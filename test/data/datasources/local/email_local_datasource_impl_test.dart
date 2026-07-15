import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource_impl.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/domain/entities/email.dart';
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
}
