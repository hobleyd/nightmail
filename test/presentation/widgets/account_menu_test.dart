import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/local/migration_local_datasource.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/migration/account_migration_service.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/account/account_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_state.dart';
import 'package:nightmail/presentation/blocs/migration/migration_cubit.dart';
import 'package:nightmail/presentation/blocs/migration/migration_state.dart';
import 'package:nightmail/presentation/widgets/folder_panel.dart';

import 'account_menu_test.mocks.dart';

const _msAccount = MicrosoftAccount(
  id: 'ms-1',
  displayName: 'Bob',
  emailAddress: 'b@corp.com',
  tenantId: 'tid',
);

const _gmailAccount = GmailAccount(
  id: 'gm-1',
  displayName: 'Alice',
  emailAddress: 'a@gmail.com',
);

const _emptyPollerState =
    MailPollerState(accountsWithNewMail: {}, pollIntervalSeconds: 300);

@GenerateMocks([AccountCubit, MailPollerCubit, MigrationCubit])
@GenerateNiceMocks([MockSpec<AccountMigrationService>()])
void main() {
  late MockAccountCubit mockAccountCubit;
  late MockMailPollerCubit mockMailPollerCubit;
  late MockAccountMigrationService mockAccountMigrationService;

  setUp(() {
    mockAccountCubit = MockAccountCubit();
    mockMailPollerCubit = MockMailPollerCubit();
    // Mockito needs a dummy of each cubit's sealed state type just to record
    // a `when(cubit.state)` stub, even though it's immediately overridden.
    provideDummy<AccountState>(const AccountNoAccounts());
    provideDummy<MailPollerState>(_emptyPollerState);
    when(mockMailPollerCubit.stream).thenAnswer((_) => const Stream.empty());
    when(mockMailPollerCubit.state).thenReturn(_emptyPollerState);
    when(mockAccountCubit.stream).thenAnswer((_) => const Stream.empty());
    // AccountMenu polls this on every build with an active account to decide
    // between "Migrate Account…" and "Migration Status" — a nice mock
    // answers null (no active migration) without every test needing its own
    // stub for it.
    mockAccountMigrationService = MockAccountMigrationService();
    sl.registerLazySingleton<AccountMigrationService>(
        () => mockAccountMigrationService);
  });

  tearDown(() async => sl.reset());

  Widget wrap() => MaterialApp(
        home: Scaffold(
          body: MultiBlocProvider(
            providers: [
              BlocProvider<AccountCubit>.value(value: mockAccountCubit),
              BlocProvider<MailPollerCubit>.value(value: mockMailPollerCubit),
            ],
            child: const AccountMenu(),
          ),
        ),
      );

  group('AccountMenu — the account switcher moved here from the bottom icon', () {
    testWidgets(
        'lists accounts, then Add Account, then Add Shared Mailbox for a '
        'Microsoft account, in that order', (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_msAccount],
        activeIndex: 0,
      ));

      await tester.pumpWidget(wrap());
      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      // 'Bob' now appears twice: the trigger label underneath the open menu,
      // and the account row inside it — the row is what ordering is measured
      // against.
      expect(find.text('Bob'), findsNWidgets(2));
      expect(find.text('Add Account'), findsOneWidget);
      expect(find.text('Add Shared Mailbox…'), findsOneWidget);

      final accountY = tester.getTopLeft(find.text('Bob').last).dy;
      final addAccountY = tester.getTopLeft(find.text('Add Account')).dy;
      final addSharedY =
          tester.getTopLeft(find.text('Add Shared Mailbox…')).dy;

      expect(addAccountY, greaterThan(accountY));
      expect(addSharedY, greaterThan(addAccountY));
    });

    testWidgets('offers no Add Shared Mailbox entry for a Gmail account',
        (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_gmailAccount],
        activeIndex: 0,
      ));

      await tester.pumpWidget(wrap());
      await tester.tap(find.text('Alice'));
      await tester.pumpAndSettle();

      expect(find.text('Add Account'), findsOneWidget);
      expect(find.text('Add Shared Mailbox…'), findsNothing);
    });

    testWidgets('lists every configured account, active one checked',
        (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_gmailAccount, _msAccount],
        activeIndex: 1,
      ));

      await tester.pumpWidget(wrap());
      // The trigger shows the active account's name.
      expect(find.text('Bob'), findsOneWidget);

      await tester.tap(find.text('Bob'));
      await tester.pumpAndSettle();

      // Both accounts are listed once the menu is open (one 'Bob' remains
      // the trigger label underneath the open menu, one is the menu row).
      expect(find.text('Alice'), findsOneWidget);
      expect(find.text('Bob'), findsWidgets);
    });
  });

  group('Migrate Account…', () {
    testWidgets(
        'is offered, below Add Shared Mailbox, once more than one account '
        'is configured', (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_msAccount, _gmailAccount],
        activeIndex: 0,
      ));

      await tester.pumpWidget(wrap());
      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      expect(find.text('Migrate Account…'), findsOneWidget);
      final addSharedY =
          tester.getTopLeft(find.text('Add Shared Mailbox…')).dy;
      final migrateY = tester.getTopLeft(find.text('Migrate Account…')).dy;
      expect(migrateY, greaterThan(addSharedY));
    });

    testWidgets('is not offered when only one account is configured',
        (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_msAccount],
        activeIndex: 0,
      ));

      await tester.pumpWidget(wrap());
      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      expect(find.text('Migrate Account…'), findsNothing);
    });

    testWidgets('opens a submenu listing every account except the active one',
        (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_msAccount, _gmailAccount],
        activeIndex: 0,
      ));

      await tester.pumpWidget(wrap());
      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Migrate Account…'));
      await tester.pumpAndSettle();

      // The active account (Bob) is never offered as its own migration
      // target; the other configured account (Alice) is.
      expect(find.text('a@gmail.com'), findsOneWidget);
      expect(find.text('b@corp.com'), findsNothing);
    });
  });

  group('Migration Status', () {
    MigrationJobRecord activeJob({required String source, required String target}) =>
        MigrationJobRecord(
          id: '$source|$target',
          sourceAccountId: source,
          targetAccountId: target,
          status: MigrationJobStatus.running,
          createdAtMs: 0,
          updatedAtMs: 0,
          lastError: null,
        );

    testWidgets(
        'replaces Migrate Account… with Migration Status once a migration '
        'is already running for the active account', (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_msAccount, _gmailAccount],
        activeIndex: 0,
      ));
      when(mockAccountMigrationService.getActiveJobForSource('ms-1'))
          .thenAnswer(
              (_) async => activeJob(source: 'ms-1', target: 'gm-1'));

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      expect(find.text('Migration Status'), findsOneWidget);
      expect(find.text('Migrate Account…'), findsNothing);
    });

    testWidgets(
        'keeps Migrate Account… when no migration is running for the '
        'active account', (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_msAccount, _gmailAccount],
        activeIndex: 0,
      ));
      // The nice mock's default (unstubbed) answer is null already; no
      // explicit stub needed to exercise the "no active job" branch.

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      expect(find.text('Migrate Account…'), findsOneWidget);
      expect(find.text('Migration Status'), findsNothing);
    });

    testWidgets(
        'tapping Migration Status opens the dialog directly for the '
        "job's own target, without the account picker", (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_msAccount, _gmailAccount],
        activeIndex: 0,
      ));
      when(mockAccountMigrationService.getActiveJobForSource('ms-1'))
          .thenAnswer(
              (_) async => activeJob(source: 'ms-1', target: 'gm-1'));

      final mockMigrationCubit = MockMigrationCubit();
      provideDummy<MigrationState>(const MigrationState());
      when(mockMigrationCubit.stream).thenAnswer((_) => const Stream.empty());
      when(mockMigrationCubit.state).thenReturn(const MigrationState());
      when(mockMigrationCubit.startOrResume(any, any))
          .thenAnswer((_) async {});
      sl.registerLazySingleton<MigrationCubit>(() => mockMigrationCubit);

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Migration Status'));
      // Not pumpAndSettle: the dialog's loading state draws an indeterminate
      // CircularProgressIndicator, which animates forever and would hang it.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      verify(mockMigrationCubit.startOrResume('ms-1', 'gm-1')).called(1);
      // Labels come from the accounts' own email addresses, resolved
      // straight from the job's targetAccountId — no intervening picker
      // step to have chosen the target from.
      expect(find.text('Migrating b@corp.com → a@gmail.com'), findsOneWidget);
    });

    testWidgets(
        'reverts to Migrate Account… once the dialog closes and the job is '
        'no longer active', (tester) async {
      when(mockAccountCubit.state).thenReturn(const AccountsLoaded(
        accounts: [_msAccount, _gmailAccount],
        activeIndex: 0,
      ));
      var checkCount = 0;
      when(mockAccountMigrationService.getActiveJobForSource('ms-1'))
          .thenAnswer((_) async {
        checkCount++;
        // Still running on the first check (menu opens); finished by the
        // second (the refresh fired when the dialog closes).
        return checkCount == 1
            ? activeJob(source: 'ms-1', target: 'gm-1')
            : null;
      });

      final mockMigrationCubit = MockMigrationCubit();
      provideDummy<MigrationState>(const MigrationState());
      when(mockMigrationCubit.stream).thenAnswer((_) => const Stream.empty());
      when(mockMigrationCubit.state).thenReturn(const MigrationState());
      when(mockMigrationCubit.startOrResume(any, any))
          .thenAnswer((_) async {});
      sl.registerLazySingleton<MigrationCubit>(() => mockMigrationCubit);

      await tester.pumpWidget(wrap());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      await tester.tap(find.text('Migration Status'));
      // Not pumpAndSettle — see the note on the test above.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Close'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      await tester.tap(find.text('Bob').first);
      await tester.pumpAndSettle();

      expect(find.text('Migrate Account…'), findsOneWidget);
      expect(find.text('Migration Status'), findsNothing);
    });
  });
}
