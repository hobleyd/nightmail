import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/settings/app_settings.dart';
import 'package:nightmail/data/datasources/local/delta_token_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/data/models/email_folder_model.dart';
import 'package:nightmail/data/models/email_model.dart';
import 'package:nightmail/data/models/mail_delta_result.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/badge/badge_service.dart';
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

EmailModel _email(String id, {bool isRead = false}) => EmailModel.fromJson({
      'id': id,
      'subject': 'Subj',
      'from': {
        'emailAddress': {'address': 's@example.com', 'name': 'S'}
      },
      'toRecipients': <dynamic>[],
      'ccRecipients': <dynamic>[],
      'bodyPreview': '',
      'isRead': isRead,
      'receivedDateTime': '2026-06-11T10:00:00Z',
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
  DeltaTokenDatasource,
  GraphApiDatasourceImpl,
  EmailRemoteDatasource,
])
void main() {
  late MockAccountManager mockAccountManager;
  late MockAppSettings mockAppSettings;
  late MockBadgeService mockBadgeService;
  late MockDeltaTokenDatasource mockDatabase;
  late MockGraphApiDatasourceImpl mockGraphDs;

  MailPollerCubit _makeCubit() => MailPollerCubit(
        accountManager: mockAccountManager,
        appSettings: mockAppSettings,
        badgeService: mockBadgeService,
        database: mockDatabase,
      );

  void _stubInfra() {
    when(mockAppSettings.loadPollIntervalSeconds())
        .thenAnswer((_) async => 9999); // long — no repeated timer fires
    when(mockBadgeService.setBadgeCount(any)).thenAnswer((_) async {});
    when(mockDatabase.saveDeltaToken(any, any, any)).thenAnswer((_) async {});
    when(mockDatabase.clearDeltaTokensForAccount(any))
        .thenAnswer((_) async {});
  }

  setUp(() {
    mockAccountManager = MockAccountManager();
    mockAppSettings = MockAppSettings();
    mockBadgeService = MockBadgeService();
    mockDatabase = MockDeltaTokenDatasource();
    mockGraphDs = MockGraphApiDatasourceImpl();
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

    test('pollGeneration does NOT increment when unread count decreases',
        () async {
      var callCount = 0;
      when(mockGmailDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 5 : 2)];
      });

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 0);
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
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(_msAccount);
      when(mockAccountManager.buildEmailDatasourceForAccount(any))
          .thenReturn(mockGraphDs);
      // No delta token saved — stays in folder-polling path across both polls.
      // saveDeltaToken is stubbed as a no-op so loadDeltaToken keeps returning
      // null even after the async bootstrap completes.
      when(mockDatabase.loadDeltaToken(any, any))
          .thenAnswer((_) async => null);
      when(mockGraphDs.syncMailDelta(any, deltaLink: anyNamed('deltaLink')))
          .thenAnswer((_) async => _emptyDelta());
    });

    test('pollGeneration increments when unread count rises', () async {
      var callCount = 0;
      when(mockGraphDs.getMailFolders()).thenAnswer((_) async {
        callCount++;
        return [_inbox(unread: callCount == 1 ? 2 : 5)];
      });

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      // Poll 1: sets baseline (2 unread).
      await cubit.initialize();
      await pumpEventQueue();
      expect(cubit.state.pollGeneration, 0);

      // Poll 2: unread jumped to 5 — must increment.
      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 1);
    });

    test('pollGeneration does NOT increment when unread count is unchanged',
        () async {
      when(mockGraphDs.getMailFolders())
          .thenAnswer((_) async => [_inbox(unread: 4)]);

      final cubit = _makeCubit();
      addTearDown(cubit.close);

      await cubit.initialize();
      await pumpEventQueue();

      await cubit.updatePollInterval(9999);
      await pumpEventQueue();

      expect(cubit.state.pollGeneration, 0);
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
  // markAccountViewed
  // ---------------------------------------------------------------------------

  group('MailPollerCubit — markAccountViewed', () {
    setUp(() {
      when(mockAccountManager.accounts).thenReturn([_msAccount]);
      when(mockAccountManager.activeAccount).thenReturn(null);
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

    test('removes account from accountsWithNewMail', () async {
      final cubit = _makeCubit();
      addTearDown(cubit.close);

      // Poll first to establish new-mail state.
      await cubit.initialize();
      await pumpEventQueue();
      expect(cubit.state.accountsWithNewMail, contains(_msId));

      cubit.markAccountViewed(_msId);

      expect(cubit.state.accountsWithNewMail, isNot(contains(_msId)));
    });
  });
}
