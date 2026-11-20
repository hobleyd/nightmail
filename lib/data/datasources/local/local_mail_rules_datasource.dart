import 'dart:math';

import '../../../domain/entities/mail_rule.dart';
import '../remote/mail_rules_datasource.dart';
import 'mail_rule_store.dart';

/// An IMAP account's rules, which NightMail stores and runs itself.
///
/// The same interface as the Graph and Gmail datasources so the Rules screen
/// needs no branch for it; [MailRuleCapabilities.local] says what it can do,
/// and `runsOnServer: false` is what tells the cubit no permission is needed.
/// The running half is `LocalMailRuleRunner`.
class LocalMailRulesDatasource implements MailRulesDatasource {
  LocalMailRulesDatasource({required this._store, required this._accountId});

  final MailRuleStore _store;
  final String _accountId;

  static final _random = Random.secure();

  @override
  MailRuleCapabilities get mailRuleCapabilities => MailRuleCapabilities.local;

  @override
  Future<List<MailRule>> getMailRules() => _store.loadRules(_accountId);

  @override
  Future<void> createMailRule(MailRule rule) async {
    final rules = await _store.loadRules(_accountId);
    final id =
        '${DateTime.now().microsecondsSinceEpoch}-${_random.nextInt(1 << 32)}';
    await _store.saveRules(_accountId, [...rules, _withId(rule, id)]);
  }

  @override
  Future<void> updateMailRule(MailRule rule) => _edit(
    rule.id!,
    (_) => rule,
  );

  @override
  Future<void> deleteMailRule(String id) async {
    final rules = await _store.loadRules(_accountId);
    await _store.saveRules(_accountId, [
      for (final r in rules)
        if (r.id != id) r,
    ]);
  }

  @override
  Future<void> setMailRuleEnabled(String id, bool enabled) =>
      _edit(id, (r) => r.copyWith(enabled: enabled));

  @override
  Future<void> reorderMailRules(Map<String, int> sequences) async {
    final rules = await _store.loadRules(_accountId);
    await _store.saveRules(_accountId, [
      for (final r in rules)
        sequences.containsKey(r.id) ? r.copyWith(sequence: sequences[r.id]) : r,
    ]);
  }

  Future<void> _edit(String id, MailRule Function(MailRule) change) async {
    final rules = await _store.loadRules(_accountId);
    if (!rules.any((r) => r.id == id)) {
      throw StateError('That rule no longer exists.');
    }
    await _store.saveRules(_accountId, [
      for (final r in rules) r.id == id ? change(r) : r,
    ]);
  }

  static MailRule _withId(MailRule rule, String id) => MailRule(
    id: id,
    name: rule.name,
    enabled: rule.enabled,
    sequence: rule.sequence,
    conditions: rule.conditions,
    exceptions: rule.exceptions,
    actions: rule.actions,
  );
}
