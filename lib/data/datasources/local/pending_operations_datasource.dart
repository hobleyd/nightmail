/// The mutation types that can be queued for offline/async replay against
/// the server. Matches the mutating methods on the email repository, plus
/// [spamDbPush] (see SpamDbSyncService), which isn't an email mutation but
/// shares the same drain engine so it can never overlap another queued
/// operation's use of the same IMAP connection.
enum PendingOperationType { delete, move, markRead, junk, emptyFolder, spamDbPush }

class PendingOperationRecord {
  const PendingOperationRecord({
    required this.id,
    required this.accountId,
    required this.emailId,
    required this.folderId,
    required this.opType,
    required this.payload,
    required this.createdAtMs,
    required this.retryCount,
    required this.lastError,
  });

  final int id;
  final String accountId;

  /// The email this op targets. Rewritten in place if an earlier queued op
  /// for the same message moves it and the server assigns it a new id —
  /// see the outbox drain engine.
  final String emailId;

  /// The folder the op applies to (used by emptyFolder; null otherwise).
  final String? folderId;
  final PendingOperationType opType;

  /// Op-specific parameters as a JSON string (e.g. {"destinationFolderId": ..}
  /// for move, {"isRead": true} for markRead, {"permanentDelete": false} for
  /// emptyFolder). Empty object for ops that need no extra data (delete, junk).
  final String payload;
  final int createdAtMs;
  final int retryCount;
  final String? lastError;
}

/// Durable queue of mutations awaiting a server round-trip. Lets a mutation
/// apply to the cache and appear in the UI immediately — even offline — with
/// the actual server call replayed later by the outbox drain engine.
abstract interface class PendingOperationsDatasource {
  /// Adds a new queued operation and returns its id.
  Future<int> enqueue({
    required String accountId,
    required String emailId,
    String? folderId,
    required PendingOperationType opType,
    required String payload,
  });

  /// All queued operations for [accountId], oldest first. Draining must
  /// process operations for the same [PendingOperationRecord.emailId] in
  /// this order so that an id remap from an earlier op (e.g. a move) is
  /// applied before a later op for the same message is sent.
  Future<List<PendingOperationRecord>> getPendingOperations(String accountId);

  /// Rewrites [oldEmailId] to [newEmailId] on every still-queued operation
  /// for [accountId] — called after a move/delete confirms the server
  /// assigned the message a new id, so operations queued behind it target
  /// the right message once they drain.
  Future<void> remapEmailId({
    required String accountId,
    required String oldEmailId,
    required String newEmailId,
  });

  /// Removes an operation once it has been successfully replayed.
  Future<void> removeOperation(int id);

  /// Records a failed replay attempt so the drain engine can back off and
  /// eventually surface persistently-failing operations to the user.
  Future<void> recordFailure({required int id, required String error});
}
