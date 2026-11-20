import '../../domain/entities/email.dart';
import '../../domain/entities/mail_rule.dart';
import '../utils/latest_reply.dart' show htmlToPlainText;

/// Decides which of NightMail's own (IMAP) rules a message triggers.
///
/// Graph's semantics, since the rules are written to Graph's model: every
/// condition must hold, the values within one condition are alternatives,
/// any exception that holds cancels the rule, and text tests are
/// case-insensitive substring matches. Pure, so it is tested without a
/// mailbox; `LocalMailRuleRunner` does the IMAP half.
class MailRuleMatcher {
  MailRuleMatcher({required Iterable<String> myAddresses})
    : _me = myAddresses.map((a) => a.trim().toLowerCase()).toSet();

  /// The account's own address and aliases, for the "sent to me" tests.
  final Set<String> _me;

  /// Whether any of [rules]' conditions or exceptions look at the body, which
  /// a list fetch does not carry — the runner reads the message only then.
  static bool needsBody(Iterable<MailRule> rules) => rules.any(
    (r) => [...r.conditions, ...r.exceptions].any(
      (c) =>
          c.kind == MailRuleConditionKind.bodyContains ||
          c.kind == MailRuleConditionKind.bodyOrSubjectContains,
    ),
  );

  bool matches(MailRule rule, Email email) {
    if (!rule.enabled || rule.conditions.isEmpty) return false;
    final text = _MessageText(email);
    return rule.conditions.every((c) => _holds(c, email, text)) &&
        !rule.exceptions.any((c) => _holds(c, email, text));
  }

  bool _holds(MailRuleCondition c, Email email, _MessageText text) {
    final values = [
      for (final v in c.values)
        if (v.trim().isNotEmpty) v.trim().toLowerCase(),
    ];
    bool anyIn(String haystack) => values.any(haystack.contains);
    final to = [for (final r in email.toRecipients) r.address.toLowerCase()];
    final cc = [for (final r in email.ccRecipients) r.address.toLowerCase()];
    bool mine(Iterable<String> addresses) => addresses.any(_me.contains);

    return switch (c.kind) {
      MailRuleConditionKind.fromAddresses => values.contains(
        email.from.address.toLowerCase(),
      ),
      MailRuleConditionKind.senderContains => anyIn(
        '${email.from.name ?? ''} <${email.from.address}>'.toLowerCase(),
      ),
      MailRuleConditionKind.sentToAddresses => [
        ...to,
        ...cc,
      ].any(values.contains),
      MailRuleConditionKind.recipientContains => anyIn(text.recipients),
      MailRuleConditionKind.subjectContains => anyIn(text.subject),
      MailRuleConditionKind.bodyContains => anyIn(text.body),
      MailRuleConditionKind.bodyOrSubjectContains =>
        anyIn(text.subject) || anyIn(text.body),
      MailRuleConditionKind.hasAttachments => email.hasAttachments,
      MailRuleConditionKind.sentToMe => mine(to),
      MailRuleConditionKind.sentOnlyToMe =>
        to.length == 1 && mine(to) && cc.isEmpty,
      MailRuleConditionKind.sentCcMe => mine(cc),
      MailRuleConditionKind.sentToOrCcMe => mine(to) || mine(cc),
      MailRuleConditionKind.notSentToMe => !mine(to),
      // Outside MailRuleCapabilities.local: a stored rule naming one (edited
      // by hand, or by a later version) must not fire on everything.
      _ => false,
    };
  }
}

/// The lower-cased text the tests search, worked out once per message.
class _MessageText {
  _MessageText(Email email)
    : subject = email.subject.toLowerCase(),
      recipients = [
        for (final r in [...email.toRecipients, ...email.ccRecipients])
          '${r.name ?? ''} <${r.address}>',
      ].join(', ').toLowerCase(),
      _email = email;

  final Email _email;
  final String subject;
  final String recipients;

  /// The rendered text rather than raw HTML, so "price" does not match
  /// `class="price-table"`.
  late final String body =
      (_email.bodyType == EmailBodyType.html
              ? htmlToPlainText(_email.body)
              : _email.body)
          .toLowerCase();
}
