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

  /// Deletes all cached emails belonging to [accountId].
  /// Call when an account is removed so no stale data lingers on disk.
  Future<void> clearCacheForAccount(String accountId);

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
}
