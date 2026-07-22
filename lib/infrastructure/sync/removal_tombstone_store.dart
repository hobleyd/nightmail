/// Short-lived record of message ids optimistically removed by a
/// delete/move/junk mutation, kept for a window that *outlives* the outbox
/// op's drain and dequeue.
///
/// A server fetch issued before the mutation propagated can resolve *after*
/// the outbox drain committed and dequeued the op. Reconciliation keyed only
/// on the pending-ops table would then find no matching op, keep the stale
/// row, and re-cache it — repainting a just-removed message until the server
/// list converges.
///
/// Both [EmailRepositoryImpl]'s and [MailPollerCubit]'s reconciliation consult
/// this store alongside the pending ops, so the two agree. It matters most for
/// a multi-message action (e.g. deleting a whole conversation thread): the
/// outbox drains those ops one at a time over several seconds, widening the
/// post-dequeue window a poll fetch can land in.
///
/// Keyed `accountId::emailId` because IMAP UIDs collide across accounts.
class RemovalTombstoneStore {
  RemovalTombstoneStore({
    Duration ttl = const Duration(seconds: 30),
    DateTime Function() now = DateTime.now,
  })  : _ttl = ttl,
        _now = now;

  final Duration _ttl;
  final DateTime Function() _now;
  final Map<String, DateTime> _expiries = {};

  /// Records [emailId] as removed for [accountId]. Resets the expiry window if
  /// already present.
  void record(String accountId, String emailId) {
    _expiries['$accountId::$emailId'] = _now().add(_ttl);
  }

  /// The ids still tombstoned for [accountId]. Expired entries are swept on
  /// each call, so the map never grows unbounded.
  Set<String> activeIds(String accountId) {
    final now = _now();
    _expiries.removeWhere((_, expiry) => !expiry.isAfter(now));
    final prefix = '$accountId::';
    return {
      for (final key in _expiries.keys)
        if (key.startsWith(prefix)) key.substring(prefix.length),
    };
  }
}
