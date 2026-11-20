import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/email_folder.dart';
import '../entities/mail_rule.dart';

/// Reads and writes one account's server-side mail rules.
///
/// Account-scoped for the reason [OutOfOfficeRepository] is: the Rules screen
/// edits whichever mailbox the user picked from its own list, and a rule
/// written to the wrong mailbox moves or deletes somebody else's mail.
///
/// An account whose provider has no server-side rules (IMAP) answers
/// [UnsupportedFailure], which the screen reports as "not available" rather
/// than as something that went wrong.
abstract interface class MailRulesRepository {
  Future<Either<Failure, MailRuleSet>> getMailRules(String accountId);

  /// The folders (Gmail: labels) a rule can move or copy into. Read from the
  /// local folder cache, which holds the whole tree once the account has been
  /// opened, so the screen does not cost a folder walk on every visit.
  Future<Either<Failure, List<EmailFolder>>> getMailRuleFolders(
    String accountId,
  );

  /// Creates [rule] when it has no id, otherwise replaces it.
  Future<Either<Failure, Unit>> saveMailRule(String accountId, MailRule rule);

  Future<Either<Failure, Unit>> deleteMailRule(String accountId, String ruleId);

  Future<Either<Failure, Unit>> setMailRuleEnabled(
    String accountId,
    String ruleId,
    bool enabled,
  );

  /// Gives each rule in [sequences] its new run position, lowest first.
  /// Only the rules that move are named: a read-only rule cannot be PATCHed
  /// at all, so renumbering the whole list fails in any mailbox holding one.
  Future<Either<Failure, Unit>> reorderMailRules(
    String accountId,
    Map<String, int> sequences,
  );
}
