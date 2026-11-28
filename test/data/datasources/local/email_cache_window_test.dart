import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource_impl.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/data/services/inline_attachment_cache.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/folder_listing.dart';
import 'package:nightmail/infrastructure/cache/cache_encryption_service.dart';
import 'package:nightmail/infrastructure/sync/recent_mutation_store.dart';

// Bypasses secure-storage platform channels — only the cache's bookkeeping is
// under test here, not encryption.
class _PlaintextEncryption extends CacheEncryptionService {
  _PlaintextEncryption() : super(const FlutterSecureStorage());

  @override
  Future<void> initialize() async {}

  @override
  Future<String> encrypt(String plaintext) async => plaintext;

  @override
  Future<String> decrypt(String stored) async => stored;
}

void main() {
  late AppDatabase db;
  late EmailLocalDatasourceImpl datasource;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    datasource = EmailLocalDatasourceImpl(
      database: db,
      encryption: _PlaintextEncryption(),
      inlineAttachments: InlineAttachmentCache(),
      recentMutations: RecentMutationStore(ttl: const Duration(seconds: 30)),
    );
  });

  tearDown(() async => db.close());

  // ---------------------------------------------------------------------------
  // A listed page replaces its window of the folder, not the folder
  //
  // Replacing the whole folder with every first page meant a folder never held
  // more than one page: the rows the user had scrolled through were gone on
  // the next poll, and so was any hope of reading a folder from the cache.
  // ---------------------------------------------------------------------------
  group('cacheEmails over a listing window', () {
    final day = DateTime(2026, 6, 1);
    EmailModel row(String id, int hoursAgo,
            {String? conversationId, String folderId = 'folder-1'}) =>
        EmailModel(
          id: id,
          subject: 'Subject $id',
          from: const EmailAddressModel(address: 'a@b.com'),
          toRecipients: const [],
          ccRecipients: const [],
          bodyPreview: '',
          body: '',
          bodyType: EmailBodyType.text,
          isRead: true,
          receivedDateTime: day.subtract(Duration(hours: hoursAgo)),
          importance: EmailImportance.normal,
          conversationId: conversationId,
          parentFolderId: folderId,
        );

    Future<Set<String>> cachedIds() async => {
          for (final e in await datasource.getCachedEmails(
              accountId: 'acct-1', folderId: 'folder-1'))
            e.id,
        };

    Future<void> write(List<EmailModel> page, ListingWindow window) =>
        datasource.cacheEmails(
          accountId: 'acct-1',
          folderId: 'folder-1',
          emails: page,
          window: window,
        );

    Future<FolderCoverage> coverage() => datasource.getFolderCoverage(
        accountId: 'acct-1', folderId: 'folder-1');

    test('a top page drops the rows inside its window it no longer lists and '
        'keeps every row older than it', () async {
      await write([row('a', 1), row('gone', 2), row('b', 3), row('old', 50)],
          const ListingWindow.top());

      await write(
        [row('a', 1), row('b', 3)],
        ListingWindow.top(
            from: day.subtract(const Duration(hours: 3)),
            listedIds: const {'a', 'b'}),
      );

      expect(await cachedIds(), {'a', 'b', 'old'});
    });

    test('a page leaves a thread that straddles its edge alone', () async {
      // A long thread: its newest message is above the page's window, an
      // older one inside it. The page lists the top of the folder and not this
      // thread (Gmail dates it by a message the page's order put elsewhere).
      final straddler = [
        row('t-new', 100, conversationId: 't'),
        row('t-old', 2, conversationId: 't'),
      ];
      await write([row('a', 1), ...straddler], const ListingWindow.top());

      await write(
        [row('a', 1)],
        ListingWindow.top(
            from: day.subtract(const Duration(hours: 3)),
            listedIds: const {'a'}),
      );

      expect(await cachedIds(), containsAll(['t-new', 't-old']));
    });

    // IMAP lists by UID: an Archive filled by moves has years-old mail at the
    // top, so a page's dates say nothing about what it covers. A coverage
    // built from them claimed years the cache had never seen, and Load More
    // continued from below them.
    test('a listing out of date order replaces the folder on its top page, '
        'only adds further down, and vouches for nothing', () async {
      await write([row('a', 1), row('b', 2)],
          ListingWindow.top(from: day, listedIds: const {'a', 'b'}));
      expect((await coverage()).coveredFrom, day);

      await write(
        [row('moved-in-2019', 24 * 365 * 7)],
        ListingWindow.top(
          from: day.subtract(const Duration(days: 365 * 7)),
          listedIds: const {'moved-in-2019'},
          dateOrdered: false,
        ),
      );
      expect(await cachedIds(), {'moved-in-2019'});
      expect(await coverage(), const FolderCoverage());
      expect(await datasource.getCoveredFolderIds('acct-1'), isEmpty,
          reason: 'nothing for the offline backfill to walk');

      await write(
        [row('page-2', 5)],
        ListingWindow.continuing(
          from: day.subtract(const Duration(hours: 5)),
          to: day,
          listedIds: const {'page-2'},
          dateOrdered: false,
        ),
      );
      expect(await cachedIds(), {'moved-in-2019', 'page-2'});
      expect(await coverage(), const FolderCoverage());
    });

    test('a page further down replaces only between its start and the page '
        'above', () async {
      await write([
        row('top', 1),
        row('mid-gone', 10),
        row('mid', 11),
        row('deep', 40),
      ], const ListingWindow.top());

      await write(
        [row('mid', 11)],
        ListingWindow.continuing(
          from: day.subtract(const Duration(hours: 12)),
          to: day.subtract(const Duration(hours: 5)),
          listedIds: const {'mid'},
        ),
      );

      expect(await cachedIds(), {'top', 'mid', 'deep'});
    });

    group('coverage', () {
      DateTime hoursAgo(int h) => day.subtract(Duration(hours: h));

      test('a top page vouches for its own window; one that reached the end '
          'for the whole folder', () async {
        await write([row('a', 1), row('b', 5)],
            ListingWindow.top(from: hoursAgo(5), listedIds: const {'a', 'b'}));
        expect(await coverage(), FolderCoverage(coveredFrom: hoursAgo(5)));

        await write([row('a', 1)], const ListingWindow.top(listedIds: {'a'}));
        expect((await coverage()).complete, isTrue);
      });

      test('a top page that joins onto the cached rows keeps the coverage '
          'below it; one that does not starts over', () async {
        await write([row('a', 10), row('b', 20)],
            ListingWindow.top(from: hoursAgo(20), listedIds: const {'a', 'b'}));
        await write([row('c', 30)],
            ListingWindow.continuing(
                from: hoursAgo(30), to: hoursAgo(20), listedIds: const {'c'}));
        expect((await coverage()).coveredFrom, hoursAgo(30));

        // New mail on top, overlapping 'a': the stretch below is still known.
        await write([row('new', 1), row('a', 10)],
            ListingWindow.top(from: hoursAgo(10), listedIds: const {'new', 'a'}));
        expect((await coverage()).coveredFrom, hoursAgo(30));

        // A full page of nothing but new mail: what lies between it and the
        // cached rows has never been listed.
        await write([row('n1', 0), row('n2', 0)],
            ListingWindow.top(from: day, listedIds: const {'n1', 'n2'}));
        expect(await coverage(), FolderCoverage(coveredFrom: day));
        expect(await cachedIds(), containsAll(['a', 'c']),
            reason: 'the older rows stay cached, just no longer vouched for');
      });

      test('a moved message put back by reconciliation does not count as '
          'the page joining on', () async {
        await write([row('a', 10)],
            ListingWindow.top(from: hoursAgo(10), listedIds: const {'a'}));
        // 'moved' is cached already (re-filed here by the move) and rides on
        // the reconciled page, but the server did not list it.
        await datasource.cacheEmails(
            accountId: 'acct-1', folderId: 'folder-1', emails: [row('moved', 1)]);
        await write([row('n', 0), row('moved', 1)],
            ListingWindow.top(from: hoursAgo(1), listedIds: const {'n'}));

        expect((await coverage()).coveredFrom, hoursAgo(1));
      });

      test('a page further down extends the coverage only from its edge, and '
          'an empty one ends it', () async {
        await write([row('a', 10)],
            ListingWindow.top(from: hoursAgo(10), listedIds: const {'a'}));

        // Below a gap: moves nothing.
        await write([row('x', 50)],
            ListingWindow.continuing(
                from: hoursAgo(50), to: hoursAgo(40), listedIds: const {'x'}));
        expect((await coverage()).coveredFrom, hoursAgo(10));

        await write([row('b', 20)],
            ListingWindow.continuing(
                from: hoursAgo(20), to: hoursAgo(10), listedIds: const {'b'}));
        expect((await coverage()).coveredFrom, hoursAgo(20));

        await write(const [], ListingWindow.continuing(to: hoursAgo(20)));
        expect((await coverage()).complete, isTrue);
      });

      test('a page listed full but emptied by reconciliation extends, not '
          'ends, the coverage', () async {
        await write([row('a', 10)],
            ListingWindow.top(from: hoursAgo(10), listedIds: const {'a'}));

        await write(const [],
            ListingWindow.continuing(from: hoursAgo(20), to: hoursAgo(10)));

        expect(await coverage(), FolderCoverage(coveredFrom: hoursAgo(20)));
      });
    });

    test('the walk and the full-pass stamp survive the coverage moving',
        () async {
      final walk = FolderWalk(
          before: day, offset: 50, windowEnd: day, full: true);
      await datasource.saveFolderWalk(
          accountId: 'acct-1', folderId: 'folder-1', walk: walk);
      await write([row('a', 1)], const ListingWindow.top(listedIds: {'a'}));

      expect(
          await datasource.getFolderWalk(
              accountId: 'acct-1', folderId: 'folder-1'),
          walk);

      await datasource.saveFolderWalk(
          accountId: 'acct-1', folderId: 'folder-1', finishedFullPass: day);
      final after = await coverage();
      expect(after.complete, isTrue);
      expect(after.lastFullPassAt, day);
      expect(
          await datasource.getFolderWalk(
              accountId: 'acct-1', folderId: 'folder-1'),
          isNull);
      expect(await datasource.getCoveredFolderIds('acct-1'), ['folder-1']);
    });
  });

  group('getCachedWindow', () {
    final day = DateTime(2026, 6, 1);
    EmailModel row(String id, int hoursAgo, {String? conversationId}) =>
        EmailModel(
          id: id,
          subject: id,
          from: const EmailAddressModel(address: 'a@b.com'),
          toRecipients: const [],
          ccRecipients: const [],
          bodyPreview: '',
          body: '',
          bodyType: EmailBodyType.text,
          isRead: true,
          receivedDateTime: day.subtract(Duration(hours: hoursAgo)),
          importance: EmailImportance.normal,
          conversationId: conversationId,
          parentFolderId: 'folder-1',
        );

    setUp(() => datasource.cacheEmails(
          accountId: 'acct-1',
          folderId: 'folder-1',
          emails: [
            row('t1-new', 1, conversationId: 't1'),
            row('solo', 2),
            row('t2', 3, conversationId: 't2'),
            // An old message of the newest thread: read with its thread.
            row('t1-old', 90, conversationId: 't1'),
            row('deep', 50),
          ],
        ));

    Future<CachedWindow> read({DateTime? from, CacheCursor? after, int? limit}) =>
        datasource.getCachedWindow(
          accountId: 'acct-1',
          folderId: 'folder-1',
          from: from,
          after: after,
          limitThreads: limit,
        );

    test('reads whole threads, newest thread first, a window at a time',
        () async {
      final first = await read(limit: 2);
      expect(first.emails.map((e) => e.id).toSet(),
          {'t1-new', 't1-old', 'solo'});
      expect(first.next, isNotNull);

      final second = await read(after: first.next, limit: 2);
      expect(second.emails.map((e) => e.id).toSet(), {'t2', 'deep'});

      final third = await read(after: second.next, limit: 2);
      expect(third.emails, isEmpty);
      expect(third.next, isNull);
    });

    test('stops at the threads dated before from', () async {
      final window = await read(from: day.subtract(const Duration(hours: 3)));
      expect(window.emails.map((e) => e.id).toSet(),
          {'t1-new', 't1-old', 'solo', 't2'});
    });
  });
}
