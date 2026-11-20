import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
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
import 'package:nightmail/presentation/blocs/mail_rules/mail_rules_cubit.dart';
import 'package:nightmail/presentation/blocs/mail_rules/mail_rules_state.dart';

import 'mail_rules_cubit_test.mocks.dart';

const _account = MicrosoftAccount(
  id: 'acct-1',
  displayName: 'Test',
  emailAddress: 'me@example.com',
  tenantId: 'common',
);

const _a = MailRule(id: 'a', name: 'A', sequence: 3);
const _b = MailRule(id: 'b', name: 'B', sequence: 7);

const _set = MailRuleSet(
  rules: [_a, _b],
  capabilities: MailRuleCapabilities.graph,
);

@GenerateMocks([
  GetMailRules,
  GetMailRuleFolders,
  SaveMailRule,
  DeleteMailRule,
  SetMailRuleEnabled,
  ReorderMailRules,
  AccountManager,
])
void main() {
  late MockGetMailRules get;
  late MockGetMailRuleFolders folders;
  late MockSaveMailRule save;
  late MockReorderMailRules reorder;
  late MockAccountManager accountManager;
  late MailRulesCubit cubit;

  setUp(() {
    provideDummy<Either<Failure, MailRuleSet>>(const Right(_set));
    provideDummy<Either<Failure, List<EmailFolder>>>(const Right([]));
    provideDummy<Either<Failure, Unit>>(const Right(unit));

    get = MockGetMailRules();
    folders = MockGetMailRuleFolders();
    save = MockSaveMailRule();
    reorder = MockReorderMailRules();
    accountManager = MockAccountManager();
    cubit = MailRulesCubit(
      getMailRules: get,
      getMailRuleFolders: folders,
      saveMailRule: save,
      deleteMailRule: MockDeleteMailRule(),
      setMailRuleEnabled: MockSetMailRuleEnabled(),
      reorderMailRules: reorder,
      accountManager: accountManager,
    );

    when(accountManager.activeAccount).thenReturn(_account);
    when(accountManager.hasOutOfOfficeWriteAccess(any))
        .thenAnswer((_) async => true);
    when(get(any)).thenAnswer((_) async => const Right(_set));
    when(folders(any)).thenAnswer((_) async => const Right([]));
  });

  tearDown(() => cubit.close());

  test('an IMAP account reads as unsupported, not as an error', () async {
    when(get(any)).thenAnswer(
      (_) async => const Left(UnsupportedFailure(message: 'Not here')),
    );

    await cubit.load();

    expect(cubit.state.status, MailRulesStatus.unsupported);
    expect(cubit.state.errorMessage, 'Not here');
  });

  test('a new rule runs after every existing one', () async {
    when(save(any)).thenAnswer((_) async => const Right(unit));
    await cubit.load();

    final ok = await cubit.saveRule(const MailRule(name: 'New'));

    expect(ok, isTrue);
    final saved =
        verify(save(captureAny)).captured.single as SaveMailRuleParams;
    expect(saved.accountId, 'acct-1');
    // Max existing sequence + 1, not the list length: Outlook leaves gaps.
    expect(saved.rule.sequence, 8);
    expect(cubit.state.savedAt, isNotNull);
  });

  test('moving a rule swaps it with its neighbour and nothing else', () async {
    when(reorder(any)).thenAnswer((_) async => const Right(unit));
    await cubit.load();

    await cubit.move(_b, -1);

    final params =
        verify(reorder(captureAny)).captured.single as ReorderMailRulesParams;
    expect(params.sequences, {'b': 3, 'a': 7});
  });

  test('a read-only neighbour pins the rule beside it', () async {
    // Graph refuses any PATCH to a read-only rule, sequence included.
    const locked = MailRule(id: 'l', sequence: 5, isReadOnly: true);
    when(get(any)).thenAnswer(
      (_) async => const Right(
        MailRuleSet(
          rules: [_a, locked, _b],
          capabilities: MailRuleCapabilities.graph,
        ),
      ),
    );
    await cubit.load();

    expect(cubit.canMove(_b, -1), isFalse);
    expect(cubit.canMove(_a, 1), isFalse);
    expect(await cubit.move(_b, -1), isFalse);
    verifyNever(reorder(any));
  });

  test('a failed change keeps its reason through the re-read', () async {
    when(save(any)).thenAnswer(
      (_) async => const Left(ServerFailure(message: 'Folder not found')),
    );
    await cubit.load();

    final ok = await cubit.saveRule(_a.copyWith(name: 'Renamed'));

    expect(ok, isFalse);
    expect(cubit.state.errorMessage, 'Folder not found');
    expect(cubit.state.busy, isFalse);
  });
}
