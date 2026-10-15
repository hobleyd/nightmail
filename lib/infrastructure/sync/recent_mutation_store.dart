/// Short-lived record of message ids the user has just mutated optimistically
/// — removed by a delete/move/junk, or marked read/unread — kept for a window
/// that *outlives* the outbox op's drain and dequeue.
///
/// A server fetch issued before the mutation propagated can resolve *after*
/// the outbox drain committed and dequeued the op. Reconciliation keyed only
/// on the pending-ops table would then find no matching op and take the stale
/// snapshot as truth: re-caching a just-removed row, or flipping a just-read
/// message back to unread, until the server list converges on the next poll.
///
/// Both [EmailRepositoryImpl]'s and [MailPollerCubit]'s reconciliation consult
/// this store alongside the pending ops, so the two agree. It matters most for
/// a multi-message action (e.g. deleting a whole conversation thread): the
/// outbox drains those ops one at a time over several seconds, widening the
/// post-dequeue window a poll fetch can land in.
///
/// Read state carries the *value* the user set, not just the id, because the
/// cache row cannot be trusted to hold it: every list fetch reconciles and then
/// encrypts and writes some time later, unordered against the mark-read write,
/// so a fetch that resolved a moment before the click lands its stale `isRead`
/// on top of the user's. `EmailLocalDatasourceImpl` overlays these values on
/// every cache read for the window, which makes the order of those writes
/// irrelevant — see `recentReadStates`.
///
/// Keyed `accountId::emailId` because IMAP UIDs collide across accounts.
class RecentMutationStore {
  RecentMutationStore({
    Duration ttl = const Duration(seconds: 30),
    DateTime Function() now = DateTime.now,
  })  : _removed = _ExpiringEntries<String?>(ttl, now),
        _arrivals = _ExpiringEntries<String>(ttl, now),
        _readStates = _ExpiringEntries<bool>(ttl, now);

  final _ExpiringEntries<String?> _removed;
  final _ExpiringEntries<String> _arrivals;
  final _ExpiringEntries<bool> _readStates;

  /// Records [emailId] as removed from view for [accountId]. Resets the expiry
  /// window if already present.
  ///
  /// [destinationFolderId] is where a *move* took it. The message has left
  /// every folder but that one, and on Gmail it keeps its id there — so a
  /// listing of the destination must not drop it (see `PendingRemovals`).
  void recordRemoval(
    String accountId,
    String emailId, {
    String? destinationFolderId,
  }) =>
      _removed.record(accountId, emailId, destinationFolderId);

  /// Records that [emailId] has just been filed into [folderId] under that id —
  /// the id the server reported for the move (minted on Graph, unchanged on
  /// Gmail). Not a removal: nothing is dropped for it. A
  /// listing of [folderId] from an Exchange replica still behind the move does
  /// not name it yet, and this is what stops that listing's folder-replacing
  /// cache write from taking the re-filed row away.
  void recordArrival(String accountId, String emailId, String folderId) =>
      _arrivals.record(accountId, emailId, folderId);

  /// Records that the user set [emailId]'s read state to [isRead] for
  /// [accountId]. A later change to the same message replaces the value.
  void recordReadChange(String accountId, String emailId,
          {required bool isRead}) =>
      _readStates.record(accountId, emailId, isRead);

  /// The ids still tombstoned as removed for [accountId].
  Set<String> recentlyRemovedIds(String accountId) =>
      _removed.active(accountId).keys.toSet();

  /// The ids still tombstoned for [accountId], each with the folder a move
  /// took it to (null for a delete or junk).
  Map<String, String?> recentRemovals(String accountId) =>
      _removed.active(accountId);

  /// The ids recently filed into a folder by a move, with that folder.
  Map<String, String> recentArrivals(String accountId) =>
      _arrivals.active(accountId);

  /// The read state the user recently set, by id, for [accountId]. Within the
  /// window this is the truth about those messages, whatever a cache row or a
  /// server snapshot says.
  Map<String, bool> recentReadStates(String accountId) =>
      _readStates.active(accountId);
}

class _ExpiringEntries<V> {
  _ExpiringEntries(this._ttl, this._now);

  final Duration _ttl;
  final DateTime Function() _now;
  final Map<String, ({DateTime expiry, V value})> _entries = {};

  void record(String accountId, String emailId, V value) {
    _entries['$accountId::$emailId'] = (expiry: _now().add(_ttl), value: value);
  }

  /// Expired entries are swept on each call, so the map never grows unbounded.
  Map<String, V> active(String accountId) {
    final now = _now();
    _entries.removeWhere((_, entry) => !entry.expiry.isAfter(now));
    final prefix = '$accountId::';
    return {
      for (final entry in _entries.entries)
        if (entry.key.startsWith(prefix))
          entry.key.substring(prefix.length): entry.value.value,
    };
  }
}
