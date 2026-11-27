import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/email_folder.dart';
import 'package:nightmail/domain/entities/mail_rule.dart';
import 'package:nightmail/domain/usecases/mail_rules/delete_mail_rule.dart';
import 'package:nightmail/domain/usecases/mail_rules/get_mail_rule_folders.dart';
import 'package:nightmail/domain/usecases/mail_rules/get_mail_rules.dart';
import 'package:nightmail/domain/usecases/mail_rules/reorder_mail_rules.dart';
import 'package:nightmail/domain/usecases/mail_rules/save_mail_rule.dart';
import 'package:nightmail/domain/usecases/mail_rules/set_mail_rule_enabled.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/account/account_cubit.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_bloc.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_event.dart';
import 'package:nightmail/presentation/blocs/email_list/email_list_state.dart';
import 'package:nightmail/presentation/blocs/mail_rules/mail_rules_cubit.dart';
import 'package:nightmail/presentation/pages/settings/mail_rules_page.dart';

import 'new_rule_for_email_test.mocks.dart';

const _account = MicrosoftAccount(
  id: 'acct-1',
  displayName: 'Test',
  emailAddress: 'me@example.com',
  tenantId: 'common',
);

Email _email({
  String id = 'email-1',
  String from = 'news@example.com',
  bool isRead = true,
  String? folderId,
}) => Email(
  id: id,
  subject: 'Weekly digest',
  from: EmailAddress(address: from, name: 'News'),
  toRecipients: const [],
  ccRecipients: const [],
  bodyPreview: '',
  body: '',
  bodyType: EmailBodyType.text,
  isRead: isRead,
  receivedDateTime: DateTime(2026, 11, 20, 9),
  importance: EmailImportance.normal,
  parentFolderId: folderId,
);

/// The mail list the rule button is pressed in: its state, and the events the
/// run sends it.
class _FakeListBloc extends Fake implements EmailListBloc {
  _FakeListBloc(this.state);

  @override
  final EmailListState state;

  final added = <EmailListEvent>[];

  @override
  Stream<EmailListState> get stream => const Stream.empty();

  @override
  void add(EmailListEvent event) => added.add(event);
}

@GenerateMocks([
  GetMailRules,
  GetMailRuleFolders,
  SaveMailRule,
  DeleteMailRule,
  SetMailRuleEnabled,
  ReorderMailRules,
  AccountManager,
  AccountCubit,
])
void main() {
  late MockGetMailRules get;
  late MockSaveMailRule save;
  late MockAccountCubit accountCubit;

  setUp(() {
    provideDummy<Either<Failure, MailRuleSet>>(
      const Right(MailRuleSet(rules: [], capabilities: MailRuleCapabilities.graph)),
    );
    provideDummy<Either<Failure, List<EmailFolder>>>(const Right([]));
    provideDummy<Either<Failure, Unit>>(const Right(unit));
    provideDummy<AccountState>(
      const AccountsLoaded(accounts: [_account], activeIndex: 0),
    );

    get = MockGetMailRules();
    save = MockSaveMailRule();
    final folders = MockGetMailRuleFolders();
    final accountManager = MockAccountManager();
    when(accountManager.activeAccount).thenReturn(_account);
    when(accountManager.hasOutOfOfficeWriteAccess(any))
        .thenAnswer((_) async => true);
    when(folders(any)).thenAnswer((_) async => const Right([]));
    when(save(any)).thenAnswer((_) async => const Right(unit));

    sl.registerFactory<MailRulesCubit>(
      () => MailRulesCubit(
        getMailRules: get,
        getMailRuleFolders: folders,
        saveMailRule: save,
        deleteMailRule: MockDeleteMailRule(),
        setMailRuleEnabled: MockSetMailRuleEnabled(),
        reorderMailRules: MockReorderMailRules(),
        accountManager: accountManager,
      ),
    );

    accountCubit = MockAccountCubit();
    when(accountCubit.stream).thenAnswer((_) => const Stream.empty());
    when(accountCubit.state).thenReturn(
      const AccountsLoaded(accounts: [_account], activeIndex: 0),
    );
  });

  tearDown(() => sl.reset());

  void answerRules(MailRuleCapabilities capabilities) {
    when(get(any)).thenAnswer(
      (_) async => Right(MailRuleSet(rules: const [], capabilities: capabilities)),
    );
  }

  // The account cubit is provided *below* the MaterialApp, as HomePage does,
  // so the dialog only sees it if it is handed across.
  Future<void> open(
    WidgetTester tester, {
    Email? email,
    EmailListBloc? list,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        home: BlocProvider<AccountCubit>.value(
          value: accountCubit,
          child: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showNewRuleForEmail(
                  context,
                  email ?? _email(),
                  list: list,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  Future<void> addAction(WidgetTester tester, String label) async {
    await tester.tap(find.text('Add action'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(label).last);
    await tester.pumpAndSettle();
  }

  /// Adds "Mark as read" — the editor will not save a rule with no action —
  /// and saves, returning the rule that reached the use case.
  Future<MailRule> addActionAndSave(
    WidgetTester tester, {
    bool runNow = false,
  }) async {
    await addAction(tester, 'Mark as read');
    if (runNow) {
      await tester.tap(find.byKey(const ValueKey('rule-run-now')));
      await tester.pump();
    }
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    final params =
        verify(save(captureAny)).captured.single as SaveMailRuleParams;
    return params.rule;
  }

  testWidgets('opens a new rule already matching the sender', (tester) async {
    answerRules(MailRuleCapabilities.graph);
    await open(tester);

    expect(find.text('New Rule'), findsOneWidget);
    expect(find.text('news@example.com'), findsOneWidget);
    // Only the condition is filled in: no action is chosen for the user.
    verifyNever(save(any));

    final rule = await addActionAndSave(tester);
    expect(rule.conditions, [
      const MailRuleCondition(
        MailRuleConditionKind.fromAddresses,
        values: ['news@example.com'],
      ),
    ]);
    expect(find.text('New Rule'), findsNothing, reason: 'the dialog closes');
  });

  testWidgets('falls back to "from contains" where exact match is missing',
      (tester) async {
    answerRules(MailRuleCapabilities.gmail);
    await open(tester);

    final rule = await addActionAndSave(tester);
    expect(rule.conditions, [
      const MailRuleCondition(
        MailRuleConditionKind.senderContains,
        values: ['news@example.com'],
      ),
    ]);
  });

  testWidgets('leaves the condition blank for the account\'s own message',
      (tester) async {
    answerRules(MailRuleCapabilities.graph);
    await open(tester, email: _email(from: 'Me@Example.com'));

    expect(find.text('New Rule'), findsOneWidget);
    expect(find.text('Me@Example.com'), findsNothing);
  });

  group('run on the folder now', () {
    final inbox = _FakeListBloc(
      EmailListLoaded(
        currentFolderId: 'inbox',
        currentFolderName: 'Inbox',
        emails: [
          _email(id: 'unread', isRead: false, folderId: 'inbox'),
          _email(id: 'read', folderId: 'inbox'),
          _email(id: 'other', from: 'boss@example.com', isRead: false, folderId: 'inbox'),
          // A thread's copy from another folder, listed beside its reply.
          _email(id: 'elsewhere', isRead: false, folderId: 'archive'),
        ],
      ),
    );

    testWidgets('is offered for a new rule opened from a folder, unticked',
        (tester) async {
      answerRules(MailRuleCapabilities.graph);
      await open(tester, list: inbox);

      expect(find.text('Run on Inbox now'), findsOneWidget);
      final box = tester.widget<Checkbox>(
        find.byKey(const ValueKey('rule-run-now')),
      );
      expect(box.value, isFalse);
    });

    testWidgets('is not offered without the list', (tester) async {
      answerRules(MailRuleCapabilities.graph);
      await open(tester);

      expect(find.byKey(const ValueKey('rule-run-now')), findsNothing);
    });

    testWidgets('acts on the matching messages in the folder only',
        (tester) async {
      answerRules(MailRuleCapabilities.graph);
      final list = _FakeListBloc(inbox.state);
      await open(tester, list: list);
      await addActionAndSave(tester, runNow: true);

      expect(list.added, [
        const EmailListMarkThreadReadRequested(
          emailIds: ['unread'],
          isRead: true,
        ),
      ]);
      expect(find.textContaining('marked 1 message in Inbox read'), findsOneWidget);
    });

    testWidgets('deletes only the sender\'s messages in the folder',
        (tester) async {
      answerRules(MailRuleCapabilities.graph);
      final list = _FakeListBloc(inbox.state);
      await open(tester, list: list);
      await addAction(tester, 'Delete (to Deleted Items)');
      await tester.tap(find.byKey(const ValueKey('rule-run-now')));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(list.added, [
        const EmailListEmailsBulkDeleted(emailIds: ['unread', 'read']),
      ]);
      expect(find.textContaining('deleted 2 messages from Inbox'), findsOneWidget);
    });

    testWidgets('does nothing to the folder when left unticked',
        (tester) async {
      answerRules(MailRuleCapabilities.graph);
      final list = _FakeListBloc(inbox.state);
      await open(tester, list: list);
      await addActionAndSave(tester);

      expect(list.added, isEmpty);
    });

    testWidgets('is refused for a rule that forwards', (tester) async {
      answerRules(MailRuleCapabilities.graph);
      await open(tester, list: inbox);
      await addAction(tester, 'Forward to');

      final box = tester.widget<Checkbox>(
        find.byKey(const ValueKey('rule-run-now')),
      );
      expect(box.onChanged, isNull);
      expect(find.textContaining('runs on new mail only'), findsOneWidget);
    });
  });

  group('Settings > Rules', () {
    // Settings carries the mail list behind it across, as
    // SettingsDialog.open does.
    Future<void> openSettings(WidgetTester tester, {EmailListBloc? list}) async {
      await tester.binding.setSurfaceSize(const Size(1000, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: MultiBlocProvider(
            providers: [
              BlocProvider<AccountCubit>.value(value: accountCubit),
              if (list != null) BlocProvider<EmailListBloc>.value(value: list),
            ],
            child: const Scaffold(body: MailRulesPage()),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('New rule'));
      await tester.pumpAndSettle();
    }

    final inbox = _FakeListBloc(
      EmailListLoaded(
        currentFolderId: 'inbox',
        currentFolderName: 'Inbox',
        emails: [
          _email(id: 'unread', isRead: false, folderId: 'inbox'),
          _email(id: 'other', from: 'boss@example.com', isRead: false, folderId: 'inbox'),
        ],
      ),
    );

    testWidgets('a new rule runs on the folder behind Settings', (tester) async {
      answerRules(MailRuleCapabilities.graph);
      final list = _FakeListBloc(inbox.state);
      await openSettings(tester, list: list);

      expect(find.text('Run on Inbox now'), findsOneWidget);
      await tester.tap(find.text('Add condition'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('From').last);
      await tester.pumpAndSettle();
      await tester.enterText(
        find.widgetWithText(TextField, 'name@example.com; another@example.com'),
        'news@example.com',
      );
      await addAction(tester, 'Mark as read');
      await tester.tap(find.byKey(const ValueKey('rule-run-now')));
      await tester.pump();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();

      expect(list.added, [
        const EmailListMarkThreadReadRequested(
          emailIds: ['unread'],
          isRead: true,
        ),
      ]);
    });

    group('a saved rule\'s run button', () {
      const fromNews = MailRuleCondition(
        MailRuleConditionKind.fromAddresses,
        values: ['news@example.com'],
      );

      void answerSaved(MailRule rule) {
        when(get(any)).thenAnswer(
          (_) async => Right(
            MailRuleSet(
              rules: [rule],
              capabilities: MailRuleCapabilities.graph,
            ),
          ),
        );
      }

      Future<void> showRules(WidgetTester tester, {EmailListBloc? list}) async {
        await tester.binding.setSurfaceSize(const Size(1000, 900));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            home: MultiBlocProvider(
              providers: [
                BlocProvider<AccountCubit>.value(value: accountCubit),
                if (list != null)
                  BlocProvider<EmailListBloc>.value(value: list),
              ],
              child: const Scaffold(body: MailRulesPage()),
            ),
          ),
        );
        await tester.pumpAndSettle();
      }

      final runButton = find.byKey(const ValueKey('rule-run-r1'));

      testWidgets('marks the matching messages read at once', (tester) async {
        answerSaved(
          const MailRule(
            id: 'r1',
            name: 'News',
            conditions: [fromNews],
            actions: [MailRuleAction(MailRuleActionKind.markAsRead)],
          ),
        );
        final list = _FakeListBloc(inbox.state);
        await showRules(tester, list: list);

        await tester.tap(runButton);
        await tester.pumpAndSettle();

        expect(list.added, [
          const EmailListMarkThreadReadRequested(
            emailIds: ['unread'],
            isRead: true,
          ),
        ]);
        expect(find.text('Rule run: marked 1 message in Inbox read.'),
            findsOneWidget);
        verifyNever(save(any));
      });

      testWidgets('asks before moving, and does nothing on Cancel',
          (tester) async {
        answerSaved(
          const MailRule(
            id: 'r1',
            name: 'News',
            conditions: [fromNews],
            actions: [
              MailRuleAction(MailRuleActionKind.moveToFolder, folderId: 'news'),
            ],
          ),
        );
        final list = _FakeListBloc(inbox.state);
        await showRules(tester, list: list);

        await tester.tap(runButton);
        await tester.pumpAndSettle();
        expect(find.text('Run this rule now?'), findsOneWidget);
        await tester.tap(find.text('Cancel'));
        await tester.pumpAndSettle();
        expect(list.added, isEmpty);

        await tester.tap(runButton);
        await tester.pumpAndSettle();
        await tester.tap(find.text('Move'));
        await tester.pumpAndSettle();
        expect(list.added, [
          const EmailListEmailsMoved(
            emailIds: ['unread'],
            destinationFolderId: 'news',
          ),
        ]);
      });

      testWidgets('is disabled for a rule that forwards', (tester) async {
        answerSaved(
          const MailRule(
            id: 'r1',
            name: 'News',
            conditions: [fromNews],
            actions: [
              MailRuleAction(
                MailRuleActionKind.forwardTo,
                addresses: ['x@example.com'],
              ),
            ],
          ),
        );
        await showRules(tester, list: _FakeListBloc(inbox.state));

        expect(tester.widget<IconButton>(runButton).onPressed, isNull);
      });

      testWidgets('is not shown with no mail list behind Settings',
          (tester) async {
        answerSaved(
          const MailRule(
            id: 'r1',
            conditions: [fromNews],
            actions: [MailRuleAction(MailRuleActionKind.markAsRead)],
          ),
        );
        await showRules(tester);

        expect(runButton, findsNothing);
      });
    });

    testWidgets('is not offered with no mail list behind Settings',
        (tester) async {
      answerRules(MailRuleCapabilities.graph);
      await openSettings(tester);

      expect(find.byKey(const ValueKey('rule-run-now')), findsNothing);
    });
  });

  testWidgets('says why when the account has no rules', (tester) async {
    when(get(any)).thenAnswer(
      (_) async => const Left(UnsupportedFailure(message: 'Not on this server')),
    );
    await open(tester);

    expect(find.text('Rules unavailable'), findsOneWidget);
    expect(find.text('Not on this server'), findsOneWidget);

    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.text('Rules unavailable'), findsNothing);
  });
}
