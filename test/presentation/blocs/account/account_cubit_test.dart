import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/repositories/email_repository.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/calendar/calendar_cache_sync_service.dart';
import 'package:nightmail/infrastructure/contacts/contact_cache_sync_service.dart';
import 'package:nightmail/infrastructure/notifications/calendar_reminder_service.dart';
import 'package:nightmail/infrastructure/notifications/task_reminder_service.dart';
import 'package:nightmail/presentation/blocs/account/account_cubit.dart';

import 'account_cubit_test.mocks.dart';

const _account1 = GmailAccount(
  id: 'acct-1',
  displayName: 'One',
  emailAddress: 'one@example.com',
);
const _account2 = GmailAccount(
  id: 'acct-2',
  displayName: 'Two',
  emailAddress: 'two@example.com',
);

@GenerateMocks([
  AccountManager,
  EmailRepository,
  CalendarReminderService,
  CalendarCacheSyncService,
  ContactCacheSyncService,
  TaskReminderService,
])
void main() {
  late MockAccountManager mockAccountManager;
  late MockEmailRepository mockEmailRepository;
  late MockCalendarReminderService mockCalendarReminderService;
  late MockCalendarCacheSyncService mockCalendarCacheSync;
  late MockContactCacheSyncService mockContactCacheSync;
  late MockTaskReminderService mockTaskReminderService;
  late StreamController<String> authFailures;
  late StreamController<String> authSuccesses;
  late AccountCubit cubit;

  AccountCubit makeCubit() => AccountCubit(
        accountManager: mockAccountManager,
        emailRepository: mockEmailRepository,
        calendarReminderService: mockCalendarReminderService,
        calendarCacheSync: mockCalendarCacheSync,
        contactCacheSync: mockContactCacheSync,
        taskReminderService: mockTaskReminderService,
      );

  setUp(() {
    // Mockito cannot auto-generate dummy values for sealed/abstract types
    // like Either, so we register one explicitly.
    provideDummy<Either<Failure, Unit>>(const Right(unit));
    provideDummy<Account>(_account1);

    mockAccountManager = MockAccountManager();
    mockEmailRepository = MockEmailRepository();
    mockCalendarReminderService = MockCalendarReminderService();
    mockCalendarCacheSync = MockCalendarCacheSyncService();
    mockContactCacheSync = MockContactCacheSyncService();
    mockTaskReminderService = MockTaskReminderService();
    authFailures = StreamController<String>.broadcast();
    authSuccesses = StreamController<String>.broadcast();

    when(mockAccountManager.authFailures).thenAnswer((_) => authFailures.stream);
    when(mockAccountManager.authSuccesses).thenAnswer((_) => authSuccesses.stream);
    when(mockAccountManager.getUnauthenticatedAccountIds())
        .thenAnswer((_) async => <String>{});
    when(mockAccountManager.accounts).thenReturn([_account1, _account2]);
    when(mockAccountManager.activeIndex).thenReturn(0);
    when(mockAccountManager.activeAccount).thenReturn(_account1);
    when(mockAccountManager.hasAccounts).thenReturn(true);
    when(mockCalendarCacheSync.syncAccount(any)).thenAnswer((_) async {});
    when(mockCalendarCacheSync.clearAccount(any)).thenAnswer((_) async {});
    when(mockContactCacheSync.syncAccount(any, force: anyNamed('force')))
        .thenAnswer((_) async {});
    when(mockContactCacheSync.clearAccount(any)).thenAnswer((_) async {});
    when(mockContactCacheSync.invalidateAccount(any)).thenAnswer((_) async {});
    when(mockEmailRepository.clearCacheForAccount(any))
        .thenAnswer((_) async => const Right(unit));
    when(mockCalendarReminderService.clearAccount(any)).thenAnswer((_) async {});
    when(mockTaskReminderService.clearAccount(any)).thenAnswer((_) async {});

    cubit = makeCubit();
  });

  tearDown(() async {
    await authFailures.close();
    await authSuccesses.close();
    if (!cubit.isClosed) await cubit.close();
  });

  group('construction', () {
    test('starts in AccountLoading', () {
      expect(cubit.state, isA<AccountLoading>());
    });
  });

  group('auth failure/success stream reactions', () {
    Future<void> makeLoaded() async {
      await cubit.initialize();
      // Let the unawaited post-init email-backfill re-emit (_doInitialize's
      // `ensureEmailPopulated().then(_emitLoaded)`) settle first, or it can
      // resolve *after* this test's own auth event and overwrite the
      // unauthenticatedAccountIds this test just set, purely because the
      // stubbed getUnauthenticatedAccountIds() always answers `{}` regardless
      // of when it's called.
      await pumpEventQueue();
      expect(cubit.state, isA<AccountsLoaded>());
    }

    test('an auth failure for a loaded account flags it unauthenticated',
        () async {
      await makeLoaded();

      authFailures.add('acct-1');
      await pumpEventQueue();

      final state = cubit.state as AccountsLoaded;
      expect(state.unauthenticatedAccountIds, {'acct-1'});
      expect(state.activeAccountNeedsReauth, isTrue);
    });

    test('a second failure for the same account does not duplicate/re-emit',
        () async {
      await makeLoaded();
      authFailures.add('acct-1');
      await pumpEventQueue();
      final afterFirst = cubit.state;

      authFailures.add('acct-1');
      await pumpEventQueue();

      // Equatable state is unchanged, so no meaningful second emission.
      expect(cubit.state, afterFirst);
    });

    test('an auth failure while not loaded is ignored', () async {
      // Still AccountLoading — initialize() was never called.
      authFailures.add('acct-1');
      await pumpEventQueue();

      expect(cubit.state, isA<AccountLoading>());
    });

    test('an auth success clears a previously flagged account', () async {
      await makeLoaded();
      authFailures.add('acct-1');
      await pumpEventQueue();
      expect((cubit.state as AccountsLoaded).unauthenticatedAccountIds,
          {'acct-1'});

      authSuccesses.add('acct-1');
      await pumpEventQueue();

      expect(
        (cubit.state as AccountsLoaded).unauthenticatedAccountIds,
        isEmpty,
      );
    });

    test('an auth success for an account that was never flagged does nothing',
        () async {
      await makeLoaded();
      final before = cubit.state;

      authSuccesses.add('acct-1');
      await pumpEventQueue();

      expect(cubit.state, before);
    });
  });

  group('close', () {
    test('cancels the auth stream subscriptions', () async {
      await cubit.initialize();
      await cubit.close();

      // If the subscriptions were not cancelled, this would attempt to
      // `emit` on a closed cubit and throw inside the stream callback.
      expect(() => authFailures.add('acct-1'), returnsNormally);
      await pumpEventQueue();
    });
  });

  group('initialize', () {
    test('emits AccountLoading, then AccountsLoaded when accounts exist',
        () async {
      final states = <dynamic>[];
      final sub = cubit.stream.listen(states.add);

      await cubit.initialize();
      await pumpEventQueue();

      expect(cubit.state, isA<AccountsLoaded>());
      final loaded = cubit.state as AccountsLoaded;
      expect(loaded.accounts, [_account1, _account2]);
      expect(loaded.activeIndex, 0);
      expect(loaded.activeAccount, _account1);
      await sub.cancel();
    });

    test('emits AccountNoAccounts when there are none', () async {
      when(mockAccountManager.hasAccounts).thenReturn(false);

      await cubit.initialize();

      expect(cubit.state, isA<AccountNoAccounts>());
      verifyNever(mockAccountManager.getUnauthenticatedAccountIds());
    });

    test('re-emits loaded after the background email backfill completes',
        () async {
      final backfillCompleter = Completer<void>();
      when(mockAccountManager.ensureEmailPopulated())
          .thenAnswer((_) => backfillCompleter.future);

      await cubit.initialize();
      // getUnauthenticatedAccountIds was called once for the first emit.
      verify(mockAccountManager.getUnauthenticatedAccountIds()).called(1);

      backfillCompleter.complete();
      await pumpEventQueue();

      // A second, quiet re-emit happened after the backfill resolved.
      verify(mockAccountManager.getUnauthenticatedAccountIds()).called(1);
    });

    test('a concurrent initialize() call reuses the in-flight attempt',
        () async {
      final initCompleter = Completer<void>();
      when(mockAccountManager.initialize())
          .thenAnswer((_) => initCompleter.future);

      final first = cubit.initialize();
      final second = cubit.initialize();

      initCompleter.complete();
      await first;
      await second;

      verify(mockAccountManager.initialize()).called(1);
    });

    test('a failure that is not the iOS keychain-interaction case reports '
        'AccountError once, without retrying', () async {
      when(mockAccountManager.initialize())
          .thenThrow(Exception('disk unavailable'));

      await cubit.initialize();

      expect(cubit.state, isA<AccountError>());
      expect(
        (cubit.state as AccountError).message,
        contains('disk unavailable'),
      );
      // Only the one attempt — this is not the iOS keychain-retry path,
      // which is gated on Platform.isIOS and unreachable when running tests
      // on a non-iOS host (dart:io Platform reflects the actual test
      // process, not the app's target platform), so that branch cannot be
      // exercised from this suite.
      verify(mockAccountManager.initialize()).called(1);
    });

    // NOTE: the 10-second timeout branch (initialize() wrapping
    // _doInitialize() in `.timeout(const Duration(seconds: 10))`) is not
    // exercised here — this suite has no fake_async/time-control harness in
    // use elsewhere, and waiting out a real 10s timeout per test is not
    // worth the cost. The reachable success/failure/concurrency branches
    // above are covered instead.
  });

  group('addAccount', () {
    setUp(() {
      when(mockAccountManager.prefillOwnProfileFields(any))
          .thenAnswer((_) async => false);
    });

    test('adds the account, reloads, and kicks off background contact/'
        'calendar syncs', () async {
      when(mockAccountManager.addAccount(any)).thenAnswer((_) async {});

      await cubit.addAccount(_account1);
      await pumpEventQueue();

      verify(mockAccountManager.addAccount(_account1)).called(1);
      expect(cubit.state, isA<AccountsLoaded>());
      verify(mockContactCacheSync.syncAccount('acct-1', force: true))
          .called(1);
      verify(mockCalendarCacheSync.syncAccount('acct-1')).called(1);
    });

    test('a failing background contact sync does not surface as an error',
        () async {
      when(mockAccountManager.addAccount(any)).thenAnswer((_) async {});
      when(mockContactCacheSync.syncAccount(any, force: anyNamed('force')))
          .thenThrow(Exception('network down'));

      await cubit.addAccount(_account1);
      await pumpEventQueue();

      expect(cubit.state, isA<AccountsLoaded>());
    });

    test('prefills the new account\'s profile fields automatically and '
        're-emits once they are saved', () async {
      when(mockAccountManager.addAccount(any)).thenAnswer((_) async {});
      final prefilled = _account1.copyWith(firstName: 'Ada', lastName: 'L');
      when(mockAccountManager.prefillOwnProfileFields('acct-1'))
          .thenAnswer((_) async {
        // The manager has persisted the fetched fields by the time it
        // answers; subsequent reads see the prefilled account.
        when(mockAccountManager.accounts).thenReturn([prefilled, _account2]);
        return true;
      });

      final states = <AccountState>[];
      final sub = cubit.stream.listen(states.add);
      await cubit.addAccount(_account1);
      await pumpEventQueue();
      await sub.cancel();

      verify(mockAccountManager.prefillOwnProfileFields('acct-1')).called(1);
      // One AccountsLoaded from addAccount itself, a second once the
      // prefilled profile has been persisted so Settings picks it up.
      final loaded = states.whereType<AccountsLoaded>().toList();
      expect(loaded.length, 2);
      expect(loaded.last.accounts.first.firstName, 'Ada');
    });

    test('does not re-emit when there was nothing to prefill', () async {
      when(mockAccountManager.addAccount(any)).thenAnswer((_) async {});

      final states = <AccountState>[];
      final sub = cubit.stream.listen(states.add);
      await cubit.addAccount(_account1);
      await pumpEventQueue();
      await sub.cancel();

      expect(states.whereType<AccountsLoaded>().length, 1);
    });

    test('a failing profile prefill does not surface as an error', () async {
      when(mockAccountManager.addAccount(any)).thenAnswer((_) async {});
      when(mockAccountManager.prefillOwnProfileFields(any))
          .thenThrow(Exception('scope not granted'));

      await cubit.addAccount(_account1);
      await pumpEventQueue();

      expect(cubit.state, isA<AccountsLoaded>());
    });
  });

  group('resolveSharedMailboxCandidate', () {
    test('passes straight through to AccountManager', () async {
      when(mockAccountManager.resolveSharedMailboxCandidate(any, any))
          .thenAnswer((_) async =>
              (displayName: 'Shared', hasAccess: true, needsReauth: false));

      final result = await cubit.resolveSharedMailboxCandidate(
        'acct-1',
        'shared@example.com',
      );

      expect(result?.displayName, 'Shared');
      verify(mockAccountManager.resolveSharedMailboxCandidate(
              'acct-1', 'shared@example.com'))
          .called(1);
    });
  });

  group('addSharedMailbox', () {
    test('adds it, reloads, and kicks off background syncs for the new id',
        () async {
      const shared = GmailAccount(
        id: 'acct-shared',
        displayName: 'Shared',
        emailAddress: 'shared@example.com',
      );
      when(mockAccountManager.addSharedMailbox(
        parentAccountId: anyNamed('parentAccountId'),
        email: anyNamed('email'),
        displayName: anyNamed('displayName'),
      )).thenAnswer((_) async => shared);

      await cubit.addSharedMailbox(
        parentAccountId: 'acct-1',
        email: 'shared@example.com',
        displayName: 'Shared',
      );
      await pumpEventQueue();

      verify(mockContactCacheSync.syncAccount('acct-shared', force: true))
          .called(1);
      verify(mockCalendarCacheSync.syncAccount('acct-shared')).called(1);
    });
  });

  group('updateAccount', () {
    test('updates and reloads', () async {
      when(mockAccountManager.updateAccount(any)).thenAnswer((_) async {});

      await cubit.updateAccount(_account1);

      verify(mockAccountManager.updateAccount(_account1)).called(1);
      expect(cubit.state, isA<AccountsLoaded>());
    });
  });

  group('cycleAccount', () {
    test('cycles and reloads, returning the new active account', () async {
      when(mockAccountManager.cycleToNextAccount())
          .thenAnswer((_) async => _account2);

      final result = await cubit.cycleAccount();

      expect(result, _account2);
      expect(cubit.state, isA<AccountsLoaded>());
    });
  });

  group('switchToAccount', () {
    test('switches and reloads', () async {
      when(mockAccountManager.switchToAccount(any)).thenAnswer((_) async {});

      await cubit.switchToAccount(1);

      verify(mockAccountManager.switchToAccount(1)).called(1);
      expect(cubit.state, isA<AccountsLoaded>());
    });
  });

  group('removeAccount', () {
    test('clears mail, calendar-reminder, task-reminder, calendar and '
        'contact state, then reloads when accounts remain', () async {
      when(mockAccountManager.removeAccount(any)).thenAnswer((_) async {});

      await cubit.removeAccount('acct-2');

      verify(mockAccountManager.removeAccount('acct-2')).called(1);
      verify(mockEmailRepository.clearCacheForAccount('acct-2')).called(1);
      verify(mockCalendarReminderService.clearAccount('acct-2')).called(1);
      verify(mockTaskReminderService.clearAccount('acct-2')).called(1);
      verify(mockCalendarCacheSync.clearAccount('acct-2')).called(1);
      verify(mockContactCacheSync.clearAccount('acct-2')).called(1);
      expect(cubit.state, isA<AccountsLoaded>());
    });

    test('emits AccountNoAccounts when that was the last account', () async {
      when(mockAccountManager.removeAccount(any)).thenAnswer((_) async {});
      when(mockAccountManager.hasAccounts).thenReturn(false);

      await cubit.removeAccount('acct-1');

      expect(cubit.state, isA<AccountNoAccounts>());
    });

    test('a failing background calendar/contact clear does not stop the '
        'removal from completing', () async {
      when(mockAccountManager.removeAccount(any)).thenAnswer((_) async {});
      when(mockCalendarCacheSync.clearAccount(any))
          .thenThrow(Exception('disk error'));
      when(mockContactCacheSync.clearAccount(any))
          .thenThrow(Exception('disk error'));

      await cubit.removeAccount('acct-2');

      expect(cubit.state, isA<AccountsLoaded>());
    });
  });

  group('clearCache', () {
    test('returns null on success', () async {
      final result = await cubit.clearCache('acct-1');
      expect(result, isNull);
    });

    test('returns the failure message on failure', () async {
      when(mockEmailRepository.clearCacheForAccount(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'disk full')));

      final result = await cubit.clearCache('acct-1');

      expect(result, 'disk full');
    });
  });

  group('signOutActiveAccount', () {
    test('does nothing when there is no active account', () async {
      when(mockAccountManager.activeAccount).thenReturn(null);

      await cubit.signOutActiveAccount();

      verifyNever(mockAccountManager.signOutAccount(any));
    });

    test('signs out the active account and reloads', () async {
      when(mockAccountManager.signOutAccount(any)).thenAnswer((_) async {});

      await cubit.signOutActiveAccount();

      verify(mockAccountManager.signOutAccount('acct-1')).called(1);
      expect(cubit.state, isA<AccountsLoaded>());
    });
  });

  group('reauthenticateActiveOAuth', () {
    test('reauthenticates, reloads, and refetches contacts for the account '
        'that was active before the reauth', () async {
      when(mockAccountManager.reauthenticateActiveOAuth())
          .thenAnswer((_) async {});

      await cubit.reauthenticateActiveOAuth();
      await pumpEventQueue();

      verify(mockAccountManager.reauthenticateActiveOAuth()).called(1);
      verify(mockContactCacheSync.invalidateAccount('acct-1')).called(1);
    });

    test('does not refetch contacts when there was no active account',
        () async {
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockAccountManager.reauthenticateActiveOAuth())
          .thenAnswer((_) async {});

      await cubit.reauthenticateActiveOAuth();
      await pumpEventQueue();

      verifyNever(mockContactCacheSync.invalidateAccount(any));
    });
  });

  group('reauthenticateOAuthAccount', () {
    test('reauthenticates the named account, reloads, and refetches its '
        'contacts unconditionally', () async {
      when(mockAccountManager.reauthenticateOAuthAccount(any))
          .thenAnswer((_) async {});

      await cubit.reauthenticateOAuthAccount('acct-2');
      await pumpEventQueue();

      verify(mockAccountManager.reauthenticateOAuthAccount('acct-2'))
          .called(1);
      verify(mockContactCacheSync.invalidateAccount('acct-2')).called(1);
    });
  });

  group('reauthenticateActiveImap', () {
    test('does nothing when there is no active account', () async {
      when(mockAccountManager.activeAccount).thenReturn(null);

      await cubit.reauthenticateActiveImap('hunter2');

      verifyNever(mockAccountManager.reauthenticateImapAccount(any, any));
    });

    test('reauthenticates the active account with the given password and '
        'reloads', () async {
      when(mockAccountManager.reauthenticateImapAccount(any, any))
          .thenAnswer((_) async {});

      await cubit.reauthenticateActiveImap('hunter2');

      verify(mockAccountManager.reauthenticateImapAccount('acct-1', 'hunter2'))
          .called(1);
      expect(cubit.state, isA<AccountsLoaded>());
    });
  });
}
