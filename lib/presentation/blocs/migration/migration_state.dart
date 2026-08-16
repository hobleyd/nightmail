import 'package:equatable/equatable.dart';

import '../../../data/datasources/local/migration_local_datasource.dart';
import '../../../infrastructure/migration/account_migration_service.dart';

class MigrationState extends Equatable {
  const MigrationState({
    this.job,
    this.failures = const [],
    this.progress,
    this.isLoading = false,
  });

  final MigrationJobRecord? job;
  final List<MigrationLedgerRecord> failures;
  final MigrationProgress? progress;
  final bool isLoading;

  @override
  List<Object?> get props => [
        job?.id,
        job?.status,
        job?.updatedAtMs,
        job?.lastError,
        failures.length,
        progress,
        isLoading,
      ];
}
