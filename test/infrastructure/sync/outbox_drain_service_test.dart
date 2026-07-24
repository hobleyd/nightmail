import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource_impl.dart';
import 'package:nightmail/data/datasources/local/pending_operations_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/datasources/remote/spam_db_sync_datasource.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/models/email_address_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/cache/cache_encryption_service.dart';
import 'package:nightmail/infrastructure/network/connectivity_service.dart';
import 'package:nightmail/infrastructure/sync/outbox_drain_service.dart';
import 'package:nightmail/infrastructure/sync/spam_db_sync_service.dart';

import 'outbox_drain_service_test.mocks.dart';

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

const _account = MicrosoftAccount(
  id: 'acct-1',
  displayName: 'Test',
  emailAddress: 'test@example.com',
  tenantId: 'common',
);

EmailModel _email(String id, {String folderId = 'folder-1'}) => EmailModel(
      id: id,
      subject: 'Subject $id',
      from: const EmailAddressModel(address: 'a@b.com'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: false,
      receivedDateTime: DateTime(2026, 6, 1),
      importance: EmailImportance.normal,
      parentFolderId: folderId,
    );

// Implements both interfaces to stand in for ImapDatasourceImpl in the
// spamDbPush drain test below — a plain mock of EmailRemoteDatasource alone
// wouldn't satisfy the `ds is SpamDbSyncDatasource` check in the drain loop.
class _FakeSpamDbCapableDatasource extends Fake
    implements EmailRemoteDatasource, SpamDbSyncDatasource {}

@GenerateMocks([
  AccountManager,
  EmailRemoteDatasource,
  ConnectivityService,
  SpamDbSyncService,
])
void main() {
  late AppDatabase db;
  late EmailLocalDatasourceImpl localDatasource;
  late MockAccountManager mockAccountManager;
  late MockEmailRemoteDatasource mockRemoteDatasource;
  late MockConnectivityService mockConnectivityService;
  late MockSpamDbSyncService mockSpamDbSyncService;
  late OutboxDrainService service;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    localDatasource = EmailLocalDatasourceImpl(
      database: db,
      encryption: _PlaintextEncryption(),
    );
    mockAccountManager = MockAccountManager();
    mockRemoteDatasource = MockEmailRemoteDatasource();
    mockConnectivityService = MockConnectivityService();
    mockSpamDbSyncService = MockSpamDbSyncService();
    when(mockAccountManager.accounts).thenReturn([_account]);
    when(mockAccountManager.buildEmailDatasourceForAccount(any))
        .thenReturn(mockRemoteDatasource);
    when(mockConnectivityService.isOnline).thenAnswer((_) async => true);

    service = OutboxDrainService(
      pendingOperations: db,
      localDatasource: localDatasource,
      accountManager: mockAccountManager,
      connectivityService: mockConnectivityService,
      spamDbSyncService: mockSpamDbSyncService,
    );
  });

  tearDown(() async => db.close());

  group('move (server assigns a new id — Graph)', () {
    test('renames the cache row, remaps queued ops, and removes the op',
        () async {
      await localDatasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('old-id')],
      );
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'old-id',
        opType: PendingOperationType.move,
        payload: jsonEncode({'destinationFolderId': 'folder-2'}),
      );
      // A second op queued behind it for the same (pre-move) message.
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'old-id',
        opType: PendingOperationType.markRead,
        payload: jsonEncode({'isRead': true}),
      );
      when(mockRemoteDatasource.moveEmail('old-id', 'folder-2'))
          .thenAnswer((_) async => 'new-id');
      when(mockRemoteDatasource.updateEmailReadStatus(
        id: anyNamed('id'),
        isRead: anyNamed('isRead'),
      )).thenAnswer((_) async => _email('new-id'));

      await service.drainForAccount('acct-1');

      // Cache row moved to the new id/folder, old id gone.
      final renamed = await localDatasource.getCachedEmailById(
          accountId: 'acct-1', emailId: 'new-id');
      expect(renamed, isNotNull);
      final stale = await localDatasource.getCachedEmailById(
          accountId: 'acct-1', emailId: 'old-id');
      expect(stale, isNull);

      // The second op must have been sent against the remapped id.
      verify(mockRemoteDatasource.updateEmailReadStatus(
        id: 'new-id',
        isRead: true,
      )).called(1);

      // Outbox drained clean.
      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });
  });

  group('move (id stable — Gmail label change)', () {
    test('relocates the cache row to the new folder without remapping ids',
        () async {
      await localDatasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('same-id')],
      );
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'same-id',
        opType: PendingOperationType.move,
        payload: jsonEncode({'destinationFolderId': 'folder-2'}),
      );
      when(mockRemoteDatasource.moveEmail('same-id', 'folder-2'))
          .thenAnswer((_) async => 'same-id');

      await service.drainForAccount('acct-1');

      final row = await localDatasource.getCachedEmailById(
          accountId: 'acct-1', emailId: 'same-id');
      expect(row, isNotNull);
      expect(row!.parentFolderId, 'folder-2');
      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });
  });

  group('move (server id unknown — IMAP)', () {
    test('removes the op without touching the cache row', () async {
      await localDatasource.cacheEmails(
        accountId: 'acct-1',
        folderId: 'folder-1',
        emails: [_email('imap-id')],
      );
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'imap-id',
        opType: PendingOperationType.move,
        payload: jsonEncode({'destinationFolderId': 'folder-2'}),
      );
      when(mockRemoteDatasource.moveEmail('imap-id', 'folder-2'))
          .thenAnswer((_) async => null);

      await service.drainForAccount('acct-1');

      final row = await localDatasource.getCachedEmailById(
          accountId: 'acct-1', emailId: 'imap-id');
      expect(row, isNotNull);
      expect(row!.parentFolderId, 'folder-1'); // untouched
      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });
  });

  group('ordering and failure handling', () {
    test(
        'a failure quarantines only the remaining ops for that message, '
        'leaving it queued for retry', () async {
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      when(mockRemoteDatasource.deleteEmail('email-1'))
          .thenThrow(Exception('throttled'));

      await service.drainForAccount('acct-1');

      final remaining = await db.getPendingOperations('acct-1');
      expect(remaining, hasLength(1));
      expect(remaining.first.retryCount, 1);
      expect(remaining.first.lastError, contains('throttled'));
    });

    // Regression: a single permanently-failing op used to stop draining for
    // the *whole account*, silently blocking every other queued message's
    // mutations behind it indefinitely. A failure must only quarantine the
    // remaining ops for its own message.
    test('a failing message does not block an unrelated message from '
        'draining in the same pass', () async {
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-2',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      when(mockRemoteDatasource.deleteEmail('email-1'))
          .thenThrow(Exception('throttled'));
      when(mockRemoteDatasource.deleteEmail('email-2'))
          .thenAnswer((_) async {});

      await service.drainForAccount('acct-1');

      verify(mockRemoteDatasource.deleteEmail('email-2')).called(1);
      final remaining = await db.getPendingOperations('acct-1');
      expect(remaining, hasLength(1));
      expect(remaining.first.emailId, 'email-1');
    });

    // Regression: ops for the same message must still stop in order after
    // a failure for that message — quarantine must not accidentally let a
    // later op for the *same* email through.
    test('a failing message still blocks its own later queued ops',
        () async {
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-1',
        opType: PendingOperationType.move,
        payload: jsonEncode({'destinationFolderId': 'folder-2'}),
      );
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-1',
        opType: PendingOperationType.markRead,
        payload: jsonEncode({'isRead': true}),
      );
      when(mockRemoteDatasource.moveEmail('email-1', 'folder-2'))
          .thenThrow(Exception('throttled'));

      await service.drainForAccount('acct-1');

      verifyNever(mockRemoteDatasource.updateEmailReadStatus(
        id: anyNamed('id'),
        isRead: anyNamed('isRead'),
      ));
      final remaining = await db.getPendingOperations('acct-1');
      expect(remaining, hasLength(2));
    });
  });

  group('giving up on doomed ops', () {
    // Regression: a delete/move/junk whose target 404s ("not found in the
    // store") can never succeed — the message is already gone. It used to be
    // requeued and re-fail on every single poll forever (live-observed at
    // thousands of retries). It must be dropped instead.
    test('drops a delete whose target 404s instead of retrying forever',
        () async {
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'gone-id',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      when(mockRemoteDatasource.deleteEmail('gone-id')).thenThrow(
          const ServerException(message: 'not found', statusCode: 404));

      await service.drainForAccount('acct-1');

      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });

    test('drops a move whose target 404s', () async {
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'gone-id',
        opType: PendingOperationType.move,
        payload: jsonEncode({'destinationFolderId': 'folder-2'}),
      );
      when(mockRemoteDatasource.moveEmail('gone-id', 'folder-2')).thenThrow(
          const ServerException(message: 'not found', statusCode: 404));

      await service.drainForAccount('acct-1');

      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });

    // A non-404 failure (e.g. transient server/throttle) is still retryable,
    // so it stays queued — only its retry counter advances.
    test('keeps a non-404 failure queued for retry', () async {
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      when(mockRemoteDatasource.deleteEmail('email-1')).thenThrow(
          const ServerException(message: 'throttled', statusCode: 503));

      await service.drainForAccount('acct-1');

      final remaining = await db.getPendingOperations('acct-1');
      expect(remaining, hasLength(1));
      expect(remaining.first.retryCount, 1);
    });

    // Backstop: even a persistently-failing non-404 op is dropped once it has
    // burned through its retry budget, so it can't re-fail on every poll
    // indefinitely.
    test('drops an op that has exhausted its retry budget', () async {
      final id = await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      // Simulate an op that has already failed right up to the cap boundary.
      for (var i = 0; i < 24; i++) {
        await db.recordFailure(id: id, error: 'boom');
      }
      when(mockRemoteDatasource.deleteEmail('email-1'))
          .thenThrow(Exception('still failing'));

      await service.drainForAccount('acct-1');

      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });
  });

  group('connectivity gate', () {
    // Regression: drainForAccount is fired fire-and-forget immediately after
    // every mutation (not just from the periodic poll, which already gates
    // on connectivity itself). Without this check, mutating something while
    // offline sent a real request straight into the HTTP client's ~30s
    // connect timeout in the background, live-observed via a real
    // NetworkException recorded on a queued op after a genuine offline
    // toggle.
    test('does not attempt any remote calls while offline', () async {
      when(mockConnectivityService.isOnline).thenAnswer((_) async => false);
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );

      await service.drainForAccount('acct-1');

      verifyNever(mockRemoteDatasource.deleteEmail(any));
      final remaining = await db.getPendingOperations('acct-1');
      expect(remaining, hasLength(1));
      expect(remaining.first.retryCount, 0);
    });
  });

  group('concurrent drainForAccount calls', () {
    // Regression: drainForAccount is fired unawaited from multiple
    // uncoordinated call sites (right after a mutation, every poll tick, on
    // reconnect, and now after enqueuing a SPAMDB push) — all sharing one
    // live IMAP connection per account with no per-operation locking. Two
    // overlapping drains could interleave a SELECT from one with an
    // EXPUNGE from the other and corrupt the wrong mailbox. Chaining, not
    // racing, is what makes routing SPAMDB push through the outbox actually
    // safe.
    test('a second call is chained behind an in-flight drain, not raced',
        () async {
      await db.enqueue(
        accountId: 'acct-1',
        emailId: 'email-1',
        opType: PendingOperationType.delete,
        payload: '{}',
      );
      final gate = Completer<void>();
      var deleteCallCount = 0;
      when(mockRemoteDatasource.deleteEmail(any)).thenAnswer((_) async {
        deleteCallCount++;
        await gate.future;
      });

      final first = service.drainForAccount('acct-1');
      final second = service.drainForAccount('acct-1');

      // Let both futures run as far as they can without the gate. If the
      // two drains were racing rather than chained, the second would have
      // already read the (still-present) queued op and called deleteEmail
      // too, making this 2.
      await Future<void>.delayed(Duration.zero);
      expect(deleteCallCount, 1,
          reason: 'the second drain must not start its own pass until the '
              'first one has finished');

      gate.complete();
      await Future.wait([first, second]);

      // Still 1: by the time the chained second drain actually ran, the
      // first had already removed the only queued op.
      expect(deleteCallCount, 1);
      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });
  });

  group('emptyFolder', () {
    test('passes folderId and permanentDelete from the payload', () async {
      await db.enqueue(
        accountId: 'acct-1',
        emailId: '__folder__',
        folderId: 'folder-1',
        opType: PendingOperationType.emptyFolder,
        payload: jsonEncode({'permanentDelete': true}),
      );
      when(mockRemoteDatasource.emptyFolder('folder-1', permanentDelete: true))
          .thenAnswer((_) async {});

      await service.drainForAccount('acct-1');

      verify(mockRemoteDatasource.emptyFolder('folder-1', permanentDelete: true))
          .called(1);
      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });
  });

  group('spamDbPush', () {
    test(
        'drains a queued push by calling SpamDbSyncService.pushForAccount on '
        'the account\'s own datasource — never run directly by callers, so '
        'this is the only path that can touch the shared IMAP connection',
        () async {
      final fakeDs = _FakeSpamDbCapableDatasource();
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(fakeDs);
      when(mockSpamDbSyncService.pushForAccount(any, any))
          .thenAnswer((_) async {});
      await db.enqueue(
        accountId: 'acct-1',
        emailId: '__spamdb__',
        opType: PendingOperationType.spamDbPush,
        payload: '{}',
      );

      await service.drainForAccount('acct-1');

      verify(mockSpamDbSyncService.pushForAccount('acct-1', fakeDs)).called(1);
      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });

    test('is skipped (not crashed on) when the datasource is not IMAP',
        () async {
      // mockRemoteDatasource (the default) doesn't implement
      // SpamDbSyncDatasource, mirroring Gmail/Graph.
      await db.enqueue(
        accountId: 'acct-1',
        emailId: '__spamdb__',
        opType: PendingOperationType.spamDbPush,
        payload: '{}',
      );

      await service.drainForAccount('acct-1');

      verifyNever(mockSpamDbSyncService.pushForAccount(any, any));
      expect(await db.getPendingOperations('acct-1'), isEmpty);
    });
  });
}
