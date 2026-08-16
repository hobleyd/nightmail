import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../data/datasources/local/migration_local_datasource.dart';
import '../../../infrastructure/migration/account_migration_service.dart';
import 'migration_state.dart';

/// Thin presentation-layer wrapper over [AccountMigrationService] — starts/
/// resumes a job and polls its status while the migration status dialog has
/// one being watched. A job can run for hours, so the dialog needs to see it
/// move without the user having to reopen it; nothing is polled before
/// [watch] is called.
class MigrationCubit extends Cubit<MigrationState> {
  MigrationCubit({required AccountMigrationService migrationService})
      : _migrationService = migrationService,
        super(const MigrationState());

  final AccountMigrationService _migrationService;
  Timer? _pollTimer;
  String? _sourceAccountId;
  String? _targetAccountId;

  /// Starts (or resumes) a migration for this account pair and begins
  /// watching its status.
  Future<void> startOrResume(
      String sourceAccountId, String targetAccountId) async {
    watch(sourceAccountId, targetAccountId);
    unawaited(
        _migrationService.startOrResume(sourceAccountId, targetAccountId));
  }

  /// Loads the current status for [sourceAccountId] -> [targetAccountId] and
  /// re-polls it every few seconds until [close] or a different pair is
  /// watched.
  void watch(String sourceAccountId, String targetAccountId) {
    _sourceAccountId = sourceAccountId;
    _targetAccountId = targetAccountId;
    emit(const MigrationState(isLoading: true));
    unawaited(_refresh());
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final sourceId = _sourceAccountId;
    final targetId = _targetAccountId;
    if (sourceId == null || targetId == null || isClosed) return;
    final job = await _migrationService.getJob(sourceId, targetId);
    final failures = job == null
        ? const <MigrationLedgerRecord>[]
        : await _migrationService.getFailures(sourceId, targetId);
    final progress = _migrationService.getProgress(sourceId, targetId);
    if (isClosed) return;
    emit(MigrationState(job: job, failures: failures, progress: progress));
  }

  @override
  Future<void> close() {
    _pollTimer?.cancel();
    return super.close();
  }
}
