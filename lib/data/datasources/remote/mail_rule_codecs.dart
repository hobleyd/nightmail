import '../../../domain/entities/mail_rule.dart';

/// Graph's inbox `messageRule` ↔ [MailRule]. Nightware implements the same
/// resource, so this is its wire format too.
///
/// The predicate and action keys are the enum names in `mail_rule.dart`, which
/// were taken from Graph for exactly that reason. Anything the entity does not
/// model is not dropped: it marks the rule [MailRule.hasUnsupportedParts],
/// because a PATCH replaces `conditions` and `actions` whole and saving from
/// the form would quietly delete it.
abstract final class GraphMailRuleCodec {
  /// [actionKinds] narrows which actions decode; the default is Graph's own.
  /// NightMail's local IMAP rules are stored in this same format with their
  /// own set — see `MailRuleStore`.
  static MailRule decode(
    Map<String, dynamic> json, {
    Set<MailRuleActionKind>? actionKinds,
  }) {
    var unsupported = false;
    List<MailRuleCondition> predicates(Object? raw) {
      final result = decodePredicates(raw);
      if (result.unsupported) unsupported = true;
      return result.conditions;
    }

    final conditions = predicates(json['conditions']);
    final exceptions = predicates(json['exceptions']);
    final actions = decodeActions(json['actions'], kinds: actionKinds);
    if (actions.unsupported) unsupported = true;

    return MailRule(
      id: json['id'] as String?,
      name: json['displayName'] as String? ?? '',
      enabled: json['isEnabled'] as bool? ?? true,
      sequence: (json['sequence'] as num?)?.toInt() ?? 0,
      conditions: conditions,
      exceptions: exceptions,
      actions: actions.actions,
      hasError: json['hasError'] as bool? ?? false,
      isReadOnly: json['isReadOnly'] as bool? ?? false,
      hasUnsupportedParts: unsupported,
    );
  }

  /// The body of a create or a full update. `conditions`, `exceptions` and
  /// `actions` are always sent, empty when there is nothing in them: Graph
  /// replaces a complex property on PATCH, so an omitted `exceptions` would
  /// leave the old exceptions in place after the user removed them.
  static Map<String, dynamic> encode(MailRule rule) => {
    'displayName': rule.name,
    'sequence': rule.sequence,
    'isEnabled': rule.enabled,
    'conditions': encodePredicates(rule.conditions),
    'exceptions': encodePredicates(rule.exceptions),
    'actions': encodeActions(rule.actions),
  };

  static ({List<MailRuleCondition> conditions, bool unsupported})
  decodePredicates(Object? raw) {
    if (raw is! Map<String, dynamic>) {
      return (conditions: const [], unsupported: false);
    }
    final conditions = <MailRuleCondition>[];
    var unsupported = false;
    for (final MapEntry(:key, :value) in raw.entries) {
      if (key.startsWith('@odata') || _isEmpty(value)) continue;
      if (key == 'withinSizeRange') {
        final range = value as Map<String, dynamic>;
        final min = (range['minimumSize'] as num?)?.toInt() ?? 0;
        final max = (range['maximumSize'] as num?)?.toInt() ?? 0;
        // Graph sizes are in KB. 0 is no lower bound, and [_noUpperBound]
        // (what encode writes for an open top) no upper one.
        if (min > 0) {
          conditions.add(
            MailRuleCondition(MailRuleConditionKind.minimumSize, sizeKb: min),
          );
        }
        if (max > 0 && max < _noUpperBound) {
          conditions.add(
            MailRuleCondition(MailRuleConditionKind.maximumSize, sizeKb: max),
          );
        }
        continue;
      }
      final kind = _conditionKinds[key];
      final condition = kind == null ? null : _decodeCondition(kind, value);
      if (condition == null) {
        unsupported = true;
      } else {
        conditions.add(condition);
      }
    }
    return (conditions: conditions, unsupported: unsupported);
  }

  static Map<String, dynamic> encodePredicates(
    List<MailRuleCondition> conditions,
  ) {
    final out = <String, dynamic>{};
    final range = <String, dynamic>{};
    for (final c in conditions) {
      switch (c.kind) {
        case MailRuleConditionKind.minimumSize:
          range['minimumSize'] = c.sizeKb ?? 0;
        case MailRuleConditionKind.maximumSize:
          range['maximumSize'] = c.sizeKb ?? 0;
        default:
          out[c.kind.name] = switch (c.kind.valueType) {
            MailRuleValueType.text => _cleaned(c.values),
            MailRuleValueType.addresses => _recipients(c.values),
            MailRuleValueType.flag => true,
            MailRuleValueType.importance => c.importance!.name,
            MailRuleValueType.size => throw StateError('handled above'),
          };
      }
    }
    if (range.isNotEmpty) {
      // `sizeRange` has both fields and Graph's docs do not say what an
      // absent or zero maximum means, so the open side is written as a bound
      // that is literally true: nothing is smaller than 0 KB, nothing larger
      // than Int32's maximum. A guessed "0 means unbounded" that Graph read
      // literally would make "at least 500 KB" match nothing, silently.
      out['withinSizeRange'] = {
        'minimumSize': range['minimumSize'] ?? 0,
        'maximumSize': range['maximumSize'] ?? _noUpperBound,
      };
    }
    return out;
  }

  static ({List<MailRuleAction> actions, bool unsupported}) decodeActions(
    Object? raw, {
    Set<MailRuleActionKind>? kinds,
  }) {
    if (raw is! Map<String, dynamic>) {
      return (actions: const [], unsupported: false);
    }
    final actions = <MailRuleAction>[];
    var unsupported = false;
    for (final MapEntry(:key, :value) in raw.entries) {
      if (key.startsWith('@odata') || _isEmpty(value)) continue;
      final kind = kinds == null
          ? _graphActionKinds[key]
          : kinds.where((k) => k.name == key).firstOrNull;
      final action = kind == null ? null : _decodeAction(kind, value);
      if (action == null) {
        unsupported = true;
      } else {
        actions.add(action);
      }
    }
    return (actions: actions, unsupported: unsupported);
  }

  static Map<String, dynamic> encodeActions(List<MailRuleAction> actions) => {
    for (final a in actions)
      a.kind.name: switch (a.kind.valueType) {
        MailRuleActionValueType.none => true,
        MailRuleActionValueType.folder => a.folderId,
        MailRuleActionValueType.importance => a.importance!.name,
        MailRuleActionValueType.addresses => _recipients(a.addresses),
      },
  };

  /// Int32's maximum, the widest `maximumSize` Graph can hold.
  static const _noUpperBound = 2147483647;

  static final _conditionKinds = {
    for (final k in MailRuleConditionKind.values)
      if (k.valueType != MailRuleValueType.size) k.name: k,
  };

  /// The Gmail-only actions have no Graph key and are deliberately absent:
  /// a Graph rule can never decode to them.
  static final _graphActionKinds = {
    for (final k in MailRuleCapabilities.graph.actions) k.name: k,
  };

  static MailRuleCondition? _decodeCondition(
    MailRuleConditionKind kind,
    Object? value,
  ) {
    return switch (kind.valueType) {
      MailRuleValueType.text when value is List =>
        MailRuleCondition(kind, values: value.whereType<String>().toList()),
      MailRuleValueType.addresses when value is List =>
        MailRuleCondition(kind, values: _addresses(value)),
      MailRuleValueType.flag when value == true => MailRuleCondition(kind),
      MailRuleValueType.importance =>
        _importance(value) == null
            ? null
            : MailRuleCondition(kind, importance: _importance(value)),
      _ => null,
    };
  }

  static MailRuleAction? _decodeAction(MailRuleActionKind kind, Object? value) {
    return switch (kind.valueType) {
      MailRuleActionValueType.none when value == true => MailRuleAction(kind),
      MailRuleActionValueType.folder when value is String =>
        MailRuleAction(kind, folderId: value),
      MailRuleActionValueType.importance =>
        _importance(value) == null
            ? null
            : MailRuleAction(kind, importance: _importance(value)),
      MailRuleActionValueType.addresses when value is List =>
        MailRuleAction(kind, addresses: _addresses(value)),
      _ => null,
    };
  }

  /// Graph sends every predicate on some tenants, unset ones as `null`,
  /// `false` or `[]`. None of those is a condition.
  static bool _isEmpty(Object? value) =>
      value == null ||
      value == false ||
      (value is List && value.isEmpty) ||
      (value is Map && value.isEmpty);

  static MailRuleImportance? _importance(Object? raw) => switch (raw) {
    'low' => MailRuleImportance.low,
    'normal' => MailRuleImportance.normal,
    'high' => MailRuleImportance.high,
    _ => null,
  };

  static List<String> _addresses(List<dynamic> recipients) => [
    for (final r in recipients)
      if (r is Map && r['emailAddress'] is Map)
        (r['emailAddress'] as Map)['address'] as String? ?? '',
  ].where((a) => a.isNotEmpty).toList();

  static List<Map<String, dynamic>> _recipients(List<String> addresses) => [
    for (final a in _cleaned(addresses))
      {
        'emailAddress': {'address': a},
      },
  ];
}

/// A Gmail filter ↔ [MailRule].
///
/// Gmail's model is search criteria plus label changes, so most of a
/// [MailRule]'s actions are label arithmetic: a move is "add the label, take
/// it out of the inbox", mark-as-read is "remove UNREAD". The criteria fields
/// are free-form search text, carried verbatim as a single value so an
/// untouched filter writes back exactly as Gmail stored it.
abstract final class GmailFilterCodec {
  static const _inbox = 'INBOX';
  static const _unread = 'UNREAD';
  static const _trash = 'TRASH';
  static const _starred = 'STARRED';
  static const _important = 'IMPORTANT';
  static const _spam = 'SPAM';

  static MailRule decode(Map<String, dynamic> json, {int sequence = 0}) {
    var unsupported = false;
    final criteria = json['criteria'] as Map<String, dynamic>? ?? const {};
    final conditions = <MailRuleCondition>[];
    final exceptions = <MailRuleCondition>[];

    for (final MapEntry(:key, :value) in criteria.entries) {
      if (value == null || value == false || value == '') continue;
      final kind = switch (key) {
        'from' => MailRuleConditionKind.senderContains,
        'to' => MailRuleConditionKind.recipientContains,
        'subject' => MailRuleConditionKind.subjectContains,
        'query' => MailRuleConditionKind.bodyOrSubjectContains,
        _ => null,
      };
      if (kind != null && value is String) {
        conditions.add(MailRuleCondition(kind, values: [value]));
      } else if (key == 'negatedQuery' && value is String) {
        exceptions.add(
          MailRuleCondition(
            MailRuleConditionKind.bodyOrSubjectContains,
            values: [value],
          ),
        );
      } else if (key == 'hasAttachment' && value == true) {
        conditions.add(
          const MailRuleCondition(MailRuleConditionKind.hasAttachments),
        );
      } else if (key == 'excludeChats') {
        // Chats are not mail; Gmail's own UI no longer sets this.
      } else {
        // size/sizeComparison, and anything Google adds later.
        unsupported = true;
      }
    }

    final action = json['action'] as Map<String, dynamic>? ?? const {};
    final add = {...?(action['addLabelIds'] as List?)?.cast<String>()};
    final remove = {...?(action['removeLabelIds'] as List?)?.cast<String>()};
    final actions = <MailRuleAction>[];

    if (add.remove(_trash)) {
      actions.add(const MailRuleAction(MailRuleActionKind.delete));
    }
    if (add.remove(_starred)) {
      actions.add(const MailRuleAction(MailRuleActionKind.star));
    }
    if (add.remove(_important)) {
      actions.add(
        const MailRuleAction(
          MailRuleActionKind.markImportance,
          importance: MailRuleImportance.high,
        ),
      );
    }
    if (remove.remove(_important)) {
      actions.add(
        const MailRuleAction(
          MailRuleActionKind.markImportance,
          importance: MailRuleImportance.low,
        ),
      );
    }
    if (remove.remove(_unread)) {
      actions.add(const MailRuleAction(MailRuleActionKind.markAsRead));
    }
    if (remove.remove(_spam)) {
      actions.add(const MailRuleAction(MailRuleActionKind.neverSpam));
    }

    // What is left must be user labels added, and at most INBOX removed.
    // A system label in either set (CATEGORY_*, a second removal) is a filter
    // this screen cannot draw.
    final userLabels = add.where(isUserLabel).toList();
    if (userLabels.length != add.length || remove.difference({_inbox}).isNotEmpty) {
      unsupported = true;
    }
    if (remove.contains(_inbox)) {
      if (userLabels.length == 1) {
        actions.add(
          MailRuleAction(
            MailRuleActionKind.moveToFolder,
            folderId: userLabels.removeAt(0),
          ),
        );
      } else {
        actions.add(const MailRuleAction(MailRuleActionKind.archive));
      }
    }
    if (userLabels.length == 1) {
      actions.add(
        MailRuleAction(MailRuleActionKind.copyToFolder, folderId: userLabels.first),
      );
    } else if (userLabels.length > 1) {
      unsupported = true;
    }

    // A forward goes only to a verified address, which this screen cannot
    // set up — see MailRuleCapabilities.gmail.
    if ((action['forward'] as String?)?.isNotEmpty ?? false) unsupported = true;

    return MailRule(
      id: json['id'] as String?,
      sequence: sequence,
      conditions: conditions,
      exceptions: exceptions,
      actions: actions,
      hasUnsupportedParts: unsupported,
    );
  }

  static Map<String, dynamic> encode(MailRule rule) {
    final criteria = <String, dynamic>{};
    for (final c in rule.conditions) {
      final key = switch (c.kind) {
        MailRuleConditionKind.senderContains => 'from',
        MailRuleConditionKind.recipientContains => 'to',
        MailRuleConditionKind.subjectContains => 'subject',
        MailRuleConditionKind.bodyOrSubjectContains => 'query',
        MailRuleConditionKind.hasAttachments => 'hasAttachment',
        _ => throw ArgumentError('Gmail filters cannot test ${c.kind.name}'),
      };
      criteria[key] = c.kind == MailRuleConditionKind.hasAttachments
          ? true
          : _query(c.values);
    }
    for (final c in rule.exceptions) {
      if (c.kind != MailRuleConditionKind.bodyOrSubjectContains) {
        throw ArgumentError('Gmail filters cannot except ${c.kind.name}');
      }
      criteria['negatedQuery'] = _query(c.values);
    }

    final add = <String>[];
    final remove = <String>[];
    for (final a in rule.actions) {
      switch (a.kind) {
        case MailRuleActionKind.moveToFolder:
          add.add(a.folderId!);
          remove.add(_inbox);
        case MailRuleActionKind.copyToFolder:
          add.add(a.folderId!);
        case MailRuleActionKind.archive:
          remove.add(_inbox);
        case MailRuleActionKind.delete:
          add.add(_trash);
        case MailRuleActionKind.markAsRead:
          remove.add(_unread);
        case MailRuleActionKind.star:
          add.add(_starred);
        case MailRuleActionKind.markImportance:
          (a.importance == MailRuleImportance.low ? remove : add).add(_important);
        case MailRuleActionKind.neverSpam:
          remove.add(_spam);
        default:
          throw ArgumentError('Gmail filters cannot ${a.kind.name}');
      }
    }

    return {
      'criteria': criteria,
      'action': {
        if (add.isNotEmpty) 'addLabelIds': add.toSet().toList(),
        if (remove.isNotEmpty) 'removeLabelIds': remove.toSet().toList(),
      },
    };
  }

  /// Gmail's user labels are `Label_<n>`; everything else is a system label.
  /// Only these can be a move or copy target — see `MailRulesRepositoryImpl`.
  static bool isUserLabel(String id) => id.startsWith('Label_');

  /// One value goes back verbatim — it is whatever Gmail stored, or what the
  /// user typed. Several are ORed, with any multi-word value bracketed so
  /// `a b OR c` cannot be read as `a AND (b OR c)`.
  static String _query(List<String> values) {
    final cleaned = _cleaned(values);
    if (cleaned.length == 1) return cleaned.single;
    return cleaned.map((v) => v.contains(' ') ? '($v)' : v).join(' OR ');
  }
}

List<String> _cleaned(List<String> values) =>
    values.map((v) => v.trim()).where((v) => v.isNotEmpty).toList();
