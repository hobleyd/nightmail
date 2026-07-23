import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource_impl.dart';
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

void main() {
  late AppDatabase db;
  late EmailLocalDatasourceImpl datasource;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    datasource = EmailLocalDatasourceImpl(
      database: db,
      encryption: _PlaintextEncryption(),
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
}
