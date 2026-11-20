import 'package:equatable/equatable.dart';

/// A message's importance, as a rule tests it or sets it.
enum MailRuleImportance { low, normal, high }

/// What a condition's value is, which decides how the editor asks for it.
enum MailRuleValueType {
  /// Words or fragments, any one of which matches.
  text,

  /// Whole email addresses, any one of which matches.
  addresses,

  /// Nothing to enter: the condition is simply true or absent.
  flag,

  /// One [MailRuleImportance].
  importance,

  /// A size in kilobytes.
  size,
}

/// What a rule condition tests.
///
/// Named after Graph's `messageRulePredicates`, which is the standard the
/// screen is built to: every kind here is one Graph predicate. Other providers
/// support a subset — see [MailRuleCapabilities] — and a rule holding a
/// predicate this list does not name is read as
/// [MailRule.hasUnsupportedParts] rather than silently thinned.
enum MailRuleConditionKind {
  fromAddresses(MailRuleValueType.addresses),
  senderContains(MailRuleValueType.text),
  sentToAddresses(MailRuleValueType.addresses),
  recipientContains(MailRuleValueType.text),
  subjectContains(MailRuleValueType.text),
  bodyContains(MailRuleValueType.text),
  bodyOrSubjectContains(MailRuleValueType.text),
  headerContains(MailRuleValueType.text),
  hasAttachments(MailRuleValueType.flag),
  importance(MailRuleValueType.importance),
  sentToMe(MailRuleValueType.flag),
  sentOnlyToMe(MailRuleValueType.flag),
  sentCcMe(MailRuleValueType.flag),
  sentToOrCcMe(MailRuleValueType.flag),
  notSentToMe(MailRuleValueType.flag),
  isAutomaticReply(MailRuleValueType.flag),
  isMeetingRequest(MailRuleValueType.flag),
  isMeetingResponse(MailRuleValueType.flag),
  isNonDeliveryReport(MailRuleValueType.flag),
  isReadReceipt(MailRuleValueType.flag),
  isEncrypted(MailRuleValueType.flag),
  isSigned(MailRuleValueType.flag),
  minimumSize(MailRuleValueType.size),
  maximumSize(MailRuleValueType.size);

  const MailRuleConditionKind(this.valueType);
  final MailRuleValueType valueType;
}

/// One test a message has to pass (or, as an exception, must not).
///
/// Only the field matching [MailRuleConditionKind.valueType] means anything.
/// Several [values] are alternatives: Graph ORs the entries of one predicate,
/// and Gmail's criteria are written as `a OR b`.
class MailRuleCondition extends Equatable {
  const MailRuleCondition(
    this.kind, {
    this.values = const [],
    this.importance,
    this.sizeKb,
  });

  final MailRuleConditionKind kind;
  final List<String> values;
  final MailRuleImportance? importance;
  final int? sizeKb;

  /// Whether the condition has what its kind needs to mean anything. A
  /// "subject contains" with no words would match every message on Graph and
  /// is refused outright by Gmail.
  bool get isComplete => switch (kind.valueType) {
    MailRuleValueType.text ||
    MailRuleValueType.addresses => values.any((v) => v.trim().isNotEmpty),
    MailRuleValueType.flag => true,
    MailRuleValueType.importance => importance != null,
    // 0 KB bounds nothing, and Graph reads it back as no bound at all, so
    // the condition would vanish on the next load.
    MailRuleValueType.size => sizeKb != null && sizeKb! > 0,
  };

  @override
  List<Object?> get props => [kind, values, importance, sizeKb];
}

/// What a rule action does. Graph's `messageRuleActions` again, plus the three
/// Gmail filter actions Graph has no counterpart for ([archive], [star],
/// [neverSpam]) — a Gmail filter that skips the inbox is the commonest one
/// there is, and reading it as unsupported would make most of them view-only.
enum MailRuleActionKind {
  moveToFolder(MailRuleActionValueType.folder),
  copyToFolder(MailRuleActionValueType.folder),
  delete(MailRuleActionValueType.none),
  permanentDelete(MailRuleActionValueType.none),
  markAsRead(MailRuleActionValueType.none),
  markImportance(MailRuleActionValueType.importance),
  forwardTo(MailRuleActionValueType.addresses),
  forwardAsAttachmentTo(MailRuleActionValueType.addresses),
  redirectTo(MailRuleActionValueType.addresses),
  stopProcessingRules(MailRuleActionValueType.none),
  archive(MailRuleActionValueType.none),
  star(MailRuleActionValueType.none),
  neverSpam(MailRuleActionValueType.none);

  const MailRuleActionKind(this.valueType);
  final MailRuleActionValueType valueType;
}

enum MailRuleActionValueType { none, folder, importance, addresses }

class MailRuleAction extends Equatable {
  const MailRuleAction(
    this.kind, {
    this.folderId,
    this.importance,
    this.addresses = const [],
  });

  final MailRuleActionKind kind;
  final String? folderId;
  final MailRuleImportance? importance;
  final List<String> addresses;

  bool get isComplete => switch (kind.valueType) {
    MailRuleActionValueType.none => true,
    MailRuleActionValueType.folder => folderId != null && folderId!.isNotEmpty,
    MailRuleActionValueType.importance => importance != null,
    MailRuleActionValueType.addresses =>
      addresses.any((a) => a.trim().isNotEmpty),
  };

  @override
  List<Object?> get props => [kind, folderId, importance, addresses];
}

/// One server-side mail rule: Graph's inbox `messageRule`, or a Gmail filter.
///
/// Like an out-of-office reply this is a *server* setting — it runs however
/// the user reads their mail, and nothing about it is cached by the app.
class MailRule extends Equatable {
  const MailRule({
    this.id,
    this.name = '',
    this.enabled = true,
    this.sequence = 0,
    this.conditions = const [],
    this.exceptions = const [],
    this.actions = const [],
    this.hasError = false,
    this.isReadOnly = false,
    this.hasUnsupportedParts = false,
  });

  /// The provider's id; null for a rule not yet saved.
  final String? id;

  /// Graph's `displayName`. Gmail filters have no name, so there it is empty
  /// and the screen describes the rule from its conditions instead.
  final String name;

  /// Gmail filters cannot be switched off, so they are always enabled.
  final bool enabled;

  /// Graph's run order, lowest first. Gmail filters all run, unordered.
  final int sequence;

  final List<MailRuleCondition> conditions;
  final List<MailRuleCondition> exceptions;
  final List<MailRuleAction> actions;

  /// Graph marks a rule it can no longer run — typically one whose target
  /// folder has been deleted.
  final bool hasError;

  /// Graph's `isReadOnly`: a rule the API may not change, such as one Outlook
  /// keeps client-side.
  final bool isReadOnly;

  /// The rule holds a condition or action this screen cannot represent.
  ///
  /// Saving it from the form would rewrite it without that part — Graph
  /// replaces `conditions`/`actions` whole rather than merging, and a Gmail
  /// edit is a delete and re-create — so such a rule opens view-only. Turning
  /// it on or off, reordering and deleting it still work: none of them send
  /// the conditions.
  final bool hasUnsupportedParts;

  /// Whether the form may rewrite this rule.
  bool get isEditable => !isReadOnly && !hasUnsupportedParts;

  MailRule copyWith({
    String? name,
    bool? enabled,
    int? sequence,
    List<MailRuleCondition>? conditions,
    List<MailRuleCondition>? exceptions,
    List<MailRuleAction>? actions,
  }) {
    return MailRule(
      id: id,
      name: name ?? this.name,
      enabled: enabled ?? this.enabled,
      sequence: sequence ?? this.sequence,
      conditions: conditions ?? this.conditions,
      exceptions: exceptions ?? this.exceptions,
      actions: actions ?? this.actions,
      hasError: hasError,
      isReadOnly: isReadOnly,
      hasUnsupportedParts: hasUnsupportedParts,
    );
  }

  @override
  List<Object?> get props => [
    id,
    name,
    enabled,
    sequence,
    conditions,
    exceptions,
    actions,
    hasError,
    isReadOnly,
    hasUnsupportedParts,
  ];
}

/// What one provider's rules can express. The screen offers exactly these,
/// rather than branching on the account type — Graph is the full set, Gmail a
/// subset with a few actions of its own.
class MailRuleCapabilities extends Equatable {
  const MailRuleCapabilities({
    required this.conditions,
    required this.exceptions,
    required this.actions,
    required this.markImportanceValues,
    required this.namedRules,
    required this.canDisable,
    required this.ordered,
    this.runsOnServer = true,
  });

  final Set<MailRuleConditionKind> conditions;
  final Set<MailRuleConditionKind> exceptions;
  final Set<MailRuleActionKind> actions;

  /// The importances [MailRuleActionKind.markImportance] can set. Gmail has
  /// "always" and "never" mark as important, and nothing in between.
  final Set<MailRuleImportance> markImportanceValues;

  /// Rules carry a name of their own (Graph), rather than being described by
  /// their conditions (Gmail).
  final bool namedRules;

  /// A rule can be switched off without deleting it.
  final bool canDisable;

  /// Rules run in a user-chosen order, and stop-processing means something.
  final bool ordered;

  /// The provider runs the rules. False for IMAP, whose rules NightMail
  /// stores and runs itself — they need no permission and no network to
  /// edit, and they only act while the app is running.
  final bool runsOnServer;

  /// Graph's `messageRule`, which Nightware implements as well.
  static const graph = MailRuleCapabilities(
    conditions: {...MailRuleConditionKind.values},
    exceptions: {...MailRuleConditionKind.values},
    actions: {
      MailRuleActionKind.moveToFolder,
      MailRuleActionKind.copyToFolder,
      MailRuleActionKind.delete,
      MailRuleActionKind.permanentDelete,
      MailRuleActionKind.markAsRead,
      MailRuleActionKind.markImportance,
      MailRuleActionKind.forwardTo,
      MailRuleActionKind.forwardAsAttachmentTo,
      MailRuleActionKind.redirectTo,
      MailRuleActionKind.stopProcessingRules,
    },
    markImportanceValues: {...MailRuleImportance.values},
    namedRules: true,
    canDisable: true,
    ordered: true,
  );

  /// Gmail's filters. Forwarding is left out: Gmail only forwards to an
  /// address already verified under Settings > Forwarding, and a filter
  /// naming any other is refused — that verification flow is not built here.
  static const gmail = MailRuleCapabilities(
    conditions: {
      MailRuleConditionKind.senderContains,
      MailRuleConditionKind.recipientContains,
      MailRuleConditionKind.subjectContains,
      MailRuleConditionKind.bodyOrSubjectContains,
      MailRuleConditionKind.hasAttachments,
    },
    exceptions: {MailRuleConditionKind.bodyOrSubjectContains},
    actions: {
      MailRuleActionKind.moveToFolder,
      MailRuleActionKind.copyToFolder,
      MailRuleActionKind.archive,
      MailRuleActionKind.delete,
      MailRuleActionKind.markAsRead,
      MailRuleActionKind.star,
      MailRuleActionKind.markImportance,
      MailRuleActionKind.neverSpam,
    },
    markImportanceValues: {MailRuleImportance.high, MailRuleImportance.low},
    namedRules: false,
    canDisable: false,
    ordered: false,
  );

  /// IMAP: rules NightMail runs itself on new Inbox mail
  /// (`LocalMailRuleRunner`). Only what can be tested from a message's
  /// envelope and body, and done with plain IMAP commands — IMAP has no
  /// importance, categories or redirect. [MailRuleActionKind.star] is the
  /// `\Flagged` flag here.
  static const local = MailRuleCapabilities(
    conditions: _localConditions,
    exceptions: _localConditions,
    actions: {
      MailRuleActionKind.moveToFolder,
      MailRuleActionKind.copyToFolder,
      MailRuleActionKind.delete,
      MailRuleActionKind.markAsRead,
      MailRuleActionKind.star,
      MailRuleActionKind.forwardTo,
      MailRuleActionKind.stopProcessingRules,
    },
    markImportanceValues: {},
    namedRules: true,
    canDisable: true,
    ordered: true,
    runsOnServer: false,
  );

  static const _localConditions = {
    MailRuleConditionKind.fromAddresses,
    MailRuleConditionKind.senderContains,
    MailRuleConditionKind.sentToAddresses,
    MailRuleConditionKind.recipientContains,
    MailRuleConditionKind.subjectContains,
    MailRuleConditionKind.bodyContains,
    MailRuleConditionKind.bodyOrSubjectContains,
    MailRuleConditionKind.hasAttachments,
    MailRuleConditionKind.sentToMe,
    MailRuleConditionKind.sentOnlyToMe,
    MailRuleConditionKind.sentCcMe,
    MailRuleConditionKind.sentToOrCcMe,
    MailRuleConditionKind.notSentToMe,
  };

  @override
  List<Object?> get props => [
    conditions,
    exceptions,
    actions,
    markImportanceValues,
    namedRules,
    canDisable,
    ordered,
    runsOnServer,
  ];
}

/// One mailbox's rules and what its provider lets them say.
class MailRuleSet extends Equatable {
  const MailRuleSet({required this.rules, required this.capabilities});

  /// In run order where the provider has one.
  final List<MailRule> rules;
  final MailRuleCapabilities capabilities;

  @override
  List<Object?> get props => [rules, capabilities];
}
