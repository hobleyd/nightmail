import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource_impl.dart';
import 'package:nightmail/data/services/inline_attachment_cache.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/inline_attachment.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';
import 'package:nightmail/infrastructure/cache/cache_encryption_service.dart';

// Bypasses secure-storage platform channels — tests only need round-trip
// fidelity of the cache, not real encryption.
class _PlaintextEncryption extends CacheEncryptionService {
  _PlaintextEncryption() : super(const FlutterSecureStorage());

  @override
  Future<void> initialize() async {}

  @override
  Future<String> encrypt(String plaintext) async => plaintext;

  @override
  Future<String> decrypt(String stored) async => stored;
}

EmailModel _email(String id, {required String body, String folderId = 'folder-1'}) =>
    EmailModel(
      id: id,
      subject: 'Subject $id',
      from: const EmailAddressModel(address: 'a@b.com'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: 'preview',
      body: body,
      bodyType: EmailBodyType.text,
      isRead: false,
      receivedDateTime: DateTime(2026, 6, 1),
      importance: EmailImportance.normal,
      parentFolderId: folderId,
    );

/// Rewrites a cached row without its parse stamp, standing in for a row
/// written before the stamp existed (the encryption here is plaintext, so the
/// stored payload is editable JSON).
Future<void> _stripParseVersion(
    AppDatabase db, String accountId, String emailId) async {
  final row = await (db.select(db.cachedEmails)
        ..where((t) => t.accountId.equals(accountId))
        ..where((t) => t.emailId.equals(emailId)))
      .getSingle();
  final json = jsonDecode(row.encryptedData) as Map<String, dynamic>;
  json.remove('attachmentParseVersion');
  await (db.update(db.cachedEmails)
        ..where((t) => t.accountId.equals(accountId))
        ..where((t) => t.emailId.equals(emailId)))
      .write(CachedEmailsCompanion(encryptedData: Value(jsonEncode(json))));
}

void main() {
  late AppDatabase db;
  late EmailLocalDatasourceImpl datasource;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    datasource = EmailLocalDatasourceImpl(
      database: db,
      encryption: _PlaintextEncryption(),
      // No temp directory under the test binding, so every cache call no-ops.
      inlineAttachments: InlineAttachmentCache(),
    );
  });

  tearDown(() async => db.close());

  group('cacheEmails', () {
    // Regression: MailPollerCubit re-caches every message it sees in a
    // delta/list fetch, which only ever carries a preview (empty body) to
    // stay cheap. Re-running that write after the user had already opened
    // the message (which upgrades the cache row to a full body) must not
    // silently downgrade it back to empty — that would make an
    // already-fully-cached message unreadable offline again the next time
    // a poll tick or folder refresh happens to touch it.
    test('does not clobber an existing full body with a later thin '
        'preview-only write', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>full content</p>')],
      );

      // Simulates a subsequent poll/list fetch re-touching the same message
      // with only preview data (no body).
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached, isNotNull);
      expect(cached!.body, '<p>full content</p>');
    });

    test('still writes a thin row when nothing was cached before', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached, isNotNull);
      expect(cached!.body, isEmpty);
    });

    test('a later full-body write does replace a thin cached row', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>opened now</p>')],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached!.body, '<p>opened now</p>');
    });

    // Regression, and the reason folder_id is in the primary key: both
    // providers expand a folder page with the same thread's copies from other
    // folders, and the whole page is cached under the folder being listed. With
    // one row per message that write *moved* the copies, so opening any folder
    // quietly emptied every other folder's cache of the mail they shared a
    // thread with. An Inbox of a dozen long-running threads drained to whatever
    // the last delta had added, and switching to that account showed those few
    // messages alone until the network page landed.
    test('caching a folder page leaves another folder listing the same message',
        () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'inbox',
        emails: [_email('email-1', body: ''), _email('email-2', body: '')],
      );

      // Listing 'archive' returns its own mail plus the Inbox copy of the
      // thread they share.
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'archive',
        emails: [_email('email-3', body: ''), _email('email-1', body: '')],
        replaceFolder: true,
      );

      expect(
        (await datasource.getCachedEmails(
                accountId: 'acct-1', folderId: 'inbox'))
            .map((e) => e.id),
        containsAll(['email-1', 'email-2']),
      );
      expect(
        (await datasource.getCachedEmails(
                accountId: 'acct-1', folderId: 'archive'))
            .map((e) => e.id),
        containsAll(['email-1', 'email-3']),
      );
    });

    // The body belongs to the message, not to the listing that fetched it, so
    // the copy written into a second folder picks up a body already cached
    // under the first rather than re-downloading it.
    test('a thin row inherits a body cached under another folder', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'inbox',
        emails: [_email('email-1', body: '<p>full content</p>')],
      );

      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'archive',
        emails: [_email('email-1', body: '')],
      );

      // Read by id, not off the listing: the body lives once per message in
      // cached_email_details and a folder listing deliberately never reads it.
      expect(
        (await datasource.getCachedEmailById(
                accountId: 'acct-1', emailId: 'email-1'))
            ?.body,
        '<p>full content</p>',
      );
      expect(
        (await datasource.getCachedEmails(
                accountId: 'acct-1', folderId: 'archive'))
            .single
            .id,
        'email-1',
        reason: 'the thin listing still holds the message',
      );
    });

    // The whole point of the split: a folder listing decrypts every row it
    // returns, so reading bodies there is what made a Sent folder of a few
    // hundred messages cost seconds of AES on the UI isolate before painting.
    test('a folder listing carries no body, however it was cached', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'inbox',
        emails: [_email('email-1', body: '<p>full content</p>')],
      );

      final listed = (await datasource.getCachedEmails(
              accountId: 'acct-1', folderId: 'inbox'))
          .single;

      expect(listed.body, isEmpty);
      // Everything a row actually draws is still there.
      expect(listed.id, 'email-1');
      expect(listed.subject, isNotEmpty);
      expect(listed.from.address, isNotEmpty);
    });

    // A delete is addressed to the message, so it takes every listing of it —
    // the copy in another folder must not survive to be repainted back.
    test('deleting a message drops every folder copy of it', () async {
      for (final folder in ['inbox', 'archive']) {
        await datasource.cacheEmails(
          accountId: 'acct-1',
          folderId: folder,
          emails: [_email('email-1', body: '')],
        );
      }

      await datasource.deleteEmailFromCache(
        accountId: 'acct-1',
        emailId: 'email-1',
      );

      for (final folder in ['inbox', 'archive']) {
        expect(
          await datasource.getCachedEmails(
              accountId: 'acct-1', folderId: folder),
          isEmpty,
        );
      }
    });
  });

  // Regression: BodyPrefetchService wrote its fetched body through cacheEmails,
  // which inserts. A message deleted while its body was in flight — the likeliest
  // case, since the prefetch targets exactly the mail the user is reading — was
  // put straight back into the folder by that write.
  group('upgradeCachedEmailBody', () {
    test('fills in the body of a row that is still cached', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );

      await datasource.upgradeCachedEmailBody(
        accountId: 'acct-1',
        email: _email('email-1', body: '<p>fetched</p>'),
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached!.body, '<p>fetched</p>');
    });

    test('writes nothing at all when the row has gone', () async {
      await datasource.upgradeCachedEmailBody(
        accountId: 'acct-1',
        email: _email('email-1', body: '<p>fetched</p>'),
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached, isNull, reason: 'a deleted message must not be inserted');
    });

    // Scoped by account as well as id, or an IMAP UID shared across two accounts
    // would let one account's prefetch write into the other's cache.
    test('does not treat another account\'s row as the one to upgrade',
        () async {
      await datasource.cacheEmails(
        accountId: 'acct-2',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );

      await datasource.upgradeCachedEmailBody(
        accountId: 'acct-1',
        email: _email('email-1', body: '<p>fetched</p>'),
      );

      expect(
        await datasource.getCachedEmailById(
            accountId: 'acct-1', emailId: 'email-1'),
        isNull,
      );
      expect(
        (await datasource.getCachedEmailById(
                accountId: 'acct-2', emailId: 'email-1'))!
            .body,
        isEmpty,
      );
    });

    // The row may carry an optimistic mark-as-read the outbox has not drained
    // yet, and the fetched copy reports the server's stale value.
    test('keeps the cached read state over the fetched one', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );
      await datasource.updateEmailReadStatusInCache(
        accountId: 'acct-1',
        emailId: 'email-1',
        isRead: true,
      );

      // _email builds isRead: false — the server has not caught up.
      await datasource.upgradeCachedEmailBody(
        accountId: 'acct-1',
        email: _email('email-1', body: '<p>fetched</p>'),
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached!.body, '<p>fetched</p>');
      expect(cached.isRead, isTrue);
      // Read back off the row as well as out of the payload: the list orders and
      // counts by the column.
      final row = await (db.select(db.cachedEmails)
            ..where((t) => t.emailId.equals('email-1')))
          .getSingle();
      expect(row.isRead, isTrue);
    });

    // It used to re-file the row under the folder it was given, which is how a
    // prefetch made while reading in one folder emptied another folder's cache
    // of the same message.
    test('upgrades every folder that lists the message, and files no new one',
        () async {
      for (final folder in ['folder-1', 'folder-2']) {
        await datasource.cacheEmails(
          accountId: 'acct-1',
          folderId: folder,
          emails: [_email('email-1', body: '')],
        );
      }

      await datasource.upgradeCachedEmailBody(
        accountId: 'acct-1',
        email: _email('email-1', body: '<p>fetched</p>', folderId: 'folder-3'),
      );

      // The body is stored once for the message rather than once per folder, so
      // "every folder gets it" is now structural: there is only one copy to get.
      expect(
        (await datasource.getCachedEmailById(
                accountId: 'acct-1', emailId: 'email-1'))
            ?.body,
        '<p>fetched</p>',
      );
      for (final folder in ['folder-1', 'folder-2']) {
        expect(
          (await datasource.getCachedEmails(
                  accountId: 'acct-1', folderId: folder))
              .single
              .id,
          'email-1',
          reason: '$folder still lists the message',
        );
      }
      expect(
        await datasource.getCachedEmails(
            accountId: 'acct-1', folderId: 'folder-3'),
        isEmpty,
        reason: 'a body fetch is not a folder listing',
      );
    });
  });

  // A partial delta item carries the changed property and nothing else, so it
  // is applied to the row rather than written as one — see MailDeltaFieldUpdate.
  group('updateCachedEmailFields', () {
    setUp(() => datasource.cacheEmails(
          accountId: 'acct-1',
          folderId: 'folder-1',
          emails: [_email('email-1', body: '<p>full content</p>')],
        ));

    test('changes only the fields it is given', () async {
      await datasource.updateCachedEmailFields(
        accountId: 'acct-1',
        emailId: 'email-1',
        isRead: true,
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached!.isRead, isTrue);
      // The whole point: everything the delta item did not mention survives.
      expect(cached.subject, 'Subject email-1');
      expect(cached.from.address, 'a@b.com');
      expect(cached.receivedDateTime, DateTime(2026, 6, 1));
      expect(cached.body, '<p>full content</p>');
    });

    test('mirrors isRead into the column the list reads', () async {
      await datasource.updateCachedEmailFields(
        accountId: 'acct-1',
        emailId: 'email-1',
        isRead: true,
      );

      final rows = await datasource.getCachedEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
      );
      expect(rows.single.isRead, isTrue);
    });

    test('leaves a field alone when it is null', () async {
      await datasource.updateCachedEmailFields(
        accountId: 'acct-1',
        emailId: 'email-1',
        isRead: true,
      );
      await datasource.updateCachedEmailFields(
        accountId: 'acct-1',
        emailId: 'email-1',
        isFlagged: true,
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached!.isFlagged, isTrue);
      expect(cached.isRead, isTrue);
    });

    test('no-ops on an email that is not cached', () async {
      await datasource.updateCachedEmailFields(
        accountId: 'acct-1',
        emailId: 'never-seen',
        isRead: true,
      );

      final rows = await datasource.getCachedEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
      );
      expect(rows.single.id, 'email-1');
    });
  });

  // ---------------------------------------------------------------------------
  // replaceFolder — the fresh page *becomes* the folder's contents.
  //
  // Regression: callers used to do this as clearCacheForFolder followed by a
  // plain cacheEmails. That defeated the body preservation above — the lookup
  // ran against a folder that had just been emptied, so it never found the old
  // row — and every poll that detected a change discarded every cached body in
  // the folder, which BodyPrefetchService then re-downloaded. Doing the delete
  // inside cacheEmails puts it after the preservation lookups and inside the
  // same transaction.
  // ---------------------------------------------------------------------------

  group('cacheEmails(replaceFolder: true)', () {
    test('drops rows the fresh page no longer lists', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [
          _email('stays', body: ''),
          _email('moved-away', body: ''),
        ],
      );

      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('stays', body: '')],
        replaceFolder: true,
      );

      final rows = await datasource.getCachedEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
      );
      expect(rows.map((e) => e.id), ['stays']);
    });

    test('preserves an existing full body while replacing the folder',
        () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>full content</p>')],
      );

      // The poll's page carries only a preview, exactly as a list fetch does.
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
        replaceFolder: true,
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached!.body, '<p>full content</p>',
          reason: 'the delete must run after the preservation lookup');
    });

    test('leaves the folder alone when the page is empty', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );

      // An empty fetch is far more likely a transient — or every message
      // tombstoned by an in-flight mutation — than a genuinely emptied folder,
      // and clearing on it blanks the cache an offline repaint reads from.
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: const [],
        replaceFolder: true,
      );

      final rows = await datasource.getCachedEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
      );
      expect(rows.map((e) => e.id), ['email-1']);
    });

    test('does not touch another folder or another account', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('a', body: '', folderId: 'folder-1')],
      );
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-2',
        emails: [_email('b', body: '', folderId: 'folder-2')],
      );
      await datasource.cacheEmails(
        accountId: 'acct-2',
        folderId: 'folder-1',
        emails: [_email('c', body: '', folderId: 'folder-1')],
      );

      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('a2', body: '', folderId: 'folder-1')],
        replaceFolder: true,
      );

      expect(
        (await datasource.getCachedEmails(
                accountId: 'acct-1', folderId: 'folder-2'))
            .map((e) => e.id),
        ['b'],
      );
      expect(
        (await datasource.getCachedEmails(
                accountId: 'acct-2', folderId: 'folder-1'))
            .map((e) => e.id),
        ['c'],
      );
    });
  });

  group('attachment parse version', () {
    test('a row this version wrote is not stale', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>full</p>')],
      );

      expect(
        await datasource.hasStaleAttachmentParse(
            accountId: 'acct-1', emailId: 'email-1'),
        isFalse,
      );
    });

    test('an unstamped legacy row is stale', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>full</p>')],
      );
      await _stripParseVersion(db, 'acct-1', 'email-1');

      expect(
        await datasource.hasStaleAttachmentParse(
            accountId: 'acct-1', emailId: 'email-1'),
        isTrue,
      );
    });

    test('an uncached email is not stale — there is nothing to repair',
        () async {
      expect(
        await datasource.hasStaleAttachmentParse(
            accountId: 'acct-1', emailId: 'nope'),
        isFalse,
      );
    });

    // The preview-merge above copies the *old* row's attachment metadata
    // forward. Stamping that as current would mark stale metadata fresh and
    // silently cancel the one-time repair, so the old stamp has to travel with
    // it — a poll tick must not "fix" a stale row by touching it.
    test('a thin preview-only re-touch keeps a legacy row stale', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>full</p>')],
      );
      await _stripParseVersion(db, 'acct-1', 'email-1');

      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );

      expect(
        await datasource.hasStaleAttachmentParse(
            accountId: 'acct-1', emailId: 'email-1'),
        isTrue,
      );
    });

    test('a full-body rewrite clears staleness', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>full</p>')],
      );
      await _stripParseVersion(db, 'acct-1', 'email-1');

      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>refetched</p>')],
      );

      expect(
        await datasource.hasStaleAttachmentParse(
            accountId: 'acct-1', emailId: 'email-1'),
        isFalse,
      );
    });
  });

  group('meeting invite', () {
    EmailModel emailWithInvite(String id) => EmailModel(
          id: id,
          subject: 'Subject $id',
          from: const EmailAddressModel(address: 'a@b.com'),
          toRecipients: const [],
          ccRecipients: const [],
          bodyPreview: 'preview',
          body: '<p>invite</p>',
          bodyType: EmailBodyType.html,
          isRead: false,
          receivedDateTime: DateTime(2026, 6, 1),
          importance: EmailImportance.normal,
          parentFolderId: 'folder-1',
          meetingInvite: MeetingInvite(
            icsData: 'BEGIN:VCALENDAR...',
            meetingStart: DateTime.utc(2026, 6, 15, 14, 0),
            meetingEnd: DateTime.utc(2026, 6, 15, 15, 0),
            location: 'Room 1',
            isAllDay: false,
            type: MeetingEmailType.invitation,
          ),
        );

    // Regression: the meeting-invite fields were dropped by the cache
    // serializer, so the Accept/Decline banner vanished as soon as the invite
    // email was re-served from the local cache (e.g. after an app restart).
    test('round-trips the meeting invite through the cache', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [emailWithInvite('email-1')],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );

      expect(cached, isNotNull);
      final invite = cached!.meetingInvite;
      expect(invite, isNotNull);
      expect(invite!.type, MeetingEmailType.invitation);
      expect(invite.icsData, 'BEGIN:VCALENDAR...');
      expect(invite.meetingStart, DateTime.utc(2026, 6, 15, 14, 0));
      expect(invite.meetingEnd, DateTime.utc(2026, 6, 15, 15, 0));
      expect(invite.location, 'Room 1');
      expect(invite.isAllDay, isFalse);
    });

    // Regression: a poll/list fetch re-touches the row with a thin, ICS-less
    // email. That must not wipe the previously-cached invite, or the banner
    // would vanish on the next poll tick.
    test('preserves the cached invite across a later preview-only write',
        () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [emailWithInvite('email-1')],
      );
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached!.meetingInvite, isNotNull);
      expect(cached.meetingInvite!.type, MeetingEmailType.invitation);
      expect(cached.meetingInvite!.meetingStart,
          DateTime.utc(2026, 6, 15, 14, 0));
    });

    test('leaves meetingInvite null for a non-invite email', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '<p>hi</p>')],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );
      expect(cached!.meetingInvite, isNull);
    });
  });

  group('inline attachments', () {
    EmailModel emailWithInline(String id, {String body = '<img src="cid:ii_x">'}) =>
        EmailModel(
          id: id,
          subject: 'Subject $id',
          from: const EmailAddressModel(address: 'a@b.com'),
          toRecipients: const [],
          ccRecipients: const [],
          bodyPreview: 'preview',
          body: body,
          bodyType: EmailBodyType.html,
          isRead: false,
          receivedDateTime: DateTime(2026, 6, 1),
          importance: EmailImportance.normal,
          parentFolderId: 'folder-1',
          inlineAttachments: [
            InlineAttachment(
              contentId: '<ii_x@mail.gmail.com>',
              contentType: 'image/png',
              contentBytes: Uint8List.fromList([9, 8, 7, 6]),
            ),
          ],
        );

    // Regression: inline attachment bytes were dropped by the cache
    // serializer, so any already-opened email re-served from cache rendered
    // its cid: images broken.
    test('round-trips inline attachment bytes through the cache', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [emailWithInline('email-1')],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );

      expect(cached, isNotNull);
      expect(cached!.inlineAttachments, hasLength(1));
      final inline = cached.inlineAttachments.first;
      expect(inline.contentId, '<ii_x@mail.gmail.com>');
      expect(inline.contentType, 'image/png');
      expect(inline.contentBytes, equals([9, 8, 7, 6]));
    });

    test('preserves cached inline attachments across a later preview-only '
        'write', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [emailWithInline('email-1')],
      );
      // A subsequent poll/list fetch re-touches the row with preview data only.
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('email-1', body: '')],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );

      expect(cached!.inlineAttachments, hasLength(1));
      expect(cached.inlineAttachments.first.contentBytes, equals([9, 8, 7, 6]));
    });
  });

  // Which folders a message belongs to is what a folder-scoped delete consults
  // to decide whether it may touch it, and the list pane is frequently served
  // from cache — dropping membership here would put a thread's Sent copies
  // back in range of a delete aimed at the Inbox.
  group('folder membership', () {
    EmailModel emailIn(String id, List<String> folderIds) => EmailModel(
          id: id,
          subject: 'Subject $id',
          from: const EmailAddressModel(address: 'a@b.com'),
          toRecipients: const [],
          ccRecipients: const [],
          bodyPreview: 'preview',
          body: '',
          bodyType: EmailBodyType.text,
          isRead: false,
          receivedDateTime: DateTime(2026, 6, 1),
          importance: EmailImportance.normal,
          parentFolderId: folderIds.first,
          folderIds: folderIds,
        );

    test('round-trips every folder a message is in', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'INBOX',
        emails: [emailIn('email-1', ['INBOX', 'SENT', 'Label_7'])],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );

      expect(cached!.folderIds, ['INBOX', 'SENT', 'Label_7']);
      expect(cached.isInFolder('SENT'), isTrue);
      expect(cached.isDeletableFrom('INBOX'), isFalse);
    });

    test('survives a later preview-only write', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'INBOX',
        emails: [emailIn('email-1', ['SENT'])],
      );
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'INBOX',
        emails: [emailIn('email-1', ['SENT'])],
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );

      expect(cached!.folderIds, ['SENT']);
    });

    // A row cached before membership was recorded has no folderIds. Reading it
    // back as empty is what sends it to the parentFolderId fallback; inventing
    // one would have it claim membership of a folder nobody checked.
    test('a row written before membership existed reads back empty', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'INBOX',
        emails: [emailIn('email-1', ['INBOX'])],
      );
      final row = await (db.select(db.cachedEmails)
            ..where((t) => t.emailId.equals('email-1')))
          .getSingle();
      final json = jsonDecode(row.encryptedData) as Map<String, dynamic>;
      json.remove('folderIds');
      await (db.update(db.cachedEmails)
            ..where((t) => t.emailId.equals('email-1')))
          .write(CachedEmailsCompanion(encryptedData: Value(jsonEncode(json))));

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-1',
      );

      expect(cached!.folderIds, isEmpty);
      expect(cached.isInFolder('INBOX'), isTrue,
          reason: 'parentFolderId still answers for it');
      expect(cached.isInFolder('SENT'), isFalse);
    });

    // renameCachedEmailId runs when a move mints a new server id. The row's old
    // membership describes where the message no longer is.
    test('a rename onto a new folder replaces the old membership', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'INBOX',
        emails: [emailIn('email-1', ['INBOX'])],
      );

      await datasource.renameCachedEmailId(
        accountId: 'acct-1',
        oldEmailId: 'email-1',
        newEmailId: 'email-2',
        newFolderId: 'archive',
      );

      final cached = await datasource.getCachedEmailById(
        accountId: 'acct-1',
        emailId: 'email-2',
      );

      expect(cached!.folderIds, ['archive']);
      expect(cached.isInFolder('INBOX'), isFalse);
    });
  });

  // Repairs caches written while a message could only be filed under one
  // folder, when caching a folder page moved the thread's copies from elsewhere
  // into it. The rows are all still there — just under the wrong folder — and
  // each one names its own in its payload.
  group('restoreFolderMemberships', () {
    test('files a message back under its own folder', () async {
      // The theft: an Inbox message cached under the Archive listing that
      // expanded its thread.
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'archive',
        emails: [_email('email-1', body: '', folderId: 'inbox')],
      );

      expect(
        await datasource.restoreFolderMemberships(accountId: 'acct-1'),
        1,
      );

      expect(
        (await datasource.getCachedEmails(
                accountId: 'acct-1', folderId: 'inbox'))
            .single
            .id,
        'email-1',
      );
      expect(
        (await datasource.getCachedEmails(
                accountId: 'acct-1', folderId: 'archive'))
            .single
            .id,
        'email-1',
        reason: 'the Archive listing really did show it — nothing is removed',
      );
    });

    test('adds nothing for a message already filed under its own folder',
        () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'inbox',
        emails: [_email('email-1', body: '', folderId: 'inbox')],
      );

      expect(
        await datasource.restoreFolderMemberships(accountId: 'acct-1'),
        0,
      );
    });

    test('is a no-op the second time', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'archive',
        emails: [_email('email-1', body: '', folderId: 'inbox')],
      );

      await datasource.restoreFolderMemberships(accountId: 'acct-1');
      expect(
        await datasource.restoreFolderMemberships(accountId: 'acct-1'),
        0,
      );
      expect(
        await datasource.getCachedEmails(
            accountId: 'acct-1', folderId: 'inbox'),
        hasLength(1),
      );
    });

    test('carries the body across to the restored copy', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'archive',
        emails: [
          _email('email-1', body: '<p>read earlier</p>', folderId: 'inbox'),
        ],
      );

      await datasource.restoreFolderMemberships(accountId: 'acct-1');

      // The restored copy is a new *folder* row; the body is keyed by message,
      // so it is the same one both rows resolve to and there is nothing to copy.
      expect(
        (await datasource.getCachedEmails(
                accountId: 'acct-1', folderId: 'inbox'))
            .single
            .id,
        'email-1',
      );
      expect(
        (await datasource.getCachedEmailById(
                accountId: 'acct-1', emailId: 'email-1'))
            ?.body,
        '<p>read earlier</p>',
      );
    });

    // IMAP list rows come straight from the folder query and name no parent.
    test('leaves a message that names no folder of its own alone', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'archive',
        emails: [_email('email-1', body: '').copyWithParent(null)],
      );

      expect(
        await datasource.restoreFolderMemberships(accountId: 'acct-1'),
        0,
      );
    });

    // Gmail names a trashed message's label as its parent — TRASH and SPAM are
    // system labels its parser skips — so restoring one would put deleted mail
    // into a label's cached listing.
    test('leaves a trashed Gmail row where it is', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'TRASH',
        emails: [_email('email-1', body: '', folderId: 'Label_7')],
      );

      expect(
        await datasource.restoreFolderMemberships(accountId: 'acct-1'),
        0,
      );
      expect(
        await datasource.getCachedEmails(
            accountId: 'acct-1', folderId: 'Label_7'),
        isEmpty,
      );
    });

    test('does not reach into another account', () async {
      await datasource.cacheEmails(
        accountId: 'acct-2',
        folderId: 'archive',
        emails: [_email('email-1', body: '', folderId: 'inbox')],
      );

      expect(
        await datasource.restoreFolderMemberships(accountId: 'acct-1'),
        0,
      );
      expect(
        await datasource.getCachedEmails(
            accountId: 'acct-2', folderId: 'inbox'),
        isEmpty,
      );
    });
  });

  // A body belongs to the message, so it is stored once however many folders
  // list it — the same 7.6 MB message used to be held once per folder.
  group('cached_email_details', () {
    test('a message in two folders stores one body, not one per folder',
        () async {
      for (final folder in ['inbox', 'archive']) {
        await datasource.cacheEmails(
          accountId: 'acct-1',
          folderId: folder,
          emails: [_email('email-1', body: '<p>big</p>', folderId: folder)],
        );
      }

      expect((await db.select(db.cachedEmails).get()).length, 2,
          reason: 'one list row per folder');
      expect((await db.select(db.cachedEmailDetails).get()).length, 1,
          reason: 'one body for the message');
    });

    test('a body outlives one folder losing the message', () async {
      for (final folder in ['inbox', 'archive']) {
        await datasource.cacheEmails(
          accountId: 'acct-1',
          folderId: folder,
          emails: [_email('email-1', body: '<p>big</p>', folderId: folder)],
        );
      }

      await datasource.clearCacheForFolder(
          accountId: 'acct-1', folderId: 'inbox');

      expect(
        (await datasource.getCachedEmailById(
                accountId: 'acct-1', emailId: 'email-1'))
            ?.body,
        '<p>big</p>',
        reason: 'archive still lists it',
      );
    });

    // The rows that would leak are the biggest in the cache, so an unreferenced
    // body must not simply sit there.
    test('a body is collected once no folder lists the message', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'inbox',
        emails: [_email('email-1', body: '<p>big</p>')],
      );
      expect((await db.select(db.cachedEmailDetails).get()), hasLength(1));

      await datasource.clearCacheForFolder(
          accountId: 'acct-1', folderId: 'inbox');

      expect(await db.select(db.cachedEmailDetails).get(), isEmpty);
    });

    test('a folder refresh that drops a message collects its body', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'inbox',
        emails: [_email('email-1', body: '<p>big</p>')],
      );

      // The message is gone from the folder as of this refresh.
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'inbox',
        emails: [_email('email-2', body: '')],
        replaceFolder: true,
      );

      expect(await db.select(db.cachedEmailDetails).get(), isEmpty);
    });

    // A move mints a new id on Graph and IMAP, so without this every move would
    // drop the body of whatever the user had just been reading.
    test('a rename carries the body to the new id', () async {
      await datasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'inbox',
        emails: [_email('email-1', body: '<p>big</p>')],
      );

      await datasource.renameCachedEmailId(
        accountId: 'acct-1',
        oldEmailId: 'email-1',
        newEmailId: 'email-9',
        newFolderId: 'archive',
      );

      expect(
        (await datasource.getCachedEmailById(
                accountId: 'acct-1', emailId: 'email-9'))
            ?.body,
        '<p>big</p>',
      );
      expect(await db.select(db.cachedEmailDetails).get(), hasLength(1));
    });
  });
}

extension on EmailModel {
  /// Rebuilds the model with no parent folder — the entity's own `copyWith`
  /// only takes isRead.
  EmailModel copyWithParent(String? parentFolderId) => EmailModel(
        id: id,
        subject: subject,
        from: EmailAddressModel(address: from.address, name: from.name),
        toRecipients: const [],
        ccRecipients: const [],
        bodyPreview: bodyPreview,
        body: body,
        bodyType: bodyType,
        isRead: isRead,
        receivedDateTime: receivedDateTime,
        importance: importance,
        parentFolderId: parentFolderId,
      );
}
