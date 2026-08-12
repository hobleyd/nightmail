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
  ///
  /// A message may be cached under several folders at once — a folder page
  /// arrives with the same thread's copies from elsewhere, and those belong to
  /// this listing *and* to their own. Writing one never disturbs the others.
  ///
  /// A thin row (empty body) never clobbers a full body already cached for the
  /// same message — see the impl's preservation lookup.
  ///
  /// Pass [replaceFolder] when [emails] is a complete page that should *become*
  /// the folder's contents, so a message removed remotely stops being listed.
  /// The rows are dropped inside the same transaction as the inserts and
  /// *after* the body-preservation lookups — which is why this replaces
  /// [clearCacheForFolder] followed by a plain cacheEmails, a sequence that
  /// silently discarded every cached body in the folder.
  ///
  /// An empty [emails] list is always a no-op, including with [replaceFolder]:
  /// an empty fetch is far more likely transient than a genuinely empty folder.
  Future<void> cacheEmails({
    required String accountId,
    required String folderId,
    required List<Email> emails,
    bool replaceFolder,
  });

  /// Returns the cached email with [emailId] for [accountId], regardless of
  /// which folder it's filed under, or null if it isn't cached. A message
  /// cached under several folders is answered for once, preferring a copy that
  /// carries a body.
  Future<Email?> getCachedEmailById({
    required String accountId,
    required String emailId,
  });

  /// Files every cached message under its own folder as well as the listings it
  /// was seen in, and returns how many rows that added.
  ///
  /// Repairs caches written before a message could be filed under more than one
  /// folder, when caching a folder page *moved* the thread's copies from
  /// elsewhere into it — so a folder could be missing mail that is sitting in
  /// the cache under whichever folder was listed last. The message's own folder
  /// travels inside the encrypted payload, which is where the answer survived.
  ///
  /// Adds only what is missing and never removes anything, so running it twice
  /// is a no-op. A row for a message that has since moved is put back where it
  /// used to be, exactly as stale as the copy already cached — the next network
  /// listing of either folder replaces both.
  Future<int> restoreFolderMemberships({required String accountId});

  /// Upgrades the already-cached rows for [email] to its full copy — body,
  /// inline images and attachment metadata — and does **nothing at all** when
  /// the message is no longer cached. Never inserts, and never moves a row
  /// between folders: a body is a property of the message, so every folder
  /// that lists it gets the upgrade and no folder gains a listing from it.
  ///
  /// This is [cacheEmails] with the insert taken away, and the difference is the
  /// whole point: `BodyPrefetchService` is upgrading a message the user is quite
  /// likely reading right now, and the row can be deleted from under it while
  /// its body is in flight. Deciding "still cached?" in the caller cannot fix
  /// that — the check and the write would be two transactions with the delete
  /// free to commit between them — so the lookup happens inside this one.
  ///
  /// The cached row's `isRead` wins over [email]'s: the row may carry an
  /// optimistic flag from a mark-as-read that has not drained to the server yet,
  /// and a freshly-fetched copy reports the server's stale value.
  Future<void> upgradeCachedEmailBody({
    required String accountId,
    required Email email,
  });

  /// Whether the cached row for [emailId] was written by an older version of
  /// the attachment-parsing code, so its attachment metadata cannot be trusted.
  ///
  /// A row that parsed *no* attachments is indistinguishable from a message
  /// that genuinely has none, so a bad parse cannot be detected by inspecting
  /// the row — it can only be dated. Callers use this to refetch such a row
  /// once; the rewrite carries the current stamp, so it never refetches again.
  /// Returns false when [emailId] isn't cached (nothing to repair).
  Future<bool> hasStaleAttachmentParse({
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
  ///
  /// Pass `evictInlineAttachments: false` when the message has only *moved* —
  /// the row belongs to a different folder now, but the message still exists, so
  /// throwing its cached inline images away only makes the destination folder
  /// download every one of them again. Orphans left this way are swept by
  /// `InlineAttachmentCache.prune` on startup.
  Future<void> deleteEmailFromCache({
    required String accountId,
    required String emailId,
    bool evictInlineAttachments,
  });

  /// Updates the isRead flag on the cached email with [emailId] for [accountId].
  /// No-ops silently when the email is not in the cache.
  Future<void> updateEmailReadStatusInCache({
    required String accountId,
    required String emailId,
    required bool isRead,
  });

  /// Applies a change that names only the fields that moved to the cached row
  /// for [emailId], leaving the rest of it as it was. A null argument means
  /// "unchanged". No-ops silently when the email is not in the cache, and when
  /// every argument is null.
  ///
  /// This is how a partial delta item is applied — writing one through
  /// [cacheEmails] would replace a complete row with a near-empty one.
  Future<void> updateCachedEmailFields({
    required String accountId,
    required String emailId,
    bool? isRead,
    bool? isFlagged,
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
