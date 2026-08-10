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
}
