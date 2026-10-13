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
  MigrationCubit({required this._migrationService})
      : super(const MigrationState());

  final AccountMigrationService _migrationService;
  Timer? _pollTimer;
  String? _sourceAccountId;
  String? _targetAccountId;
  MigrationScope _scope = MigrationScope.account;

  /// Starts (or resumes) a migration for this account pair and begins
  /// watching its status.
  Future<void> startOrResume(
    String sourceAccountId,
    String targetAccountId, {
    MigrationScope scope = MigrationScope.account,
  }) async {
    watch(sourceAccountId, targetAccountId, scope: scope);
    unawaited(_migrationService.startOrResume(sourceAccountId, targetAccountId,
        scope: scope));
  }

  /// Loads the current status for [sourceAccountId] -> [targetAccountId] and
  /// re-polls it every few seconds until [close] or a different pair is
  /// watched.
  void watch(
    String sourceAccountId,
    String targetAccountId, {
    MigrationScope scope = MigrationScope.account,
  }) {
    _sourceAccountId = sourceAccountId;
    _targetAccountId = targetAccountId;
    _scope = scope;
    emit(const MigrationState(isLoading: true));
    unawaited(_refresh());
    _pollTimer?.cancel();
    _pollTimer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  Future<void> _refresh() async {
    final sourceId = _sourceAccountId;
    final targetId = _targetAccountId;
    final scope = _scope;
    if (sourceId == null || targetId == null || isClosed) return;
    final job =
        await _migrationService.getJob(sourceId, targetId, scope: scope);
    final failures = job == null
        ? const <MigrationLedgerRecord>[]
        : await _migrationService.getFailures(sourceId, targetId,
            scope: scope);
    final progress =
        _migrationService.getProgress(sourceId, targetId, scope: scope);
    // A refresh that was already in flight when a different job started
    // being watched must not report the old job as the new one.
    if (isClosed ||
        sourceId != _sourceAccountId ||
        targetId != _targetAccountId ||
        scope != _scope) {
      return;
    }
    emit(MigrationState(job: job, failures: failures, progress: progress));
  }

  @override
  Future<void> close() {
    _pollTimer?.cancel();
    return super.close();
  }
}
