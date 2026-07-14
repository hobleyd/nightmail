import '../../../domain/entities/email.dart';

abstract interface class EmailLocalDatasource {
  /// Returns cached emails for [accountId]/[folderId], ordered by
  /// receivedDateTime descending. Returns an empty list when no cache exists.
  Future<List<Email>> getCachedEmails({
    required String accountId,
    required String folderId,
  });

  /// Upserts the given [emails] into the cache for [accountId]/[folderId].
  /// Call this after a successful network fetch so that future offline
  /// launches can display the emails without a network connection.
  Future<void> cacheEmails({
    required String accountId,
    required String folderId,
    required List<Email> emails,
  });

  /// Returns the cached email with [emailId] for [accountId], regardless of
  /// which folder it's filed under, or null if it isn't cached.
  Future<Email?> getCachedEmailById({
    required String accountId,
    required String emailId,
  });

  /// Deletes all cached emails belonging to [accountId].
  /// Call when an account is removed so no stale data lingers on disk.
  Future<void> clearCacheForAccount(String accountId);

  /// Deletes all cached emails for [accountId]/[folderId].
  /// Call before writing a fresh first-page network response so removed
  /// emails do not linger in the cache.
  Future<void> clearCacheForFolder({
    required String accountId,
    required String folderId,
  });

  /// Deletes the cached email with [emailId] for [accountId].
  Future<void> deleteEmailFromCache({
    required String accountId,
    required String emailId,
  });

  /// Updates the isRead flag on the cached email with [emailId] for [accountId].
  /// No-ops silently when the email is not in the cache.
  Future<void> updateEmailReadStatusInCache({
    required String accountId,
    required String emailId,
    required bool isRead,
  });

  /// Renames the cached row for [oldEmailId] to [newEmailId] and re-files it
  /// under [newFolderId] — called by the outbox drain engine once the server
  /// confirms a move/junk assigned the message a new id. No-ops silently when
  /// [oldEmailId] isn't cached. If a row already exists at [newEmailId] (e.g.
  /// a delta sync already landed it), that row is replaced by the rename
  /// rather than left to collide with it.
  Future<void> renameCachedEmailId({
    required String accountId,
    required String oldEmailId,
    required String newEmailId,
    required String newFolderId,
  });
}
