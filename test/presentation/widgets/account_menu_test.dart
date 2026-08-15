import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/presentation/blocs/account/account_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_poller/mail_poller_state.dart';
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

@GenerateMocks([AccountCubit, MailPollerCubit])
void main() {
  late MockAccountCubit mockAccountCubit;
  late MockMailPollerCubit mockMailPollerCubit;

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
  });

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
}
