enum MigrationJobStatus { running, paused, completed, failed }

/// A ledger row's lifecycle: pending -> inProgress -> written -> done (or ->
/// failed at any point after inProgress). `written` is a distinct step from
/// `done` so a crash between the destination provider call succeeding and
/// the ledger update committing is detectable on resume — the row already
/// carries [MigrationLedgerRecord.destMessageId] at that point, it just
/// hasn't been marked `done` yet.
enum MigrationMessageStatus { pending, inProgress, written, done, failed }

class MigrationJobRecord {
  const MigrationJobRecord({
    required this.id,
    required this.sourceAccountId,
    required this.targetAccountId,
    required this.status,
    required this.createdAtMs,
    required this.updatedAtMs,
    required this.lastError,
  });

  final String id;
  final String sourceAccountId;
  final String targetAccountId;
  final MigrationJobStatus status;
  final int createdAtMs;
  final int updatedAtMs;
  final String? lastError;
}

class MigrationLedgerRecord {
  const MigrationLedgerRecord({
    required this.id,
    required this.jobId,
    required this.sourceFolderId,
    required this.sourceMessageId,
    required this.status,
    required this.destFolderId,
    required this.destMessageId,
    required this.retryCount,
    required this.lastError,
    required this.updatedAtMs,
  });

  final int id;
  final String jobId;
  final String sourceFolderId;
  final String sourceMessageId;
  final MigrationMessageStatus status;
  final String? destFolderId;
  final String? destMessageId;
  final int retryCount;
  final String? lastError;
  final int updatedAtMs;
}

/// Durable state for `AccountMigrationService`: one job row per (source,
/// target) account pair, and a per-message ledger that is both the
/// resumability checkpoint and the guard against copying the same source
/// message twice.
abstract interface class MigrationLocalDatasource {
  /// Creates [jobId] if it doesn't exist yet, or updates its status if it
  /// does — one row per pair, upserted, never appended. Re-running a
  /// completed job just catches up new source mail and retries prior
  /// failures against the same row and ledger.
  Future<MigrationJobRecord> upsertJob({
    required String jobId,
    required String sourceAccountId,
    required String targetAccountId,
    required MigrationJobStatus status,
  });

  Future<MigrationJobRecord?> getJob(String jobId);

  /// Every job left `running` or `paused` — resumed on app start.
  Future<List<MigrationJobRecord>> getResumableJobs();

  Future<void> setJobStatus({
    required String jobId,
    required MigrationJobStatus status,
    String? lastError,
  });

  /// [matchSourceFolderId] must be false for a Gmail source: a message there
  /// can carry more than one label, so enumerating folder-by-folder would
  /// otherwise see (and re-copy) the same message once per folder it
  /// belongs to. Passing false checks `(jobId, sourceMessageId)` only,
  /// regardless of which folder it was first ledgered under — first folder
  /// processed wins, and the caller must skip entirely on a hit rather than
  /// ledger a second row for the same message under a different folder.
  Future<MigrationLedgerRecord?> findLedgerRow({
    required String jobId,
    required String sourceFolderId,
    required String sourceMessageId,
    required bool matchSourceFolderId,
  });

  /// Inserts or updates the ledger row for one message. `retryCount`
  /// increments only when [incrementRetry] is true (a failed attempt) —
  /// every other transition leaves it as-is. Omitted [destFolderId]/
  /// [destMessageId] leave whatever the row already has, so marking a row
  /// `done` after an earlier `written` call doesn't need to repeat them.
  Future<void> upsertLedgerRow({
    required String jobId,
    required String sourceFolderId,
    required String sourceMessageId,
    required MigrationMessageStatus status,
    String? destFolderId,
    String? destMessageId,
    String? lastError,
    bool incrementRetry = false,
  });

  /// Permanently-failed rows for [jobId] — the migration status UI's
  /// failure list.
  Future<List<MigrationLedgerRecord>> getFailedRows(String jobId);
}
