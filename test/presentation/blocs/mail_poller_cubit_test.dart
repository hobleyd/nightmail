import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/settings/app_settings.dart';
import 'package:nightmail/data/datasources/local/delta_token_datasource.dart';
import 'package:nightmail/data/datasources/local/email_local_datasource.dart';
import 'package:nightmail/data/datasources/local/folder_local_datasource.dart';
import 'package:nightmail/data/datasources/local/pending_operations_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/models/email_folder_model.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/domain/usecases/get_cached_folders.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/data/models/mail_delta_result.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/badge/badge_service.dart';
import 'package:nightmail/infrastructure/network/connectivity_service.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';
import 'package:nightmail/infrastructure/sync/body_prefetch_service.dart';
import 'package:nightmail/infrastructure/sync/imap_connection_gate.dart';
import 'package:nightmail/infrastructure/sync/outbox_drain_service.dart';
import 'package:nightmail/infrastructure/sync/removal_tombstone_store.dart';
import 'package:nightmail/infrastructure/sync/spam_db_sync_service.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_state.dart';

import 'mail_poller_cubit_test.mocks.dart';

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _msId = 'acct-ms-1';
const _savedToken =
    'https://graph.microsoft.com/v1.0/me/messages/delta?token=old';
const _newToken =
    'https://graph.microsoft.com/v1.0/me/messages/delta?token=new';

final _msAccount = MicrosoftAccount(
  id: _msId,
  displayName: 'Test User',
  emailAddress: 'test@example.com',
  tenantId: 'common',
);

final _gmailAccount = GmailAccount(
  id: 'acct-gmail-1',
  displayName: 'Gmail',
  emailAddress: 'test@gmail.com',
);

EmailFolderModel _inbox({int unread = 0}) => EmailFolderModel.fromJson({
      'id': 'inbox-id',
      'displayName': 'Inbox',
      'totalItemCount': 100,
      'unreadItemCount': unread,
      'parentFolderId': null,
      'isHidden': false,
      'childFolderCount': 0,
    });

EmailModel _email(
  String id, {
  bool isRead = false,
  String receivedDateTime = '2026-06-11T10:00:00Z',
  List<Map<String, dynamic>> attachments = const [],
}) =>
    EmailModel.fromJson({
      'id': id,
      'subject': 'Subj',
      'from': {
        'emailAddress': {'address': 's@example.com', 'name': 'S'}
      },
      'toRecipients': <dynamic>[],
      'ccRecipients': <dynamic>[],
      'bodyPreview': '',
      'isRead': isRead,
      'attachments': attachments,
      'receivedDateTime': receivedDateTime,
      'sentDateTime': '2026-06-11T09:59:00Z',
      'importance': 'normal',
      'conversationId': 'c1',
      'hasAttachments': false,
      'parentFolderId': 'inbox-id',
    });

MailDeltaResult _emptyDelta() => MailDeltaResult(
      upserted: [],
      removedIds: [],
      deltaLink: _newToken,
    );

// ---------------------------------------------------------------------------
// @GenerateMocks
// ---------------------------------------------------------------------------

@GenerateMocks([
  AccountManager,
  AppSettings,
  BadgeService,
  ConnectivityService,
  DeltaTokenDatasource,
  EmailLocalDatasource,
  FolderLocalDatasource,
  GraphApiDatasourceImpl,
  EmailRemoteDatasource,
  GetCachedFolders,
  NotificationService,
  OutboxDrainService,
  PendingOperationsDatasource,
  SpamDbSyncService,
])
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late MockAccountManager mockAccountManager;
  late MockAppSettings mockAppSettings;
  late MockBadgeService mockBadgeService;
  late MockConnectivityService mockConnectivityService;
  late MockDeltaTokenDatasource mockDatabase;
  late MockEmailLocalDatasource mockEmailLocalDatasource;
  late MockFolderLocalDatasource mockFolderLocalDatasource;
  late MockGraphApiDatasourceImpl mockGraphDs;
  late MockGetCachedFolders mockGetCachedFolders;
  late MockNotificationService mockNotificationService;
  late MockOutboxDrainService mockOutboxDrainService;
  late MockPendingOperationsDatasource mockPendingOperations;
  late MockSpamDbSyncService mockSpamDbSyncService;
  late RemovalTombstoneStore removalTombstones;
  late BodyPrefetchService bodyPrefetchService;

  MailPollerCubit _makeCubit() => MailPollerCubit(
        accountManager: mockAccountManager,
        appSettings: mockAppSettings,
        badgeService: mockBadgeService,
        bodyPrefetchService: bodyPrefetchService,
        connectivityService: mockConnectivityService,
        database: mockDatabase,
        emailLocalDatasource: mockEmailLocalDatasource,
        folderLocalDatasource: mockFolderLocalDatasource,
        getCachedFolders: mockGetCachedFolders,
        imapConnectionGate: ImapConnectionGate(),
        notificationService: mockNotificationService,
        outboxDrainService: mockOutboxDrainService,
        pendingOperations: mockPendingOperations,
        removalTombstones: removalTombstones,
        spamDbSyncService: mockSpamDbSyncService,
      );

  void _stubInfra() {
    when(mockAppSettings.loadPollIntervalSeconds())
        .thenAnswer((_) async => 9999); // long — no repeated timer fires
    when(mockBadgeService.setBadgeCount(any)).thenAnswer((_) async {});
    when(mockDatabase.saveDeltaToken(any, any, any)).thenAnswer((_) async {});
    when(mockDatabase.clearDeltaTokensForAccount(any))
        .thenAnswer((_) async {});
    when(mockGetCachedFolders(any))
        .thenAnswer((_) async => const Right([]));
    when(mockEmailLocalDatasource.cacheEmails(
      accountId: anyNamed('accountId'),
      folderId: anyNamed('folderId'),
      emails: anyNamed('emails'),
      replaceFolder: anyNamed('replaceFolder'),
    )).thenAnswer((_) async {});
    when(mockEmailLocalDatasource.getCachedEmails(
      accountId: anyNamed('accountId'),
      folderId: anyNamed('folderId'),
    )).thenAnswer((_) async => const []);
    when(mockFolderLocalDatasource.cacheFolders(
      accountId: anyNamed('accountId'),
      folders: anyNamed('folders'),
    )).thenAnswer((_) async {});
    when(mockEmailLocalDatasource.clearCacheForFolder(
      accountId: anyNamed('accountId'),
      folderId: anyNamed('folderId'),
    )).thenAnswer((_) async {});
    when(mockEmailLocalDatasource.deleteEmailFromCache(
      accountId: anyNamed('accountId'),
      emailId: anyNamed('emailId'),
      evictInlineAttachments: anyNamed('evictInlineAttachments'),
    )).thenAnswer((_) async {});
    when(mockNotificationService.showNewMailNotification(
      accountLabel: anyNamed('accountLabel'),
      newCount: anyNamed('newCount'),
    )).thenAnswer((_) async {});
    when(mockNotificationService.showEmailNotification(
      emailId: anyNamed('emailId'),
      accountId: anyNamed('accountId'),
      subject: anyNamed('subject'),
      senderName: anyNamed('senderName'),
      accountLabel: anyNamed('accountLabel'),
    )).thenAnswer((_) async {});
    when(mockOutboxDrainService.drainAll()).thenAnswer((_) async {});
    // Online by default — tests that need offline behavior override this.
    when(mockConnectivityService.isOnline).thenAnswer((_) async => true);
    when(mockConnectivityService.onReconnected)
        .thenAnswer((_) => const Stream<void>.empty());
    // No pending outbox ops by default — tests exercising reconciliation
    // override this.
    when(mockPendingOperations.getPendingOperations(any))
        .thenAnswer((_) async => []);
  }

  setUp(() {
    mockAccountManager = MockAccountManager();
    mockAppSettings = MockAppSettings();
    mockBadgeService = MockBadgeService();
    mockPendingOperations = MockPendingOperationsDatasource();
    mockConnectivityService = MockConnectivityService();
    mockDatabase = MockDeltaTokenDatasource();
    mockEmailLocalDatasource = MockEmailLocalDatasource();
    mockFolderLocalDatasource = MockFolderLocalDatasource();
    mockGraphDs = MockGraphApiDatasourceImpl();
    mockGetCachedFolders = MockGetCachedFolders();
    mockOutboxDrainService = MockOutboxDrainService();
    mockNotificationService = MockNotificationService();
    mockSpamDbSyncService = MockSpamDbSyncService();
    removalTombstones = RemovalTombstoneStore();
    bodyPrefetchService =
        BodyPrefetchService(localDatasource: mockEmailLocalDatasource);
    provideDummy<Either<Failure, List<EmailFolder>>>(const Right([]));
    _stubInfra();
  });

  // ---------------------------------------------------------------------------
  // No saved token → folder polling + async bootstrap
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — Microsoft account, no saved token', () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => null);
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 4)]);
      when(mockGraphDs.syncMailDelta(any,
              deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => _emptyDelta());
    });

    test('calls getMailFolders for immediate badge count', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockGraphDs.getMailFolders()).called(1);
    });

    test('updates badge from folder unread count', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      final badges =
          verify(mockBadgeService.setBadgeCount(captureAny)).captured;
      expect(badges.last, 4);
    });

    test('bootstrap saves delta token after initial sync', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockDatabase.saveDeltaToken(_msId, 'inbox', _newToken)).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Offline — skip the cycle rather than run out each account's HTTP
  // connect timeout in turn.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — offline', () {
    test('skips the poll cycle entirely without touching the datasource',
        () async {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockConnectivityService.isOnline).thenAnswer((_) async => false);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verifyNever(mockGraphDs.getMailFolders());
      verifyNever(mockDatabase.loadDeltaToken(any, any));
    });

    test('onReconnected triggers an immediate drain and poll', () async {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => null);
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 0)]);
      final reconnectController = StreamController<void>.broadcast();
      when(mockConnectivityService.onReconnected)
          .thenAnswer((_) => reconnectController.stream);
      addTearDown(reconnectController.close);

      final cubit = _makeCubit();
      addTearDown(cubit.close);
      await cubit.initialize();
      await pumpEventQueue();
      clearInteractions(mockOutboxDrainService);

      reconnectController.add(null);
      await pumpEventQueue();

      verify(mockOutboxDrainService.drainAll()).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Saved token, no changes → skip getMailFolders
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — Microsoft account, incremental sync, no changes',
      () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.syncMailDelta(any,
              deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => _emptyDelta());
      // Prime the cache so _latestPolledUnread is populated before the first
      // poll. Without this, the "no cached count" branch fires getMailFolders.
      when(mockGetCachedFolders(any)).thenAnswer((_) async => Right([
            const EmailFolder(
                id: 'inbox', displayName: 'Inbox',
                totalItemCount: 10, unreadItemCount: 2),
          ]));
    });

    test('does NOT call getMailFolders when delta returns no changes',
        () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verifyNever(mockGraphDs.getMailFolders());
    });

    test('saves the new delta link returned by the server', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockDatabase.saveDeltaToken(_msId, 'inbox', _newToken)).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // Saved token, new unread mail → getMailFolders + new mail state
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — Microsoft account, incremental sync, new unread',
      () {
    setUp(() {
      // activeAccount = null → MS account treated as inactive → new mail fires
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.syncMailDelta(any,
              deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: [_email('new-msg', isRead: false)],
                removedIds: [],
                deltaLink: _newToken,
              ));
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 3)]);
    });

    test('calls getMailFolders when changes are found', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockGraphDs.getMailFolders()).called(1);
    });

    test('emits state with account in accountsWithNewMail', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      final states = <MailPollerState>[];
      final sub = cubit.stream.listen(states.add);
      addTearDown(sub.cancel);

      await cubit.initialize();
      await pumpEventQueue();

      expect(states, isNotEmpty);
      expect(states.last.accountsWithNewMail, contains(_msId));
    });

    test('updates badge to folder unread count', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      final badges =
          verify(mockBadgeService.setBadgeCount(captureAny)).captured;
      expect(badges.last, 3);
    });
  });

  // ---------------------------------------------------------------------------
  // Saved token, changes but no new unread → getMailFolders, no new mail state
  // ---------------------------------------------------------------------------

  group(
      'MailPollerCubit — Microsoft account, incremental sync, '
      'changes but no new unread',
      () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      // A message was marked read — has changes but no new unread.
      when(mockGraphDs.syncMailDelta(any,
              deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: [_email('msg-1', isRead: true)],
                removedIds: [],
                deltaLink: _newToken,
              ));
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 0)]);
    });

    test('still calls getMailFolders to refresh badge', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockGraphDs.getMailFolders()).called(1);
    });

    test('does NOT add account to accountsWithNewMail', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      final states = <MailPollerState>[];
      final sub = cubit.stream.listen(states.add);
      addTearDown(sub.cancel);

      await cubit.initialize();
      await pumpEventQueue();

      for (final s in states) {
        expect(s.accountsWithNewMail, isNot(contains(_msId)));
      }
    });
  });

  // ---------------------------------------------------------------------------
  // Reconciliation against pending outbox ops
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — reconciliation against pending outbox ops', () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 1)]);
    });

    test('drops a message from the cache write when a delete/move/junk op '
        'is still pending for it (tombstone)', () async {
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: [_email('deleted-msg'), _email('kept-msg')],
                removedIds: [],
                deltaLink: _newToken,
              ));
      when(mockPendingOperations.getPendingOperations(_msId))
          .thenAnswer((_) async => [
                const PendingOperationRecord(
                  id: 1,
                  accountId: _msId,
                  emailId: 'deleted-msg',
                  folderId: null,
                  opType: PendingOperationType.delete,
                  payload: '{}',
                  createdAtMs: 0,
                  retryCount: 0,
                  lastError: null,
                ),
              ]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);
      await cubit.initialize();
      await pumpEventQueue();

      final cached = verify(mockEmailLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: captureAnyNamed('emails'),
      )).captured.single as List<dynamic>;
      final cachedIds = cached.map((e) => (e as dynamic).id).toSet();
      expect(cachedIds, isNot(contains('deleted-msg')));
      expect(cachedIds, contains('kept-msg'));
    });

    // Regression: the pending-op tombstone above only covers a message while
    // its outbox op is still queued. Once the drain deletes and dequeues the
    // op, a stale server snapshot resolving in that window would resurrect it.
    // A multi-message delete (e.g. a whole conversation thread) drains one op
    // at a time over several seconds, widening that window. The recently-
    // removed tombstone store — shared with EmailRepositoryImpl — must be
    // honoured here too, or the poll re-caches the just-deleted message.
    test('drops a message that is in the removal tombstone store even with no '
        'pending op (post-drain window)', () async {
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: [_email('drained-msg'), _email('kept-msg')],
                removedIds: [],
                deltaLink: _newToken,
              ));
      // No pending op for it any more — the drain already dequeued it.
      when(mockPendingOperations.getPendingOperations(_msId))
          .thenAnswer((_) async => []);
      removalTombstones.record(_msId, 'drained-msg');

      final cubit = _makeCubit();
      addTearDown(cubit.close);
      await cubit.initialize();
      await pumpEventQueue();

      final cached = verify(mockEmailLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: captureAnyNamed('emails'),
      )).captured.single as List<dynamic>;
      final cachedIds = cached.map((e) => (e as dynamic).id).toSet();
      expect(cachedIds, isNot(contains('drained-msg')));
      expect(cachedIds, contains('kept-msg'));
    });

    test('keeps the locally-cached isRead value when a markRead op is '
        'still pending for that message (local wins)', () async {
      // Server still reports it unread — the local mark-as-read hasn't
      // drained yet.
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: [_email('msg-1', isRead: false)],
                removedIds: [],
                deltaLink: _newToken,
              ));
      when(mockPendingOperations.getPendingOperations(_msId))
          .thenAnswer((_) async => [
                const PendingOperationRecord(
                  id: 1,
                  accountId: _msId,
                  emailId: 'msg-1',
                  folderId: null,
                  opType: PendingOperationType.markRead,
                  payload: '{"isRead":true}',
                  createdAtMs: 0,
                  retryCount: 0,
                  lastError: null,
                ),
              ]);
      when(mockEmailLocalDatasource.getCachedEmailById(
        accountId: _msId,
        emailId: 'msg-1',
      )).thenAnswer((_) async => _email('msg-1', isRead: true));

      final cubit = _makeCubit();
      addTearDown(cubit.close);
      await cubit.initialize();
      await pumpEventQueue();

      final cached = verify(mockEmailLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: captureAnyNamed('emails'),
      )).captured.single as List<dynamic>;
      expect((cached.single as dynamic).isRead, isTrue);
    });
  });

  // ---------------------------------------------------------------------------
  // Delta items that name only the properties that changed.
  //
  // Regression: opening a message marks it read, and the next delta reports
  // that change as the id and `isRead` alone. Cached as if it were a whole
  // message, it replaced the real row with one that had no sender, no subject
  // and an epoch date — so the message the user had just opened dropped to the
  // bottom of the list, blank, until the next full fetch put it back.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — delta field updates', () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 0)]);
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: const [],
                removedIds: const [],
                fieldUpdates: const [
                  MailDeltaFieldUpdate(id: 'msg-1', isRead: true),
                ],
                deltaLink: _newToken,
              ));
    });

    test('are applied to the cached row instead of rewriting it', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);
      await cubit.initialize();
      await pumpEventQueue();

      verify(mockEmailLocalDatasource.updateCachedEmailFields(
        accountId: _msId,
        emailId: 'msg-1',
        isRead: true,
        isFlagged: null,
      )).called(1);
      // Nothing may go through the upsert path: that is what blanked the row.
      verifyNever(mockEmailLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: anyNamed('emails'),
      ));
    });

    test('do not overwrite isRead while a markRead op is still pending',
        () async {
      when(mockPendingOperations.getPendingOperations(_msId))
          .thenAnswer((_) async => [
                const PendingOperationRecord(
                  id: 1,
                  accountId: _msId,
                  emailId: 'msg-1',
                  folderId: null,
                  opType: PendingOperationType.markRead,
                  payload: '{"isRead":false}',
                  createdAtMs: 0,
                  retryCount: 0,
                  lastError: null,
                ),
              ]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);
      await cubit.initialize();
      await pumpEventQueue();

      verify(mockEmailLocalDatasource.updateCachedEmailFields(
        accountId: _msId,
        emailId: 'msg-1',
        isRead: null,
        isFlagged: null,
      )).called(1);
    });

    test('are skipped for a message with a pending removal', () async {
      when(mockPendingOperations.getPendingOperations(_msId))
          .thenAnswer((_) async => []);
      removalTombstones.record(_msId, 'msg-1');

      final cubit = _makeCubit();
      addTearDown(cubit.close);
      await cubit.initialize();
      await pumpEventQueue();

      verifyNever(mockEmailLocalDatasource.updateCachedEmailFields(
        accountId: anyNamed('accountId'),
        emailId: anyNamed('emailId'),
        isRead: anyNamed('isRead'),
        isFlagged: anyNamed('isFlagged'),
      ));
    });
  });

  // ---------------------------------------------------------------------------
  // Expired delta token (410)
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — expired delta token (410)', () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.syncMailDelta(any,
              deltaLink: anyNamed('deltaLink')))
          .thenThrow(const ServerException(
            message: 'Sync state generation has expired.',
            statusCode: 410,
          ));
    });

    test('clears delta token so next poll can re-bootstrap', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockDatabase.clearDeltaTokensForAccount(_msId)).called(1);
    });

    test('does not crash the cubit', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      expect(() async {
        await cubit.initialize();
        await pumpEventQueue();
      }, returnsNormally);
    });
  });

  // ---------------------------------------------------------------------------
  // Non-Microsoft account — falls through to folder polling
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — non-Microsoft account (Gmail)', () {
    late MockEmailRemoteDatasource mockGmailDs;

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_gmailAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 7)]);
    });

    test('always calls getMailFolders (no delta support)', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockGmailDs.getMailFolders()).called(1);
    });

    test('sets badge from folder unread count', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      final badges =
          verify(mockBadgeService.setBadgeCount(captureAny)).captured;
      expect(badges.last, 7);
    });
  });

  // ---------------------------------------------------------------------------
  // Gmail non-active account — new unread mail should show a real
  // subject/sender (fetched from the inbox) rather than the generic
  // aggregate alert, with a graceful fallback if that fetch fails.
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // A background account's cache must move too.
  //
  // Regression: a non-active account had nothing but a boolean "has new mail"
  // flag toggled — no cache write of any kind — so switching to it showed rows
  // frozen at whenever it was last selected until a manual refresh landed.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — non-active account caching', () {
    late MockEmailRemoteDatasource mockGmailDs;

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
    });

    test('replaces a background account\'s inbox cache on a count change',
        () async {
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 1 : 4)];
      });
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => [_email('bg-1')]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      verify(mockEmailLocalDatasource.cacheEmails(
        accountId: _gmailAccount.id,
        folderId: 'inbox-id',
        emails: anyNamed('emails'),
        replaceFolder: true,
      )).called(greaterThanOrEqualTo(1));
      // Not the active account, so nothing tells the UI to repaint from it.
      expect(cubit.state.syncedFolderIds, isEmpty);
    });
  });

  group('MailPollerCubit — Gmail non-active account, new unread mail', () {
    late MockEmailRemoteDatasource mockGmailDs;

    // This toast fallback only fires on Windows/Linux (macOS/mobile surface
    // new mail via the dock badge / OS background isolate instead — see the
    // `Platform.isWindows || Platform.isLinux` guard in MailPollerCubit._poll).
    // `Platform.isWindows`/`isLinux` are `static final` in dart:io with no
    // IOOverrides hook, so they can't be faked when the suite itself runs on
    // macOS; skip rather than report a false failure on this host.
    final skipReason = Platform.isWindows || Platform.isLinux
        ? null
        : 'Windows/Linux-only new-mail toast path; cannot run on ${Platform.operatingSystem}';

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
    });

    test('shows the real subject/sender when the inbox fetch succeeds',
        () async {
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 0 : 2)];
      });
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => [_email('new-1', isRead: false)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      verify(mockNotificationService.showEmailNotification(
        emailId: 'new-1',
        accountId: _gmailAccount.id,
        subject: 'Subj',
        senderName: 'S and 1 more',
        accountLabel: 'Gmail',
      )).called(1);
      verifyNever(mockNotificationService.showNewMailNotification(
        accountLabel: anyNamed('accountLabel'),
        newCount: anyNamed('newCount'),
      ));
    }, skip: skipReason);

    test('falls back to the generic alert when the inbox fetch fails',
        () async {
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 0 : 2)];
      });
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenThrow(Exception('network blip'));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      verify(mockNotificationService.showNewMailNotification(
        accountLabel: _gmailAccount.emailAddress,
        newCount: 2,
      )).called(1);
      verifyNever(mockNotificationService.showEmailNotification(
        emailId: anyNamed('emailId'),
        accountId: anyNamed('accountId'),
        subject: anyNamed('subject'),
        senderName: anyNamed('senderName'),
        accountLabel: anyNamed('accountLabel'),
      ));
    }, skip: skipReason);
  });

  // ---------------------------------------------------------------------------
  // Gmail active account — pollGeneration must increment on unread increase
  // (regression: was never set in the non-delta path)
  // ---------------------------------------------------------------------------

  group(
      'MailPollerCubit — Gmail active account, '
      'pollGeneration triggered by unread increase',
      () {
    late MockEmailRemoteDatasource mockGmailDs;

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_gmailAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
    });

    test('pollGeneration increments when unread count rises', () async {
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 3 : 6)];
      });

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      // Poll 1: sets baseline (3 unread) — no increment expected.
      await cubit.initialize();
      await pumpEventQueue();
      expect(cubit.state.pollGeneration, 0);

      // Poll 2: unread jumped to 6 — must increment.
      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 1);
    });

    test('pollGeneration does NOT increment when unread count is unchanged',
        () async {
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 3)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 0);
    });

    test('pollGeneration increments when unread count decreases', () async {
      // A decrease (e.g. read/deleted on another client) must also refresh
      // the UI — otherwise a stale, too-high count never self-heals.
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 5 : 2)];
      });

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      expect(cubit.state.pollGeneration, 0);

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Gmail active account — the synced inbox page must *replace* the folder's
  // cache, not merge into it.
  //
  // Regression: cacheEmails is an upsert, so it can only ever add. A thread
  // filed into another folder is never returned by the inbox fetch again, so
  // its rows sat in the cache untouched — and because the list repaints from
  // cache as soon as pollGeneration bumps, the just-filed thread reappeared in
  // the Inbox and stayed there until a manual folder refresh.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — Gmail active account, inbox cache replacement', () {
    late MockEmailRemoteDatasource mockGmailDs;

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_gmailAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
    });

    // Two polls: the first sets the baseline, the second sees the count change
    // and takes the fetch-and-cache branch.
    void stubTwoPolls({required List<EmailModel> page}) {
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 3 : 6)];
      });
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => page);
    }

    // The replacement is one write with replaceFolder, not a clear followed by
    // a write: cacheEmails preserves an already-cached full body by looking the
    // old row up first, and a separate clear on the line before guaranteed that
    // lookup found nothing — so every poll that detected a change blanked every
    // cached body in the Inbox and BodyPrefetchService re-downloaded them.
    test('replaces the folder cache in a single write', () async {
      stubTwoPolls(page: [_email('still-here')]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      verifyNever(mockEmailLocalDatasource.clearCacheForFolder(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
      ));
      verify(mockEmailLocalDatasource.cacheEmails(
        accountId: _gmailAccount.id,
        folderId: 'inbox-id',
        emails: anyNamed('emails'),
        replaceFolder: true,
      )).called(1);
    });

    // An empty page is far more likely a transient than a genuinely emptied
    // folder, and replacing on it would blank the cache for an offline repaint.
    // The guard now lives inside cacheEmails — which the poller calls
    // unconditionally — so what matters here is that nothing clears the folder.
    test('leaves the cache alone when the synced page comes back empty',
        () async {
      stubTwoPolls(page: const []);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      verifyNever(mockEmailLocalDatasource.clearCacheForFolder(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
      ));
    });
  });

  // ---------------------------------------------------------------------------
  // The very first poll must report the active account's counts as changed when
  // they disagree with the cache the badge was primed from.
  //
  // Regression: NightMail opened showing 2 in the Inbox when 27 were waiting.
  // A cold-start folder fetch that fails is swallowed in favour of the cache
  // (FolderListBloc), so the first poll is the only thing that can notice the
  // counts on screen are yesterday's — and it used to spend that one look
  // establishing its baseline, overwriting the primed value and then agreeing
  // with the server forever after.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — first poll against a stale primed cache', () {
    late MockEmailRemoteDatasource mockGmailDs;

    EmailFolder cachedInbox({required int unread, required int total}) =>
        EmailFolder(
          id: 'inbox-id',
          displayName: 'Inbox',
          totalItemCount: total,
          unreadItemCount: unread,
          isHidden: false,
          childFolderCount: 0,
        );

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_gmailAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => [_email('fresh-1')]);
    });

    test('increments pollGeneration when the cached count is stale', () async {
      when(mockGetCachedFolders(any)).thenAnswer(
        (_) async => Right([cachedInbox(unread: 2, total: 2)]),
      );
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 27)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 1);
    });

    test('re-caches the inbox page so the list repaints with the real mail',
        () async {
      when(mockGetCachedFolders(any)).thenAnswer(
        (_) async => Right([cachedInbox(unread: 2, total: 2)]),
      );
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 27)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockEmailLocalDatasource.cacheEmails(
        accountId: _gmailAccount.id,
        folderId: 'inbox-id',
        emails: anyNamed('emails'),
        replaceFolder: true,
      )).called(1);
    });

    // The common case: nothing arrived while the app was closed. One cold start
    // must not cost a redundant inbox fetch and repaint.
    test('does not increment when the cached count already agrees', () async {
      when(mockGetCachedFolders(any)).thenAnswer(
        (_) async => Right([cachedInbox(unread: 7, total: 100)]),
      );
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 7)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 0);
      verifyNever(mockGmailDs.getEmails(
          folderId: anyNamed('folderId'), top: anyNamed('top')));
    });

    // A total that moved while unread did not is still a stale list: mail was
    // read elsewhere and new mail arrived, or something was deleted.
    test('increments when only the cached total is stale', () async {
      when(mockGetCachedFolders(any)).thenAnswer(
        (_) async => Right([cachedInbox(unread: 7, total: 40)]),
      );
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 7)]); // total 100

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 1);
    });

    // Non-active accounts keep priming on the first cycle, so unread mail that
    // was already there when NightMail opened doesn't announce itself as new.
    test('a non-active account still primes silently', () async {
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockGetCachedFolders(any)).thenAnswer(
        (_) async => Right([cachedInbox(unread: 2, total: 2)]),
      );
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 27)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 0);
      verifyNever(mockEmailLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: anyNamed('emails'),
      ));
    });
  });

  // ---------------------------------------------------------------------------
  // Microsoft pre-delta active account — pollGeneration must increment on
  // unread increase (regression: same missing flag before delta token exists)
  // ---------------------------------------------------------------------------

  group(
      'MailPollerCubit — Microsoft pre-delta active account, '
      'pollGeneration triggered by unread increase',
      () {
    setUp(() {
      // No delta token: both polls stay in the folder-polling path.
      // syncMailDelta succeeds once (bootstrap after poll 1), then throws so
      // the second bootstrap attempt fails silently and does not add a
      // spurious pollGeneration increment — isolating the unread-change signal.
      var syncCallCount = 0;
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => null);
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async {
        syncCallCount++;
        if (syncCallCount > 1) throw Exception('second bootstrap not expected');
        return _emptyDelta();
      });
    });

    test('pollGeneration increments when unread count rises', () async {
      var callCount = 0;
      when(mockGraphDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 2 : 5)];
      });

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      // Poll 1: sets baseline (2 unread). Bootstrap completes and emits
      // pollGeneration+1 to flush any stale cache after initial delta sync.
      await cubit.initialize();
      await pumpEventQueue();
      expect(cubit.state.pollGeneration, 1);

      // Poll 2: unread jumped to 5 — must increment again.
      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 2);
    });

    test('pollGeneration does NOT increment when unread count is unchanged',
        () async {
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 4)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      // Bootstrap emits pollGeneration+1 once after poll 1.
      await cubit.initialize();
      await pumpEventQueue();

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      // Second bootstrap fails silently; unread unchanged → no additional
      // increment beyond the initial bootstrap.
      expect(cubit.state.pollGeneration, 1);
    });
  });

  // ---------------------------------------------------------------------------
  // Microsoft delta active account — pollGeneration increments (existing path,
  // adding explicit coverage)
  // ---------------------------------------------------------------------------

  group(
      'MailPollerCubit — Microsoft delta active account, '
      'pollGeneration increments on new unread',
      () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: [_email('new-msg', isRead: false)],
                removedIds: [],
                deltaLink: _newToken,
              ));
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 3)]);
    });

    test('pollGeneration increments for active account with new unread delta',
        () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, greaterThan(0));
    });
  });

  // ---------------------------------------------------------------------------
  // The delta stream must always have a way back.
  //
  // Regression: only a 410 cleared a stored delta token, and the token lives in
  // a persistent table. So a link Graph answers 400 or 404 — Graph escapes its
  // own separators inside a delta link, so a stored one can be rejected
  // outright — left the account fetching nothing, caching nothing and bumping
  // nothing on every cycle for the rest of the install's life, silently.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — delta recovery', () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 3)]);
    });

    for (final status in [400, 404, 410]) {
      test('a $status from syncMailDelta clears the stored token', () async {
        when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
            .thenThrow(ServerException(
                message: 'rejected', statusCode: status));

        final cubit = _makeCubit();
        addTearDown(cubit.close);

        await cubit.initialize();
        await pumpEventQueue();

        verify(mockDatabase.clearDeltaTokensForAccount(_msAccount.id))
            .called(1);
        expect(cubit.state.lastPollErrors, contains(_msAccount.id));
      });
    }

    // "Delta query completed without returning a delta link" arrives with no
    // status at all, and was the one case that could never recover.
    test('a status-less ServerException clears the stored token', () async {
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenThrow(const ServerException(message: 'no delta link'));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockDatabase.clearDeltaTokensForAccount(_msAccount.id)).called(1);
    });

    // A failure with no recognised status must not be permanent either.
    test('three consecutive unrecognised failures clear the token', () async {
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenThrow(Exception('transport blew up'));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      verifyNever(mockDatabase.clearDeltaTokensForAccount(any));

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();
      verifyNever(mockDatabase.clearDeltaTokensForAccount(any));

      await cubit.updatePollInterval(9998);
      await pumpEventQueue();
      verify(mockDatabase.clearDeltaTokensForAccount(_msAccount.id)).called(1);
    });

    // A delta link is a one-shot receipt. Advancing it before the page it
    // acknowledges has been applied loses those changes for good: the next cycle
    // asks from the new link and is told nothing has changed.
    test('does not save the delta token when the cache write fails', () async {
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: [_email('new-msg')],
                removedIds: const [],
                deltaLink: _newToken,
              ));
      when(mockEmailLocalDatasource.cacheEmails(
        accountId: anyNamed('accountId'),
        folderId: anyNamed('folderId'),
        emails: anyNamed('emails'),
        replaceFolder: anyNamed('replaceFolder'),
      )).thenThrow(Exception('disk full'));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verifyNever(mockDatabase.saveDeltaToken(any, any, _newToken));
    });

    // The list repaints from cache as soon as pollGeneration bumps, so a removal
    // still in flight would let a message deleted elsewhere survive the repaint.
    test('deletes removed ids before emitting pollGeneration', () async {
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: const [],
                removedIds: const ['gone-1'],
                deltaLink: _newToken,
              ));

      final cubit = _makeCubit();
      addTearDown(cubit.close);
      final generationSeen = <int>[];
      cubit.stream.listen((s) => generationSeen.add(s.pollGeneration));

      await cubit.initialize();
      await pumpEventQueue();

      verifyInOrder([
        mockEmailLocalDatasource.deleteEmailFromCache(
          accountId: _msAccount.id,
          emailId: 'gone-1',
        ),
        mockBadgeService.setBadgeCount(any),
      ]);
      expect(generationSeen, isNotEmpty);
    });

    // A move, not a delete: the message still exists, so its cached inline
    // images must not be thrown away for the destination folder to re-download.
    test('a moved-out message keeps its cached inline images', () async {
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: const [],
                removedIds: const [],
                movedOutIds: const ['moved-1'],
                deltaLink: _newToken,
              ));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      verify(mockEmailLocalDatasource.deleteEmailFromCache(
        accountId: _msAccount.id,
        emailId: 'moved-1',
        evictInlineAttachments: false,
      )).called(1);
    });
  });

  // ---------------------------------------------------------------------------
  // The envelope's "new mail" flag clears on a real read, not on switching
  // to the account — the account-switch call that used to clear it eagerly
  // (markAccountViewed) is gone; only an actual unread-count change does.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — new-mail flag tracks real reads', () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.syncMailDelta(any,
              deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => MailDeltaResult(
                upserted: [_email('msg-1', isRead: false)],
                removedIds: [],
                deltaLink: _newToken,
              ));
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 1)]);
    });

    test('flags the active account too while it has real unread mail',
        () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.accountsWithNewMail, contains(_msId));
    });

    test('decrementUnreadCount clears it the instant unread hits zero',
        () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      expect(cubit.state.accountsWithNewMail, contains(_msId));

      cubit.decrementUnreadCount();

      expect(cubit.state.accountsWithNewMail, isNot(contains(_msId)));
    });
  });

  // ---------------------------------------------------------------------------
  // Auth failures must surface instead of being silently swallowed
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // A poll that fails must not look like a quiet mailbox.
  //
  // Regression: every failure other than a 410 hit a bare `catch (_)`. The
  // account wrote no cache, bumped no generation, raised no banner and logged
  // nothing — so a *deterministic* failure (a stored delta link the server
  // answers 400, a delta response carrying no delta link) persisted across
  // restarts with mail simply never updating.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — failure reporting', () {
    late MockEmailRemoteDatasource mockGmailDs;

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_gmailAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
    });

    test('records a per-account error and still stamps lastPollAt', () async {
      when(mockGmailDs.getMailFolders())
          .thenThrow(Exception('connection reset'));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.lastPollErrors, contains(_gmailAccount.id));
      expect(cubit.state.lastPollErrors[_gmailAccount.id],
          contains('connection reset'));
      expect(cubit.state.hasPollErrors, isTrue);
      expect(cubit.state.lastPollAt, isNotNull);
    });

    test('a successful cycle clears the previous cycle\'s errors', () async {
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) throw Exception('transient');
        return [_inbox(unread: 1)];
      });

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      expect(cubit.state.hasPollErrors, isTrue);

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(cubit.state.lastPollErrors, isEmpty);
    });

    // The offline branch returns before the cycle runs, so it has to stamp the
    // state itself — a probe stuck on offline is otherwise indistinguishable
    // from a mailbox with nothing in it, and `onReconnected` needs a false→true
    // edge a stuck probe never produces.
    test('reports being skipped while offline', () async {
      when(mockConnectivityService.isOnline).thenAnswer((_) async => false);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.hasPollErrors, isTrue);
      expect(cubit.state.lastPollErrors.values.join(), contains('offline'));
      expect(cubit.state.lastPollAt, isNotNull);
    });

    // Regression: `_polling = true` was latched before the try whose finally
    // cleared it, with drainAll() in between. One throw there stopped polling
    // for every account for the lifetime of the process.
    test('a throwing outbox drain does not stop the next cycle polling',
        () async {
      when(mockOutboxDrainService.drainAll())
          .thenThrow(Exception('drain exploded'));
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 2)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      // Two cycles reached the provider, so _polling was released each time.
      verify(mockGmailDs.getMailFolders()).called(2);
    });
  });

  // ---------------------------------------------------------------------------
  // The folder on screen is synced too, and the UI is told which folders a
  // repaint-from-cache is valid for.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — watched folder', () {
    late MockEmailRemoteDatasource mockGmailDs;

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_gmailAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
      when(mockGmailDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 3)]);
    });

    test('fetches and replaces the cache of the folder on screen', () async {
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => [_email('archived-1')]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      // Selecting a folder polls straight away rather than leaving the user on
      // a cache that may be a whole interval old.
      cubit.setWatchedFolder('archive-id');
      await pumpEventQueue();

      verify(mockGmailDs.getEmails(folderId: 'archive-id', top: 25)).called(1);
      verify(mockEmailLocalDatasource.cacheEmails(
        accountId: _gmailAccount.id,
        folderId: 'archive-id',
        emails: anyNamed('emails'),
        replaceFolder: true,
      )).called(1);
      expect(cubit.state.syncedFolderIds, contains('archive-id'));
    });

    // The Inbox is synced every cycle whether or not it is showing, so naming it
    // as the watched folder must not fetch it twice.
    test('does not double-sync when the Inbox is the folder on screen',
        () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      cubit.setWatchedFolder('inbox-id');
      await pumpEventQueue();

      verifyNever(mockGmailDs.getEmails(folderId: 'inbox-id', top: 25));
    });

    // A repaint is only valid for a folder whose cache this cycle actually
    // wrote; the UI reads this to decide cache-repaint versus network refresh.
    test('reports no synced folders when nothing changed', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.syncedFolderIds, isEmpty);
    });

    // Regression: a page's two sides do not arrive in the same order — a cached
    // page is newest-first, a provider's listing is grouped by thread — so
    // comparing index against index found a change in an unchanged folder on
    // every single cycle, and each one bumped pollGeneration: a full folder-list
    // reload (one request per Gmail label) and list refresh, every interval,
    // for ever.
    test('reports no change when the same page arrives in another order',
        () async {
      final older = _email('older', receivedDateTime: '2026-06-11T09:00:00Z');
      final newer = _email('newer', receivedDateTime: '2026-06-11T10:00:00Z');
      // Thread-grouped, as a provider returns it.
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => [older, newer]);
      // Newest-first, as the cache returns it.
      when(mockEmailLocalDatasource.getCachedEmails(
        accountId: anyNamed('accountId'),
        folderId: 'archive-id',
      )).thenAnswer((_) async => [newer, older]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      final generationBefore = cubit.state.pollGeneration;

      cubit.setWatchedFolder('archive-id');
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, generationBefore);
    });

    // The other half of the same regression: a cached row whose body has been
    // fetched carries the attachments that came with it, and the list projection
    // it is compared against carries none. Full entity equality therefore
    // disagreed for ever — on exactly the messages the user opens.
    test('reports no change when a cached row has a fetched body\'s extras',
        () async {
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => [_email('msg-1')]);
      when(mockEmailLocalDatasource.getCachedEmails(
        accountId: anyNamed('accountId'),
        folderId: 'archive-id',
      )).thenAnswer((_) async => [
            _email('msg-1', attachments: [
              {'id': 'att-1', 'name': 'report.pdf', 'size': 12},
            ]),
          ]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      final generationBefore = cubit.state.pollGeneration;

      cubit.setWatchedFolder('archive-id');
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, generationBefore);
    });

    // ...but a real change still has to register.
    test('reports a change when a row was read elsewhere', () async {
      when(mockGmailDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => [_email('msg-1', isRead: true)]);
      when(mockEmailLocalDatasource.getCachedEmails(
        accountId: anyNamed('accountId'),
        folderId: 'archive-id',
      )).thenAnswer((_) async => [_email('msg-1', isRead: false)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      final generationBefore = cubit.state.pollGeneration;

      cubit.setWatchedFolder('archive-id');
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, generationBefore + 1);
    });
  });

  // ---------------------------------------------------------------------------
  // A quiet delta must cost one request.
  //
  // Regression: the delta branch only resolved the Inbox's real id when it had
  // changes to report, so on a quiet cycle the watched-folder step could not
  // tell the Inbox from a second folder and re-fetched the whole page — then
  // compared it against the cache, and (see _samePage above) declared it
  // changed. A quiet mailbox reloaded the folder list and the message list on
  // every interval.
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — quiet delta with the Inbox on screen', () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => _savedToken);
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => _emptyDelta());
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 3)]);
      when(mockGraphDs.getEmails(
              folderId: anyNamed('folderId'), top: anyNamed('top')))
          .thenAnswer((_) async => [_email('msg-1')]);
    });

    test('does not re-fetch the Inbox as if it were a second folder', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      // The first cycle primed the count, so the Inbox's id is known even though
      // this cycle's delta has nothing to say.
      cubit.setWatchedFolder('inbox-id');
      await pumpEventQueue();

      verifyNever(mockGraphDs.getEmails(
          folderId: anyNamed('folderId'), top: anyNamed('top')));
      expect(cubit.state.pollGeneration, 0);
    });

    // The same, for the cold start the badge was primed from cache on: no cycle
    // fetches folders at all there, so the id has to come from the same cached
    // rows the count did.
    test('knows the Inbox from the cache the badge was primed from', () async {
      when(mockGetCachedFolders(any))
          .thenAnswer((_) async => Right([_inbox(unread: 3)]));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      cubit.setWatchedFolder('inbox-id');
      await cubit.initialize();
      await pumpEventQueue();

      verifyNever(mockGraphDs.getEmails(
          folderId: anyNamed('folderId'), top: anyNamed('top')));
    });
  });

  group('MailPollerCubit — auth failure handling', () {
    late MockEmailRemoteDatasource mockGmailDs;

    setUp(() {
      mockGmailDs = MockEmailRemoteDatasource();
      when(mockAccountManager.accounts).thenReturn([_gmailAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_gmailAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGmailDs);
    });

    test('flags the account in accountsNeedingReauth on AuthException',
        () async {
      when(mockGmailDs.getMailFolders())
          .thenThrow(const AuthException(message: 'Session expired'));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state.accountsNeedingReauth, contains(_gmailAccount.id));
    });

    test('does not crash the cubit on AuthException', () async {
      when(mockGmailDs.getMailFolders())
          .thenThrow(const AuthException(message: 'Session expired'));

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      expect(() async {
        await cubit.initialize();
        await pumpEventQueue();
      }, returnsNormally);
    });

    test('clears accountsNeedingReauth once polling succeeds again',
        () async {
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        if (callCount == 1) {
          throw const AuthException(message: 'Session expired');
        }
        return [_inbox(unread: 2)];
      });

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();
      expect(cubit.state.accountsNeedingReauth, contains(_gmailAccount.id));

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(
          cubit.state.accountsNeedingReauth, isNot(contains(_gmailAccount.id)));
    });
  });
}
