import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/local/local_mail_rules_datasource.dart';
import 'package:nightmail/data/datasources/local/mail_rule_store.dart';
import 'package:nightmail/domain/entities/mail_rule.dart';

/// An IMAP account's rules are files NightMail keeps itself.
void main() {
  late Directory dir;
  late MailRuleStore store;
  late LocalMailRulesDatasource datasource;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('local_rules_test');
    store = MailRuleStore(directory: () async => dir);
    datasource = LocalMailRulesDatasource(store: store, accountId: 'imap/1');
  });

  tearDown(() => dir.delete(recursive: true));

  const rule = MailRule(
    name: 'Receipts',
    sequence: 1,
    conditions: [
      MailRuleCondition(
        MailRuleConditionKind.subjectContains,
        values: ['receipt'],
      ),
    ],
    actions: [
      MailRuleAction(MailRuleActionKind.moveToFolder, folderId: 'Receipts'),
      // Gmail's star is IMAP's \Flagged here, and must survive the file.
      MailRuleAction(MailRuleActionKind.star),
    ],
  );

  test('a created rule reads back whole, with an id of its own', () async {
    await datasource.createMailRule(rule);

    final saved = (await datasource.getMailRules()).single;
    expect(saved.id, isNotNull);
    expect(saved.hasUnsupportedParts, isFalse);
    expect(saved.conditions, rule.conditions);
    expect(saved.actions.toSet(), rule.actions.toSet());
  });

  test('enable, reorder, update and delete act on the stored copy', () async {
    await datasource.createMailRule(rule);
    await datasource.createMailRule(rule.copyWith(name: 'Second', sequence: 2));
    final [a, b] = await datasource.getMailRules();

    await datasource.setMailRuleEnabled(a.id!, false);
    await datasource.reorderMailRules({a.id!: 2, b.id!: 1});
    await datasource.updateMailRule(b.copyWith(name: 'Renamed'));

    final rules = await datasource.getMailRules();
    expect(rules.map((r) => r.name), ['Renamed', 'Receipts']);
    expect(rules.last.enabled, isFalse);

    await datasource.deleteMailRule(a.id!);
    expect((await datasource.getMailRules()).map((r) => r.id), [b.id]);
  });

  test('a corrupt progress file reads as none, never as 0', () async {
    await File('${dir.path}/mail_rule_progress_imap_1.json')
        .writeAsString('{not json');

    expect(await store.loadProgress('imap/1'), isNull);
  });
}
