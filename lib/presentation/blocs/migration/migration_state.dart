import 'package:equatable/equatable.dart';

import '../../../data/datasources/local/migration_local_datasource.dart';
import '../../../infrastructure/migration/account_migration_service.dart';
import '../../../infrastructure/migration/mail_rule_migrator.dart';

class MigrationState extends Equatable {
  const MigrationState({
    this.job,
    this.failures = const [],
    this.progress,
    this.isLoading = false,
    this.ruleResult,
    this.copyingRules = false,
    this.targetRunsLocalRules = false,
  });

  final MigrationJobRecord? job;
  final List<MigrationLedgerRecord> failures;
  final MigrationProgress? progress;
  final bool isLoading;

  /// What copying the source's rules came to; null until it has run.
  final RuleMigrationResult? ruleResult;

  /// The dialog's rules retry is in flight.
  final bool copyingRules;

  /// The target is IMAP, whose rules NightMail runs — paused while this
  /// migration fills its Inbox.
  final bool targetRunsLocalRules;

  @override
  List<Object?> get props => [
        job?.id,
        job?.status,
        job?.updatedAtMs,
        job?.lastError,
        failures.length,
        progress,
        isLoading,
        ruleResult?.status,
        ruleResult?.copied,
        ruleResult?.alreadyThere,
        ruleResult?.skipped.length,
        ruleResult?.message,
        ruleResult?.sourceRules,
        ruleResult?.sourceRulesMessage,
        copyingRules,
        targetRunsLocalRules,
      ];
}
