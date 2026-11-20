import '../../../domain/entities/mail_rule.dart';

/// Reads and writes a mailbox's server-side mail rules.
///
/// A narrow interface of its own for the reason [OutOfOfficeDatasource] is:
/// IMAP has no rules API this app speaks (ManageSieve would be the route), and
/// putting these on the shared interface would force `ImapDatasourceImpl` to
/// stub methods it can never honour. The repository tests for it with `is`
/// and answers `UnsupportedFailure` when it is absent.
///
/// Implemented by `GraphApiDatasourceImpl` (Graph and Nightware) and
/// `GmailDatasourceImpl`. The wire mapping lives in `mail_rule_codecs.dart`.
abstract interface class MailRulesDatasource {
  MailRuleCapabilities get mailRuleCapabilities;

  /// Every rule, in run order where the provider has one.
  Future<List<MailRule>> getMailRules();

  Future<void> createMailRule(MailRule rule);

  /// Replaces the rule with [rule]'s id. Gmail filters cannot be updated, so
  /// there this creates the new filter and then deletes the old one — in that
  /// order, so a failed edit leaves the original in place.
  Future<void> updateMailRule(MailRule rule);

  Future<void> deleteMailRule(String id);

  /// Only where [MailRuleCapabilities.canDisable].
  Future<void> setMailRuleEnabled(String id, bool enabled);

  /// Sets each named rule's sequence. Only where
  /// [MailRuleCapabilities.ordered].
  Future<void> reorderMailRules(Map<String, int> sequences);
}
