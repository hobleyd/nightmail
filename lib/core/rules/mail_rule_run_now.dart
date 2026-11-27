import '../../domain/entities/email.dart';
import '../../domain/entities/mail_rule.dart';
import 'mail_rule_matcher.dart';

/// What running a rule over a folder's messages comes to: which messages it
/// matched and what to do to them.
class MailRuleRunPlan {
  const MailRuleRunPlan({
    this.matchedIds = const [],
    this.moveToFolderId,
    this.delete = false,
    this.markReadIds = const [],
  });

  final List<String> matchedIds;

  /// Null when the rule does not move, or moves into the folder being run.
  final String? moveToFolderId;

  final bool delete;

  /// The matched messages that are still unread.
  final List<String> markReadIds;

  bool get isEmpty =>
      matchedIds.isEmpty ||
      (moveToFolderId == null && !delete && markReadIds.isEmpty);
}

/// Runs a rule over the mail already in a folder — the rule editor's "Run on
/// [folder] now" for a new rule, and the run button on a Settings > Rules row
/// for one already saved. No provider runs a rule on demand
/// (Graph has no such call, and Gmail's "apply to matching conversations" is
/// its own client doing a search and a relabel), so the app decides which
/// messages match, with the same [MailRuleMatcher] its IMAP rules use, and
/// acts through the mail list. See `docs/claude/mail-rules.md`.
///
/// Only what can be decided and done faithfully is offered: a test the
/// matcher cannot evaluate answers false, which as an *exception* would make
/// the rule act on more mail than it says.
class MailRuleRunNow {
  const MailRuleRunNow._();

  /// The actions the mail list has a path for. Forwarding is left out on
  /// purpose: it would send old mail on to other people.
  static const actions = {
    MailRuleActionKind.moveToFolder,
    MailRuleActionKind.delete,
    MailRuleActionKind.markAsRead,
    MailRuleActionKind.stopProcessingRules,
  };

  /// What the matcher can test from a list row. The body is not on a list
  /// row, and reading every message in full is a quota cost on Gmail.
  static final conditions = {
    for (final k in MailRuleCapabilities.local.conditions)
      if (k != MailRuleConditionKind.bodyContains &&
          k != MailRuleConditionKind.bodyOrSubjectContains)
        k,
  };

  /// Why [rule] cannot be run over existing mail, or null when it can.
  /// [google] for a Gmail account, whose rows say less.
  static String? unavailableReason(MailRule rule, {bool google = false}) {
    final noun = google ? 'filter' : 'rule';
    // What the entity does not model is not in [rule] at all — a lost
    // condition or exception would make the run act on more mail than the
    // rule does on the server.
    if (rule.hasUnsupportedParts) {
      return 'This $noun uses settings NightMail cannot show, so it runs on '
          'new mail only.';
    }
    final kinds = [...rule.conditions, ...rule.exceptions].map((c) => c.kind);
    final actionKinds = rule.actions.map((a) => a.kind);
    if (actionKinds.any(
      (k) =>
          k == MailRuleActionKind.forwardTo ||
          k == MailRuleActionKind.forwardAsAttachmentTo ||
          k == MailRuleActionKind.redirectTo,
    )) {
      return 'A $noun that forwards runs on new mail only — run now, it '
          'would send old mail on to other people.';
    }
    if (kinds.any(
      (k) =>
          k == MailRuleConditionKind.bodyContains ||
          k == MailRuleConditionKind.bodyOrSubjectContains,
    )) {
      return 'A $noun that looks at the message text runs on new mail only.';
    }
    // Gmail lists with format=metadata, which carries no MIME parts, so its
    // rows never say they have attachments; the test would match nothing.
    if (!kinds.every(conditions.contains) ||
        (google && kinds.contains(MailRuleConditionKind.hasAttachments))) {
      return 'This $noun tests something NightMail cannot check itself, so '
          'it runs on new mail only.';
    }
    if (!actionKinds.every(actions.contains)) {
      return 'Only moving, deleting and marking read can be run on mail '
          'already received.';
    }
    if (!actionKinds.any((k) => k != MailRuleActionKind.stopProcessingRules)) {
      return 'This $noun does nothing to run.';
    }
    return null;
  }

  /// Which of [emails] [rule] matches and what to do to them. Only messages
  /// that are themselves in [folderId] are considered: the list also shows a
  /// thread's copies from other folders (Sent above all), and a rule run on
  /// this folder must not move those.
  static MailRuleRunPlan plan(
    MailRule rule,
    Iterable<Email> emails, {
    required String folderId,
    required MailRuleMatcher matcher,
    bool google = false,
  }) {
    if (unavailableReason(rule, google: google) != null) {
      return const MailRuleRunPlan();
    }
    final enabled = rule.copyWith(enabled: true);
    final seen = <String>{};
    final matched = [
      for (final e in emails)
        if (e.isMovableFrom(folderId) &&
            seen.add(e.id) &&
            matcher.matches(enabled, e))
          e,
    ];
    // The first move or delete the rule names wins, as when it runs on new
    // mail (LocalMailRuleRunner): both take the message out of the folder.
    MailRuleAction? removal;
    for (final a in rule.actions) {
      if (a.kind == MailRuleActionKind.moveToFolder ||
          a.kind == MailRuleActionKind.delete) {
        removal = a;
        break;
      }
    }
    final move =
        removal?.kind == MailRuleActionKind.moveToFolder &&
            removal!.folderId != folderId
        ? removal.folderId
        : null;
    final markRead = rule.actions.any(
      (a) => a.kind == MailRuleActionKind.markAsRead,
    );
    return MailRuleRunPlan(
      matchedIds: [for (final e in matched) e.id],
      moveToFolderId: move,
      delete: removal?.kind == MailRuleActionKind.delete,
      markReadIds: [
        if (markRead)
          for (final e in matched)
            if (!e.isRead) e.id,
      ],
    );
  }
}
