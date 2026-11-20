import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/core/utils/special_folder_kind.dart';
import 'package:nightmail/data/datasources/local/mail_rule_store.dart';
import 'package:nightmail/domain/entities/mail_rule.dart';
import 'package:nightmail/domain/repositories/mail_rules_repository.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/migration/mail_rule_migrator.dart';
import 'package:nightmail/infrastructure/sync/imap_connection_gate.dart';

import 'mail_rule_migrator_test.mocks.dart';

class _Folders implements RuleFolderResolver {
  _Folders(this.map);

  final Map<String, FolderTarget> map;

  @override
  Future<(FolderTarget?, String?)> resolve(String sourceFolderId) async {
    final target = map[sourceFolderId];
    return target == null
        ? (null, 'files into a folder that no longer exists')
        : (target, null);
  }
}

MailRuleCondition _c(MailRuleConditionKind kind, [List<String> values = const []]) =>
    MailRuleCondition(kind, values: values);

MailRule _rule(
  List<MailRuleCondition> conditions,
  List<MailRuleAction> actions, {
  String name = 'r',
  int sequence = 1,
}) => MailRule(
  id: name,
  name: name,
  sequence: sequence,
  conditions: conditions,
  actions: actions,
);

const _graph = MicrosoftAccount(
  id: 'ms',
  displayName: 'Old',
  emailAddress: 'me@old.example',
  tenantId: 'common',
);
const _gmail = GmailAccount(
  id: 'gm',
  displayName: 'New',
  emailAddress: 'me@new.example',
);
const _imap = ImapAccount(
  id: 'imap',
  displayName: 'New',
  emailAddress: 'me@new.example',
  host: 'imap.new.example',
  port: 993,
  useSsl: true,
  smtpHost: 'smtp.new.example',
  smtpPort: 587,
  smtpUseSsl: false,
);

@GenerateMocks([MailRulesRepository, AccountManager])
void main() {
  group('MailRuleTranslator', () {
    MailRuleTranslator toGmail({Map<String, FolderTarget> folders = const {}}) =>
        MailRuleTranslator(
          sourceIsGmail: false,
          target: MailRuleCapabilities.gmail,
          targetIsGmail: true,
          folders: _Folders(folders),
        );

    Future<({MailRule? rule, String? reason})> run(
      MailRuleTranslator t,
      MailRule rule, {
      List<MailRule> later = const [],
    }) => t.translate(rule, later: later, name: rule.name);

    test('a condition the target cannot test skips the whole rule', () async {
      // Dropping it would make the rule act on more mail than it did.
      final out = await run(
        toGmail(),
        _rule(
          [
            _c(MailRuleConditionKind.subjectContains, ['x']),
            _c(MailRuleConditionKind.headerContains, ['X-List']),
          ],
          const [MailRuleAction(MailRuleActionKind.delete)],
        ),
      );

      expect(out.rule, isNull);
      expect(out.reason, contains('headerContains'));
    });

    test('an exception the target cannot test skips it too', () async {
      final out = await run(
        toGmail(),
        const MailRule(
          name: 'r',
          conditions: [MailRuleCondition(MailRuleConditionKind.hasAttachments)],
          exceptions: [MailRuleCondition(MailRuleConditionKind.sentToMe)],
          actions: [MailRuleAction(MailRuleActionKind.delete)],
        ),
      );

      expect(out.rule, isNull);
    });

    test("Outlook's \"from\" becomes Gmail's From, quoted where needed",
        () async {
      final out = await run(
        toGmail(),
        _rule(
          [
            _c(MailRuleConditionKind.fromAddresses, ['boss@old.example']),
            _c(MailRuleConditionKind.subjectContains, ['-draft', 'weekly report']),
          ],
          const [MailRuleAction(MailRuleActionKind.markAsRead)],
        ),
      );

      expect(out.rule!.conditions, [
        _c(MailRuleConditionKind.senderContains, ['boss@old.example']),
        // Unquoted, `-draft` means "not draft" in Gmail's search syntax.
        _c(MailRuleConditionKind.subjectContains, ['"-draft"', '"weekly report"']),
      ]);
      expect(out.rule!.name, isEmpty);
    });

    test('stop-processing is dropped for Gmail when nothing later is '
        'destructive', () async {
      final out = await run(
        toGmail(),
        _rule(
          [_c(MailRuleConditionKind.subjectContains, ['x'])],
          const [
            MailRuleAction(MailRuleActionKind.markAsRead),
            MailRuleAction(MailRuleActionKind.stopProcessingRules),
          ],
        ),
        later: [
          _rule(
            [_c(MailRuleConditionKind.hasAttachments)],
            const [MailRuleAction(MailRuleActionKind.markAsRead)],
          ),
        ],
      );

      expect(out.rule!.actions, [
        const MailRuleAction(MailRuleActionKind.markAsRead),
      ]);
    });

    test('...and the rule is skipped when a later one deletes', () async {
      // On Gmail both would run, and the delete would reach mail this rule
      // used to shield from it.
      final out = await run(
        toGmail(),
        _rule(
          [_c(MailRuleConditionKind.subjectContains, ['x'])],
          const [
            MailRuleAction(MailRuleActionKind.markAsRead),
            MailRuleAction(MailRuleActionKind.stopProcessingRules),
          ],
        ),
        later: [
          _rule(
            [_c(MailRuleConditionKind.hasAttachments)],
            const [MailRuleAction(MailRuleActionKind.delete)],
          ),
        ],
      );

      expect(out.rule, isNull);
      expect(out.reason, contains('deletes or forwards'));
    });

    test("a move to Gmail's Trash or Archive becomes delete or archive",
        () async {
      final t = toGmail(
        folders: {
          'deleted': const FolderTarget('TRASH', kind: SpecialFolderKind.trash),
          'archive': const FolderTarget('ARCHIVE', kind: SpecialFolderKind.archive),
          'junk': const FolderTarget('SPAM', kind: SpecialFolderKind.junk),
        },
      );
      MailRule moveTo(String id) => _rule(
        [_c(MailRuleConditionKind.hasAttachments)],
        [MailRuleAction(MailRuleActionKind.moveToFolder, folderId: id)],
      );

      expect((await run(t, moveTo('deleted'))).rule!.actions, [
        const MailRuleAction(MailRuleActionKind.delete),
      ]);
      expect((await run(t, moveTo('archive'))).rule!.actions, [
        const MailRuleAction(MailRuleActionKind.archive),
      ]);
      expect((await run(t, moveTo('junk'))).rule, isNull);
    });

    test('a folder that resolves is filed under its new id', () async {
      final t = MailRuleTranslator(
        sourceIsGmail: true,
        target: MailRuleCapabilities.graph,
        targetIsGmail: false,
        folders: _Folders({'Label_3': const FolderTarget('graph-folder-9')}),
      );

      final out = await run(
        t,
        _rule(
          [_c(MailRuleConditionKind.senderContains, ['a@x.com OR b@x.com'])],
          const [
            MailRuleAction(MailRuleActionKind.copyToFolder, folderId: 'Label_3'),
          ],
        ),
      );

      expect(out.rule!.actions, [
        const MailRuleAction(
          MailRuleActionKind.copyToFolder,
          folderId: 'graph-folder-9',
        ),
      ]);
      // A plain Gmail OR list becomes Graph's alternatives.
      expect(out.rule!.conditions.single.values, ['a@x.com', 'b@x.com']);
    });

    test('Gmail search syntax has no literal meaning elsewhere', () async {
      expect(MailRuleTranslator.plainGmailValues(['a OR b']), ['a', 'b']);
      expect(MailRuleTranslator.plainGmailValues(['(a OR b)']), isNull);
      expect(MailRuleTranslator.plainGmailValues(['list:announce']), isNull);
      expect(MailRuleTranslator.plainGmailValues(['-spam']), isNull);
    });

    test("NightMail's own rules never file into the Inbox", () async {
      final t = MailRuleTranslator(
        sourceIsGmail: false,
        target: MailRuleCapabilities.local,
        targetIsGmail: false,
        folders: _Folders({'x': const FolderTarget('INBOX')}),
      );

      final out = await run(
        t,
        _rule(
          [_c(MailRuleConditionKind.hasAttachments)],
          const [MailRuleAction(MailRuleActionKind.moveToFolder, folderId: 'x')],
        ),
      );

      expect(out.rule, isNull);
    });
  });

  group('MailRuleMigrator', () {
    late Directory dir;
    late MockMailRulesRepository repository;
    late MockAccountManager accountManager;
    late MailRuleMigrator migrator;
    var targetRules = <MailRule>[];

    final sourceRule = _rule(
      [_c(MailRuleConditionKind.subjectContains, ['invoice'])],
      const [MailRuleAction(MailRuleActionKind.markAsRead)],
      name: 'Invoices',
    );

    setUp(() async {
      provideDummy<Either<Failure, MailRuleSet>>(
        const Right(
          MailRuleSet(rules: [], capabilities: MailRuleCapabilities.graph),
        ),
      );
      provideDummy<Either<Failure, Unit>>(const Right(unit));
      dir = await Directory.systemTemp.createTemp('rule_migrator_test');
      repository = MockMailRulesRepository();
      accountManager = MockAccountManager();
      targetRules = [];
      migrator = MailRuleMigrator(
        repository: repository,
        accountManager: accountManager,
        store: MailRuleStore(directory: () async => dir),
        imapConnectionGate: ImapConnectionGate(),
      );
      when(repository.getMailRules('ms')).thenAnswer(
        (_) async => Right(
          MailRuleSet(
            rules: [sourceRule],
            capabilities: MailRuleCapabilities.graph,
          ),
        ),
      );
      when(repository.saveMailRule(any, any)).thenAnswer((inv) async {
        targetRules.add(inv.positionalArguments[1] as MailRule);
        return const Right(unit);
      });
    });

    tearDown(() => dir.delete(recursive: true));

    void targetIs(Account target, MailRuleCapabilities caps) {
      when(repository.getMailRules(target.id)).thenAnswer(
        (_) async => Right(MailRuleSet(rules: [...targetRules], capabilities: caps)),
      );
    }

    test('an IMAP target needs no permission', () async {
      targetIs(_imap, MailRuleCapabilities.local);
      // The OAuth check answers false for IMAP; it must not be what decides.
      when(accountManager.hasOutOfOfficeWriteAccess(any))
          .thenAnswer((_) async => false);

      final result = await migrator.migrateOnce(_graph, _imap);

      expect(result.status, RuleMigrationStatus.done);
      expect(result.copied, 1);
      expect(targetRules.single.name, 'Invoices');
    });

    test('a server target without the permission waits for it', () async {
      targetIs(_gmail, MailRuleCapabilities.gmail);
      when(accountManager.hasOutOfOfficeWriteAccess('gm'))
          .thenAnswer((_) async => false);

      final first = await migrator.migrateOnce(_graph, _gmail);
      expect(first.status, RuleMigrationStatus.needsPermission);
      verifyNever(repository.saveMailRule(any, any));

      // Granted since: the next pass of the job tries again.
      when(accountManager.hasOutOfOfficeWriteAccess('gm'))
          .thenAnswer((_) async => true);
      final second = await migrator.migrateOnce(_graph, _gmail);
      expect(second.status, RuleMigrationStatus.done);
      expect(second.copied, 1);
    });

    test('a finished copy is never repeated, so a deleted rule stays deleted',
        () async {
      targetIs(_imap, MailRuleCapabilities.local);

      await migrator.migrateOnce(_graph, _imap);
      // The user deletes the migrated rule on the new account; the job's
      // next rescan comes round.
      targetRules.clear();
      final again = await migrator.migrateOnce(_graph, _imap);

      expect(again.copied, 1, reason: 'the stored result, not a new run');
      verify(repository.saveMailRule(any, any)).called(1);
    });

    test('a rule already on the target is counted, not copied', () async {
      targetRules = [
        sourceRule.copyWith(name: 'Something else', sequence: 4),
      ];
      targetIs(_imap, MailRuleCapabilities.local);

      final result = await migrator.migrateNow(_graph, _imap);

      expect(result.alreadyThere, 1);
      expect(result.copied, 0);
    });

    test('a source with no rules has nothing to copy', () async {
      when(repository.getMailRules('ms')).thenAnswer(
        (_) async => const Left(UnsupportedFailure(message: 'no rules here')),
      );

      final result = await migrator.migrateOnce(_graph, _imap);

      expect(result.status, RuleMigrationStatus.nothingToCopy);
    });

    test('the result survives in the store for the dialog', () async {
      targetIs(_imap, MailRuleCapabilities.local);

      await migrator.migrateOnce(_graph, _imap);
      final stored = await migrator.lastResult('ms', 'imap');

      expect(stored!.status, RuleMigrationStatus.done);
      expect(stored.copied, 1);
    });

    group('switching the old rules off', () {
      final skippedRule = _rule(
        [_c(MailRuleConditionKind.headerContains, ['X-List'])],
        const [MailRuleAction(MailRuleActionKind.delete)],
        name: 'Lists',
        sequence: 2,
      );

      setUp(() {
        provideDummy<Either<Failure, Unit>>(const Right(unit));
        when(repository.getMailRules('ms')).thenAnswer(
          (_) async => Right(
            MailRuleSet(
              rules: [sourceRule, skippedRule],
              capabilities: MailRuleCapabilities.graph,
            ),
          ),
        );
        when(repository.setMailRuleEnabled(any, any, any))
            .thenAnswer((_) async => const Right(unit));
        // headerContains cannot be tested on IMAP, so 'Lists' is skipped.
        targetIs(_imap, MailRuleCapabilities.local);
      });

      test('the copy asks, and only migrated rules are offered', () async {
        final result = await migrator.migrateOnce(_graph, _imap);

        expect(result.asksAboutSourceRules, isTrue);
        expect(result.migratedSourceRuleIds, ['Invoices']);
        expect(result.skipped.single.name, 'Lists');
      });

      test('turning off disables only the migrated ones, and is remembered',
          () async {
        when(accountManager.hasOutOfOfficeWriteAccess('ms'))
            .thenAnswer((_) async => true);
        await migrator.migrateOnce(_graph, _imap);

        final result = await migrator.decideSourceRules(
          _graph,
          _imap,
          turnOff: true,
        );

        // 'Lists' has no copy; switching it off would just lose it.
        verify(repository.setMailRuleEnabled('ms', 'Invoices', false))
            .called(1);
        verifyNever(repository.setMailRuleEnabled('ms', 'Lists', any));
        expect(result!.sourceRules, SourceRulesDecision.turnedOff);
        expect(
          (await migrator.lastResult('ms', 'imap'))!.asksAboutSourceRules,
          isFalse,
        );
      });

      test('keeping them running changes nothing on the old account',
          () async {
        await migrator.migrateOnce(_graph, _imap);

        final result = await migrator.decideSourceRules(
          _graph,
          _imap,
          turnOff: false,
        );

        verifyNever(repository.setMailRuleEnabled(any, any, any));
        expect(result!.sourceRules, SourceRulesDecision.keptRunning);
      });

      test('without the permission nothing changes and a sign-in is asked for',
          () async {
        when(accountManager.hasOutOfOfficeWriteAccess('ms'))
            .thenAnswer((_) async => false);
        await migrator.migrateOnce(_graph, _imap);

        final result = await migrator.decideSourceRules(
          _graph,
          _imap,
          turnOff: true,
        );

        verifyNever(repository.setMailRuleEnabled(any, any, any));
        expect(result!.asksAboutSourceRules, isTrue);
        expect(
          result.sourceRulesMessage,
          MailRuleMigrator.needsPermissionMessage,
        );
      });

      test('a rule that will not switch off keeps the question open',
          () async {
        when(accountManager.hasOutOfOfficeWriteAccess('ms'))
            .thenAnswer((_) async => true);
        when(repository.setMailRuleEnabled(any, any, any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'Rule not found')),
        );
        await migrator.migrateOnce(_graph, _imap);

        final result = await migrator.decideSourceRules(
          _graph,
          _imap,
          turnOff: true,
        );

        expect(result!.asksAboutSourceRules, isTrue);
        expect(result.sourceRulesMessage, contains('Rule not found'));
      });
    });
  });
}
