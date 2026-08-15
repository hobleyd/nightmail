import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/usecases/search_contacts.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/account/account_cubit.dart';
import 'package:nightmail/presentation/widgets/add_shared_mailbox_dialog.dart';

import 'add_shared_mailbox_dialog_test.mocks.dart';

/// Stands in for [SearchContacts] so the dialog's typeahead never touches the
/// four repositories it would otherwise merge — only [call] matters here.
class _FakeSearchContacts implements SearchContacts {
  List<ContactSuggestion> results = const [];

  @override
  Future<List<ContactSuggestion>> call({
    required String query,
    required String accountId,
    String? accountDomain,
  }) async =>
      results;

  @override
  Never get senderRepository => throw UnimplementedError();
  @override
  Never get contactCacheRepository => throw UnimplementedError();
  @override
  Never get systemContactsRepository => throw UnimplementedError();
  @override
  Never get directoryContactsRepository => throw UnimplementedError();
}

@GenerateMocks([AccountCubit])
void main() {
  late MockAccountCubit mockAccountCubit;
  late _FakeSearchContacts fakeSearchContacts;

  setUp(() {
    mockAccountCubit = MockAccountCubit();
    fakeSearchContacts = _FakeSearchContacts();
    sl.registerLazySingleton<SearchContacts>(() => fakeSearchContacts);
    // BlocProvider subscribes to this on first context.read/watch, even
    // though the dialog never actually watches AccountCubit's state.
    when(mockAccountCubit.stream).thenAnswer((_) => const Stream.empty());
  });

  tearDown(() async {
    await sl.reset();
  });

  // The dialog is opened via showDialog in production, and a dialog route is
  // a *sibling* of the page that opened it, not a descendant — so, exactly
  // like folder_panel.dart's _showAddSharedMailboxDialog, the provider has to
  // be re-supplied inside the dialog's own builder.
  Widget wrap() => MaterialApp(
        home: Builder(
          builder: (context) => ElevatedButton(
            onPressed: () => showDialog<bool>(
              context: context,
              builder: (_) => BlocProvider<AccountCubit>.value(
                value: mockAccountCubit,
                child: const AddSharedMailboxDialog(
                  parentAccountId: 'ms-1',
                  parentAccountLabel: 'b@corp.com',
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      );

  Future<void> openDialog(WidgetTester tester) async {
    await tester.pumpWidget(wrap());
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('AddSharedMailboxDialog', () {
    testWidgets('shows local directory suggestions as the user types',
        (tester) async {
      fakeSearchContacts.results = const [
        ContactSuggestion(address: 'sales@corp.com', name: 'Sales Team'),
      ];
      await openDialog(tester);

      await tester.enterText(find.byType(TextField), 'sal');
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.text('Sales Team'), findsOneWidget);
      expect(find.text('sales@corp.com'), findsOneWidget);
    });

    testWidgets('selecting a candidate that resolves adds it and closes',
        (tester) async {
      fakeSearchContacts.results = const [
        ContactSuggestion(address: 'sales@corp.com', name: 'Sales Team'),
      ];
      when(mockAccountCubit.resolveSharedMailboxCandidate(any, any))
          .thenAnswer((_) async => (
                displayName: 'Sales Team',
                hasAccess: true,
                needsReauth: false,
              ));
      when(mockAccountCubit.addSharedMailbox(
        parentAccountId: anyNamed('parentAccountId'),
        email: anyNamed('email'),
        displayName: anyNamed('displayName'),
      )).thenAnswer((_) async {});

      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'sal');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Sales Team'));
      await tester.tap(find.text('Sales Team'));
      await tester.pumpAndSettle();

      verify(mockAccountCubit.addSharedMailbox(
        parentAccountId: 'ms-1',
        email: 'sales@corp.com',
        displayName: 'Sales Team',
      )).called(1);
      expect(find.byType(AddSharedMailboxDialog), findsNothing);
    });

    testWidgets(
        'a stale-scope parent reports needsReauth without ever being told '
        '"no access"', (tester) async {
      fakeSearchContacts.results = const [
        ContactSuggestion(address: 'sales@corp.com', name: 'Sales Team'),
      ];
      when(mockAccountCubit.resolveSharedMailboxCandidate(any, any))
          .thenAnswer((_) async => (
                displayName: 'sales@corp.com',
                hasAccess: false,
                needsReauth: true,
              ));

      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'sal');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Sales Team'));
      await tester.tap(find.text('Sales Team'));
      await tester.pumpAndSettle();

      expect(find.textContaining('needs to be re-authenticated'), findsOneWidget);
      expect(find.textContaining("don't have access"), findsNothing);
      verifyNever(mockAccountCubit.addSharedMailbox(
        parentAccountId: anyNamed('parentAccountId'),
        email: anyNamed('email'),
        displayName: anyNamed('displayName'),
      ));
      // The dialog stays open so the user can try a different address.
      expect(find.byType(AddSharedMailboxDialog), findsOneWidget);
    });

    testWidgets('no Full Access grant shows the access-denied message',
        (tester) async {
      fakeSearchContacts.results = const [
        ContactSuggestion(address: 'sales@corp.com', name: 'Sales Team'),
      ];
      when(mockAccountCubit.resolveSharedMailboxCandidate(any, any))
          .thenAnswer((_) async => (
                displayName: 'Sales Team',
                hasAccess: false,
                needsReauth: false,
              ));

      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'sal');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Sales Team'));
      await tester.tap(find.text('Sales Team'));
      await tester.pumpAndSettle();

      expect(find.textContaining("Couldn't open sales@corp.com"), findsOneWidget);
      verifyNever(mockAccountCubit.addSharedMailbox(
        parentAccountId: anyNamed('parentAccountId'),
        email: anyNamed('email'),
        displayName: anyNamed('displayName'),
      ));
    });

    testWidgets('Cancel dismisses the dialog even while a probe is in flight',
        (tester) async {
      fakeSearchContacts.results = const [
        ContactSuggestion(address: 'sales@corp.com', name: 'Sales Team'),
      ];
      // Never completes — simulates a slow/throttled tenant.
      when(mockAccountCubit.resolveSharedMailboxCandidate(any, any))
          .thenAnswer((_) => Completer<
                  ({String displayName, bool hasAccess, bool needsReauth})>()
              .future);

      await openDialog(tester);
      await tester.enterText(find.byType(TextField), 'sal');
      await tester.pump(const Duration(milliseconds: 250));
      await tester.ensureVisible(find.text('Sales Team'));
      await tester.tap(find.text('Sales Team'));
      await tester.pump();

      // Still mid-probe: the spinner is up, and Cancel must still work.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(find.byType(AddSharedMailboxDialog), findsNothing);
    });
  });
}
