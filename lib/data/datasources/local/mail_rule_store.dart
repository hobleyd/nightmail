import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../../../core/platform/app_data_directory.dart';
import '../../../domain/entities/mail_rule.dart';
import '../remote/mail_rule_codecs.dart';

/// How far [LocalMailRuleRunner] has got through one account's Inbox.
///
/// IMAP UIDs only ever grow within one [uidValidity], so "the highest UID the
/// rules have been offered" is the whole of the progress. Kept in its own
/// file, apart from the rules: the runner writes it every message and the
/// Rules screen writes the rules, and neither may overwrite the other's.
class MailRuleProgress {
  const MailRuleProgress({required this.uidValidity, required this.lastUid});

  final int? uidValidity;
  final int lastUid;

  Map<String, dynamic> toJson() => {
    'uidValidity': uidValidity,
    'lastUid': lastUid,
  };

  static MailRuleProgress? fromJson(Object? json) {
    if (json is! Map<String, dynamic>) return null;
    final lastUid = (json['lastUid'] as num?)?.toInt();
    if (lastUid == null) return null;
    return MailRuleProgress(
      uidValidity: (json['uidValidity'] as num?)?.toInt(),
      lastUid: lastUid,
    );
  }
}

/// NightMail's own copy of an IMAP account's rules, and the runner's progress.
///
/// Files in the app data directory, the same as `AppSettings`: read fresh on
/// every call, so the Rules screen and the poller in the main window, and any
/// other window, all see the same thing without a shared cache. Rules are
/// stored in Graph's `messageRule` JSON (`GraphMailRuleCodec`) — the entity's
/// names are Graph's, so there is nothing to invent.
class MailRuleStore {
  MailRuleStore({Future<Directory> Function()? directory})
    : _directory = directory ?? appDataDirectory;

  final Future<Directory> Function() _directory;

  static const _rulesPrefix = 'mail_rules_';
  static const _progressPrefix = 'mail_rule_progress_';

  Future<List<MailRule>> loadRules(String accountId) async {
    final json = await _read('$_rulesPrefix${_safe(accountId)}.json');
    if (json is! List) return const [];
    return [
      for (final item in json)
        if (item is Map<String, dynamic>)
          GraphMailRuleCodec.decode(
            item,
            actionKinds: MailRuleCapabilities.local.actions,
          ),
    ]..sort((a, b) => a.sequence.compareTo(b.sequence));
  }

  Future<void> saveRules(String accountId, List<MailRule> rules) => _write(
    '$_rulesPrefix${_safe(accountId)}.json',
    [
      for (final r in rules) {'id': r.id, ...GraphMailRuleCodec.encode(r)},
    ],
  );

  Future<MailRuleProgress?> loadProgress(String accountId) async =>
      MailRuleProgress.fromJson(
        await _read('$_progressPrefix${_safe(accountId)}.json'),
      );

  Future<void> saveProgress(String accountId, MailRuleProgress progress) =>
      _write('$_progressPrefix${_safe(accountId)}.json', progress.toJson());

  Future<void> clearProgress(String accountId) async {
    final file = File(
      '${(await _directory()).path}/$_progressPrefix${_safe(accountId)}.json',
    );
    if (await file.exists()) await file.delete();
  }

  static const _migrationPrefix = 'mail_rule_migration_';

  /// What copying rules from one account to another last came to, keyed by
  /// the account pair — `MailRuleMigrator`'s once-only marker and the
  /// migration dialog's summary. Per pair, not per job: an Inbox job and a
  /// whole-account job between the same two accounts must not copy twice.
  Future<Map<String, dynamic>?> loadMigrationResult(
    String sourceAccountId,
    String targetAccountId,
  ) async {
    final json = await _read(_migrationName(sourceAccountId, targetAccountId));
    return json is Map<String, dynamic> ? json : null;
  }

  Future<void> saveMigrationResult(
    String sourceAccountId,
    String targetAccountId,
    Map<String, dynamic> result,
  ) => _write(_migrationName(sourceAccountId, targetAccountId), result);

  static String _migrationName(String source, String target) =>
      '$_migrationPrefix${_safe(source)}__${_safe(target)}.json';

  /// A corrupt or unreadable file reads as absent. For progress that is the
  /// safe direction: the runner restarts from the Inbox's newest message and
  /// processes nothing old, rather than from 0.
  Future<Object?> _read(String name) async {
    try {
      final file = File('${(await _directory()).path}/$name');
      if (!await file.exists()) return null;
      return jsonDecode(await file.readAsString());
    } catch (e) {
      debugPrint('[MailRules] could not read $name: $e');
      return null;
    }
  }

  /// Written to a temporary file and renamed over the real one, so a crash
  /// mid-write leaves the previous rules rather than half a JSON document.
  Future<void> _write(String name, Object json) async {
    final dir = await _directory();
    final tmp = File('${dir.path}/$name.tmp');
    await tmp.writeAsString(jsonEncode(json), flush: true);
    await tmp.rename('${dir.path}/$name');
  }

  static String _safe(String accountId) =>
      accountId.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
}
