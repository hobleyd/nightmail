import 'package:flutter/foundation.dart';

import '../../core/error/failures.dart';
import '../../core/utils/special_folder_kind.dart';
import '../../data/datasources/local/mail_rule_store.dart';
import '../../data/datasources/remote/email_remote_datasource.dart';
import '../../domain/entities/email_folder.dart';
import '../../domain/entities/mail_rule.dart';
import '../../domain/repositories/mail_rules_repository.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';
import '../sync/imap_connection_gate.dart';

enum RuleMigrationStatus {
  /// Ran to the end; see the counts for what happened to each rule.
  done,

  /// The source has no rules, or no rules at all for its account type.
  nothingToCopy,

  /// The target's token cannot write rules yet, and a background job cannot
  /// open a sign-in window — the dialog offers it.
  needsPermission,

  /// Could not read or write rules at all; [RuleMigrationResult.message].
  failed,
}

/// What the user chose to do with the old account's copies of the migrated
/// rules — asked once the copy is done, because while mail still reaches
/// both accounts both sets of rules act on it (two forwards, say).
enum SourceRulesDecision {
  undecided,
  turnedOff,
  keptRunning,
}

class SkippedRule {
  const SkippedRule(this.name, this.reason);

  final String name;
  final String reason;
}

/// What copying one account's rules to another came to.
class RuleMigrationResult {
  const RuleMigrationResult({
    required this.status,
    this.copied = 0,
    this.alreadyThere = 0,
    this.skipped = const [],
    this.message,
    this.migratedSourceRuleIds = const [],
    this.sourceCanDisable = true,
    this.sourceRunsOnServer = true,
    this.sourceRules = SourceRulesDecision.undecided,
    this.sourceRulesMessage,
  });

  final RuleMigrationStatus status;
  final int copied;
  final int alreadyThere;
  final List<SkippedRule> skipped;
  final String? message;

  /// The old account's rules that now exist on the new one — copied, or
  /// found already there. Only these are offered to be switched off; a
  /// skipped rule has no copy, and turning it off would just lose it.
  final List<String> migratedSourceRuleIds;

  /// The old account can switch a rule off (not Gmail).
  final bool sourceCanDisable;

  /// The old account's rules live on its server, so switching them off may
  /// need the write permission there.
  final bool sourceRunsOnServer;

  final SourceRulesDecision sourceRules;

  /// Why switching the old rules off did not finish, or that it needs a
  /// sign-in first.
  final String? sourceRulesMessage;

  /// The dialog should ask what to do with the old rules.
  bool get asksAboutSourceRules =>
      status == RuleMigrationStatus.done &&
      migratedSourceRuleIds.isNotEmpty &&
      sourceRules == SourceRulesDecision.undecided;

  RuleMigrationResult withSourceRules(
    SourceRulesDecision decision, {
    String? message,
  }) => RuleMigrationResult(
    status: status,
    copied: copied,
    alreadyThere: alreadyThere,
    skipped: skipped,
    message: this.message,
    migratedSourceRuleIds: migratedSourceRuleIds,
    sourceCanDisable: sourceCanDisable,
    sourceRunsOnServer: sourceRunsOnServer,
    sourceRules: decision,
    sourceRulesMessage: message,
  );

  /// Worth running again on the job's next pass. A finished copy is not:
  /// re-running it would bring back a migrated rule the user has since
  /// deleted or changed on the new server.
  bool get shouldRetry =>
      status == RuleMigrationStatus.needsPermission ||
      status == RuleMigrationStatus.failed;

  Map<String, dynamic> toJson() => {
    'status': status.name,
    'copied': copied,
    'alreadyThere': alreadyThere,
    'skipped': [
      for (final s in skipped) {'name': s.name, 'reason': s.reason},
    ],
    'message': message,
    'migratedSourceRuleIds': migratedSourceRuleIds,
    'sourceCanDisable': sourceCanDisable,
    'sourceRunsOnServer': sourceRunsOnServer,
    'sourceRules': sourceRules.name,
    'sourceRulesMessage': sourceRulesMessage,
  };

  static RuleMigrationResult? fromJson(Map<String, dynamic>? json) {
    if (json == null) return null;
    final status = RuleMigrationStatus.values
        .where((s) => s.name == json['status'])
        .firstOrNull;
    if (status == null) return null;
    return RuleMigrationResult(
      status: status,
      copied: (json['copied'] as num?)?.toInt() ?? 0,
      alreadyThere: (json['alreadyThere'] as num?)?.toInt() ?? 0,
      skipped: [
        for (final s in (json['skipped'] as List?) ?? const [])
          if (s is Map)
            SkippedRule('${s['name'] ?? ''}', '${s['reason'] ?? ''}'),
      ],
      message: json['message'] as String?,
      migratedSourceRuleIds: [
        for (final id in (json['migratedSourceRuleIds'] as List?) ?? const [])
          if (id is String) id,
      ],
      sourceCanDisable: json['sourceCanDisable'] as bool? ?? true,
      sourceRunsOnServer: json['sourceRunsOnServer'] as bool? ?? true,
      sourceRules:
          SourceRulesDecision.values
              .where((d) => d.name == json['sourceRules'])
              .firstOrNull ??
          SourceRulesDecision.undecided,
      sourceRulesMessage: json['sourceRulesMessage'] as String?,
    );
  }
}

/// Copies an account's mail rules to the account its mail is being migrated
/// to, as part of `AccountMigrationService`'s job.
///
/// **Strict:** a rule is copied only if the new server can say exactly the
/// same thing, because a rule that has lost a condition or an exception acts
/// on more mail than it did — a delete rule most of all. Everything else is
/// skipped with the reason, for the migration dialog. The one loosening is
/// "stop processing more rules" into Gmail, which has no rule order: dropped
/// only when no later rule deletes or forwards, since then the only
/// difference is that a later move or label also applies.
///
/// **Once per account pair.** The result is kept (`MailRuleStore`) and a
/// finished copy is never repeated: a migration job re-runs whenever it is
/// resumed or re-scanned, and copying again would bring back a migrated rule
/// the user has deleted or changed on the new server. A rule identical to
/// one already on the target counts as already there, as a second guard.
class MailRuleMigrator {
  MailRuleMigrator({
    required this._repository,
    required this._accountManager,
    required this._store,
    required this._imapConnectionGate,
  });

  final MailRulesRepository _repository;
  final AccountManager _accountManager;
  final MailRuleStore _store;
  final ImapConnectionGate _imapConnectionGate;

  Future<RuleMigrationResult?> lastResult(
    String sourceAccountId,
    String targetAccountId,
  ) async => RuleMigrationResult.fromJson(
    await _store.loadMigrationResult(sourceAccountId, targetAccountId),
  );

  /// Copies the rules unless a previous pass already did; see the class doc.
  Future<RuleMigrationResult> migrateOnce(Account source, Account target) async {
    final prior = await lastResult(source.id, target.id);
    if (prior != null && !prior.shouldRetry) return prior;
    return migrateNow(source, target);
  }

  /// Copies the rules regardless of a previous result — the dialog's retry
  /// after the user has granted the permission.
  Future<RuleMigrationResult> migrateNow(Account source, Account target) async {
    RuleMigrationResult result;
    try {
      result = await _migrate(source, target);
    } catch (e) {
      result = RuleMigrationResult(
        status: RuleMigrationStatus.failed,
        message: '$e',
      );
    }
    debugPrint('[MailRules] migrate ${source.id} -> ${target.id}: '
        '${result.status.name}, ${result.copied} copied, '
        '${result.alreadyThere} already there, ${result.skipped.length} '
        'skipped${result.message == null ? '' : ' (${result.message})'}');
    await _store.saveMigrationResult(source.id, target.id, result.toJson());
    return result;
  }

  Future<RuleMigrationResult> _migrate(Account source, Account target) async {
    final sourceSet = await _repository.getMailRules(source.id);
    final failure = sourceSet.getLeft().toNullable();
    if (failure is UnsupportedFailure) {
      return const RuleMigrationResult(status: RuleMigrationStatus.nothingToCopy);
    }
    if (failure != null) {
      return RuleMigrationResult(
        status: RuleMigrationStatus.failed,
        message: 'Could not read the rules to copy: ${failure.message}',
      );
    }
    final from = sourceSet.getRight().toNullable()!;
    if (from.rules.isEmpty) {
      return const RuleMigrationResult(status: RuleMigrationStatus.nothingToCopy);
    }

    final targetSet = await _repository.getMailRules(target.id);
    final targetFailure = targetSet.getLeft().toNullable();
    if (targetFailure != null) {
      return RuleMigrationResult(
        status: RuleMigrationStatus.failed,
        message: targetFailure is UnsupportedFailure
            ? targetFailure.message
            : 'Could not read the new account\'s rules: '
                  '${targetFailure.message}',
      );
    }
    final to = targetSet.getRight().toNullable()!;
    // Branch on where the rules live, not on the token: an IMAP target's
    // rules are files on this device, and the OAuth check answers false.
    if (to.capabilities.runsOnServer &&
        !await _accountManager.hasOutOfOfficeWriteAccess(target.id)) {
      return const RuleMigrationResult(
        status: RuleMigrationStatus.needsPermission,
      );
    }

    final translator = MailRuleTranslator(
      sourceIsGmail: source is GmailAccount,
      target: to.capabilities,
      targetIsGmail: target is GmailAccount,
      folders: _FolderMapper(this, source, target),
    );
    final existing = [...to.rules];
    var sequence = existing.fold<int>(
      0,
      (m, r) => r.sequence > m ? r.sequence : m,
    );
    var copied = 0;
    var alreadyThere = 0;
    final skipped = <SkippedRule>[];
    final migrated = <String>[];
    final ordered = [...from.rules]
      ..sort((a, b) => a.sequence.compareTo(b.sequence));

    for (var i = 0; i < ordered.length; i++) {
      final rule = ordered[i];
      final label = rule.name.isNotEmpty ? rule.name : 'Rule ${i + 1}';
      final outcome = await translator.translate(
        rule,
        later: ordered.sublist(i + 1),
        name: label,
      );
      if (outcome.reason != null) {
        skipped.add(SkippedRule(label, outcome.reason!));
        continue;
      }
      final translated = outcome.rule!.copyWith(sequence: ++sequence);
      if (existing.any((r) => sameRule(r, translated))) {
        alreadyThere++;
        if (rule.id != null) migrated.add(rule.id!);
        continue;
      }
      final saved = await _repository.saveMailRule(target.id, translated);
      final saveFailure = saved.getLeft().toNullable();
      if (saveFailure == null) {
        copied++;
        existing.add(translated);
        if (rule.id != null) migrated.add(rule.id!);
      } else if (saveFailure.message.toLowerCase().contains('already exists')) {
        // Gmail's answer to a filter identical to one it holds.
        alreadyThere++;
        if (rule.id != null) migrated.add(rule.id!);
      } else {
        skipped.add(SkippedRule(label, saveFailure.message));
      }
    }
    return RuleMigrationResult(
      status: RuleMigrationStatus.done,
      copied: copied,
      alreadyThere: alreadyThere,
      skipped: skipped,
      migratedSourceRuleIds: migrated,
      sourceCanDisable: from.capabilities.canDisable,
      sourceRunsOnServer: from.capabilities.runsOnServer,
    );
  }

  /// Records the answer to "switch the old rules off?", switching them off
  /// when [turnOff]. Each is a toggle of `isEnabled` alone, so a rule holding
  /// settings NightMail cannot show loses nothing. On a server account
  /// without the write permission nothing is changed and the result says a
  /// sign-in is needed — the caller runs it, never a background job. A rule
  /// that fails to switch off (deleted since, say) is reported, and the
  /// question stays open so it can be tried again.
  Future<RuleMigrationResult?> decideSourceRules(
    Account source,
    Account target, {
    required bool turnOff,
  }) async {
    final prior = await lastResult(source.id, target.id);
    if (prior == null || !prior.asksAboutSourceRules) return prior;

    RuleMigrationResult result;
    if (!turnOff) {
      result = prior.withSourceRules(SourceRulesDecision.keptRunning);
    } else if (prior.sourceRunsOnServer &&
        !await _accountManager.hasOutOfOfficeWriteAccess(source.id)) {
      result = prior.withSourceRules(
        SourceRulesDecision.undecided,
        message: needsPermissionMessage,
      );
    } else {
      final failures = <String>[];
      for (final id in prior.migratedSourceRuleIds) {
        final done = await _repository.setMailRuleEnabled(source.id, id, false);
        final failure = done.getLeft().toNullable();
        if (failure != null) failures.add(failure.message);
      }
      result = failures.isEmpty
          ? prior.withSourceRules(SourceRulesDecision.turnedOff)
          : prior.withSourceRules(
              SourceRulesDecision.undecided,
              message:
                  '${failures.length} could not be turned off: '
                  '${failures.toSet().join('; ')}',
            );
    }
    debugPrint('[MailRules] old rules on ${source.id}: '
        '${result.sourceRules.name}'
        '${result.sourceRulesMessage == null ? '' : ' (${result.sourceRulesMessage})'}');
    await _store.saveMigrationResult(source.id, target.id, result.toJson());
    return result;
  }

  /// Marks the result as waiting on the old account's sign-in — the dialog
  /// offers it in place of a plain "Turn off".
  static const needsPermissionMessage = 'needs-permission';

  /// The same conditions, exceptions and actions, in any order — names,
  /// sequence and ids aside, which differ by provider.
  @visibleForTesting
  static bool sameRule(MailRule a, MailRule b) {
    bool same<T>(List<T> x, List<T> y) =>
        x.length == y.length && x.toSet().containsAll(y);
    return same(a.conditions, b.conditions) &&
        same(a.exceptions, b.exceptions) &&
        same(a.actions, b.actions);
  }

  Future<T> _guarded<T>(Account account, Future<T> Function() body) =>
      account is ImapAccount
      ? _imapConnectionGate.runExclusive(account.id, body)
      : body();
}

/// Where a folder a rule files into lives on the new server.
class FolderTarget {
  const FolderTarget(this.id, {this.kind});

  final String id;

  /// Set when this is the target's special folder of that kind.
  final SpecialFolderKind? kind;
}

/// Resolves a source rule's folder on the target, creating it if need be.
abstract interface class RuleFolderResolver {
  /// Null with a reason when it cannot be resolved.
  Future<(FolderTarget?, String?)> resolve(String sourceFolderId);
}

/// Turns one provider's rule into another's, or says why it cannot. Pure
/// apart from the folder resolver, so it is tested without servers.
class MailRuleTranslator {
  MailRuleTranslator({
    required this.sourceIsGmail,
    required this.target,
    required this.targetIsGmail,
    required this.folders,
  });

  final bool sourceIsGmail;
  final MailRuleCapabilities target;
  final bool targetIsGmail;
  final RuleFolderResolver folders;

  /// An exact-address condition the target lacks, and the "contains" test
  /// that stands in for it. Outlook's own "from X" rule is `fromAddresses`;
  /// without this most Outlook rules could not reach Gmail at all.
  static const _standIns = {
    MailRuleConditionKind.fromAddresses: MailRuleConditionKind.senderContains,
    MailRuleConditionKind.sentToAddresses:
        MailRuleConditionKind.recipientContains,
  };

  static const _destructive = {
    MailRuleActionKind.delete,
    MailRuleActionKind.permanentDelete,
    MailRuleActionKind.forwardTo,
    MailRuleActionKind.forwardAsAttachmentTo,
    MailRuleActionKind.redirectTo,
  };

  Future<({MailRule? rule, String? reason})> translate(
    MailRule rule, {
    required List<MailRule> later,
    required String name,
  }) async {
    ({MailRule? rule, String? reason}) skip(String why) =>
        (rule: null, reason: why);

    if (rule.isReadOnly || rule.hasUnsupportedParts) {
      return skip('uses settings NightMail cannot read in full');
    }
    if (!rule.enabled && !target.canDisable) {
      return skip('is switched off, and the new server cannot hold a rule '
          'that is off');
    }

    final conditions = _conditions(rule.conditions, target.conditions);
    if (conditions.reason != null) return skip(conditions.reason!);
    final exceptions = _conditions(rule.exceptions, target.exceptions);
    if (exceptions.reason != null) return skip(exceptions.reason!);
    if (conditions.list!.isEmpty) return skip('has no conditions');

    final actions = <MailRuleAction>[];
    for (final a in rule.actions) {
      if (a.kind == MailRuleActionKind.stopProcessingRules && !target.ordered) {
        // Gmail runs every matching filter. Losing "stop" only lets a later
        // move or label apply too — unless a later rule deletes or forwards,
        // when it would reach mail this rule used to shield.
        if (later.any((r) => r.actions.any((x) => _destructive.contains(x.kind)))) {
          return skip('stops later rules, one of which deletes or forwards, '
              'and the new server runs every rule');
        }
        continue;
      }
      if (a.kind.valueType == MailRuleActionValueType.folder) {
        final mapped = await _folderAction(a);
        if (mapped.reason != null) return skip(mapped.reason!);
        actions.add(mapped.action!);
        continue;
      }
      if (!target.actions.contains(a.kind)) {
        return skip('"${a.kind.name}" cannot be done by the new server');
      }
      if (a.kind == MailRuleActionKind.markImportance &&
          !target.markImportanceValues.contains(a.importance)) {
        return skip('sets an importance the new server cannot set');
      }
      actions.add(a);
    }
    if (actions.isEmpty) return skip('has nothing left to do');

    return (
      rule: MailRule(
        name: target.namedRules ? name : '',
        enabled: rule.enabled,
        conditions: conditions.list!,
        exceptions: exceptions.list!,
        actions: actions,
      ),
      reason: null,
    );
  }

  ({List<MailRuleCondition>? list, String? reason}) _conditions(
    List<MailRuleCondition> source,
    Set<MailRuleConditionKind> allowed,
  ) {
    final out = <MailRuleCondition>[];
    for (final c in source) {
      var kind = c.kind;
      if (!allowed.contains(kind)) {
        final standIn = _standIns[kind];
        if (standIn == null || !allowed.contains(standIn)) {
          return (list: null, reason: 'tests "${kind.name}", which the new '
              'server cannot');
        }
        kind = standIn;
      }
      // Two tests landing on one kind would have to become one, and ANDed
      // tests cannot be merged into ORed alternatives.
      if (out.any((o) => o.kind == kind)) {
        return (list: null, reason: 'tests the sender or recipients two ways '
            'at once, which the new server cannot');
      }
      var values = c.values;
      if (kind.valueType == MailRuleValueType.text ||
          kind.valueType == MailRuleValueType.addresses) {
        if (sourceIsGmail && targetIsGmail) {
          // Already Gmail search text, which is what the target wants.
        } else if (sourceIsGmail) {
          final plain = plainGmailValues(values);
          if (plain == null) {
            return (list: null, reason: 'uses Gmail search syntax');
          }
          values = plain;
        }
        if (targetIsGmail && !sourceIsGmail) {
          values = [for (final v in values) quoteForGmail(v)];
        }
      }
      out.add(
        MailRuleCondition(
          kind,
          values: values,
          importance: c.importance,
          sizeKb: c.sizeKb,
        ),
      );
    }
    return (list: out, reason: null);
  }

  Future<({MailRuleAction? action, String? reason})> _folderAction(
    MailRuleAction a,
  ) async {
    ({MailRuleAction? action, String? reason}) skip(String why) =>
        (action: null, reason: why);
    final (folder, why) = await folders.resolve(a.folderId!);
    if (folder == null) return skip(why ?? 'files into a folder that is gone');
    final move = a.kind == MailRuleActionKind.moveToFolder;

    if (targetIsGmail && folder.kind != null) {
      // Gmail's special folders are system labels, not label targets.
      if (move && folder.kind == SpecialFolderKind.trash) {
        return (action: const MailRuleAction(MailRuleActionKind.delete), reason: null);
      }
      if (move && folder.kind == SpecialFolderKind.archive) {
        return (action: const MailRuleAction(MailRuleActionKind.archive), reason: null);
      }
      return skip('files into Gmail\'s ${folder.kind!.name}, which a filter '
          'cannot');
    }
    if (!target.runsOnServer && folder.id.toUpperCase() == 'INBOX') {
      return skip('files into the Inbox, which NightMail\'s own rules do not');
    }
    if (!target.actions.contains(a.kind)) {
      return skip('"${a.kind.name}" cannot be done by the new server');
    }
    return (action: MailRuleAction(a.kind, folderId: folder.id), reason: null);
  }

  /// A Gmail criterion as plain alternatives: `a`, or `a OR b OR c`, with no
  /// brackets, quotes or operators. Anything else is search syntax that has
  /// no literal meaning on another server, and null.
  @visibleForTesting
  static List<String>? plainGmailValues(List<String> values) {
    final out = <String>[];
    for (final v in values) {
      if (RegExp(r'[()"{}]|(^|\s)-|\b(AND|NOT)\b|\w:').hasMatch(v)) return null;
      out.addAll(v.split(' OR ').map((p) => p.trim()).where((p) => p.isNotEmpty));
    }
    return out;
  }

  /// A literal for Gmail's search-syntax criteria. A bare address or domain
  /// goes as it is; anything else is quoted, or `-draft` would mean "not
  /// draft" and `a b` would mean "a and b anywhere".
  @visibleForTesting
  static String quoteForGmail(String value) {
    final v = value.trim();
    if (RegExp(r'^[\w.+-]+(@[\w.-]+)?$').hasMatch(v) && !v.startsWith('-')) {
      return v;
    }
    return '"${v.replaceAll('"', '')}"';
  }
}

/// Maps source folders onto the target by special kind, then by full path,
/// reading both trees live — the cache would miss folders the account
/// migration has just created, and creating one again fails.
class _FolderMapper implements RuleFolderResolver {
  _FolderMapper(this._migrator, this._source, this._target);

  final MailRuleMigrator _migrator;
  final Account _source;
  final Account _target;

  late final EmailRemoteDatasource _sourceDs = _migrator._accountManager
      .buildEmailDatasourceForAccount(_source);
  late final EmailRemoteDatasource _targetDs = _migrator._accountManager
      .buildEmailDatasourceForAccount(_target);

  Map<String, List<String>>? _sourcePaths;
  Map<String, SpecialFolderKind>? _sourceKinds;
  Map<String, String>? _targetByPath;
  Map<SpecialFolderKind, String>? _targetSpecial;

  Future<void> _load() async {
    if (_sourcePaths != null) return;
    final sourceFolders = await _walk(_source, _sourceDs);
    _sourcePaths = _paths(sourceFolders);
    _sourceKinds = {
      for (final e in (await _migrator._guarded(
        _source,
        _sourceDs.getSpecialFolderIds,
      )).entries)
        e.value: e.key,
    };
    final targetFolders = await _walk(_target, _targetDs);
    _targetByPath = {
      for (final MapEntry(:key, :value) in _paths(targetFolders).entries)
        if (!key.startsWith('__virtual__')) _key(value): key,
    };
    _targetSpecial = await _migrator._guarded(
      _target,
      _targetDs.getSpecialFolderIds,
    );
  }

  @override
  Future<(FolderTarget?, String?)> resolve(String sourceFolderId) async {
    await _load();
    final kind = _sourceKinds![sourceFolderId];
    if (kind != null) {
      final id = _targetSpecial![kind];
      if (id != null) return (FolderTarget(id, kind: kind), null);
    }
    final path = _sourcePaths![sourceFolderId];
    if (path == null) {
      return (null, 'files into a folder that no longer exists');
    }
    final existing = _targetByPath![_key(path)];
    if (existing != null) return (FolderTarget(existing), null);
    return (FolderTarget(await _create(path)), null);
  }

  /// Creates [path] one level at a time, reusing levels that exist. Gmail
  /// labels nest by name alone, so there the whole path is one label at the
  /// root — a `__virtual__` parent cannot be created under.
  Future<String> _create(List<String> path) async {
    if (_target is GmailAccount) {
      final id = await _targetDs.createFolder(
        parentFolderId: '',
        displayName: path.join('/'),
      );
      _targetByPath![_key(path)] = id;
      return id;
    }
    var parentId = '';
    for (var depth = 1; depth <= path.length; depth++) {
      final prefix = path.sublist(0, depth);
      final known = _targetByPath![_key(prefix)];
      if (known != null) {
        parentId = known;
        continue;
      }
      final id = await _migrator._guarded(
        _target,
        () => _targetDs.createFolder(
          parentFolderId: parentId,
          displayName: prefix.last,
        ),
      );
      _targetByPath![_key(prefix)] = id;
      parentId = id;
    }
    return parentId;
  }

  static String _key(List<String> path) => path.join('/').toLowerCase();

  /// The same breadth-first walk as the account migration's own.
  Future<List<EmailFolder>> _walk(
    Account account,
    EmailRemoteDatasource ds,
  ) async {
    final roots = await _migrator._guarded(account, ds.getMailFolders);
    final all = <String, EmailFolder>{for (final f in roots) f.id: f};
    final queue = [for (final f in roots) if (f.childFolderCount > 0) f];
    while (queue.isNotEmpty) {
      final parent = queue.removeAt(0);
      final children = await _migrator._guarded(
        account,
        () => ds.getChildFolders(parent.id),
      );
      for (final c in children) {
        if (all.containsKey(c.id)) continue;
        all[c.id] = c;
        if (c.childFolderCount > 0) queue.add(c);
      }
    }
    return all.values.toList();
  }

  static Map<String, List<String>> _paths(List<EmailFolder> folders) {
    final byId = {for (final f in folders) f.id: f};
    List<String> path(EmailFolder f) {
      final parts = [f.displayName];
      final seen = {f.id};
      var parent = f.parentFolderId;
      while (parent != null && seen.add(parent)) {
        final p = byId[parent];
        if (p == null) break;
        parts.insert(0, p.displayName);
        parent = p.parentFolderId;
      }
      return parts;
    }

    return {for (final f in folders) f.id: path(f)};
  }
}
