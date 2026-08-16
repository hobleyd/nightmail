import 'dart:async';

/// Serializes IMAP work for one account **across every caller**.
///
/// `AccountManager.buildEmailDatasourceForAccount` caches one
/// `ImapDatasourceImpl` per account id, and that datasource holds exactly one
/// stateful connection with one selected mailbox. `OutboxDrainService` and
/// `MailPollerCubit`'s poll loop each happen to serialize *themselves*
/// against it, but nothing enforces mutual exclusion *between* those two
/// callers — and a third caller (account migration) racing the same
/// connection is a real wire-level hazard: a fetch landing mid-SELECT from
/// another caller can corrupt the session, not just race a UI concern. This
/// gate is the actual guarantee; the callers' own serialization is not.
///
/// Acquired per *unit* of IMAP work (one message, one queued op), not per
/// job or per poll cycle — holding it for a whole migration would starve
/// normal mail sync for hours. Because a caller never holds two accounts'
/// locks at once (source is fetched, released, *then* the destination is
/// locked and written), there is no lock-ordering/deadlock concern even
/// between two migrations running in opposite directions.
class ImapConnectionGate {
  final Map<String, Future<void>> _tails = {};

  /// Runs [body] as the sole holder of [accountId]'s IMAP connection —
  /// callers for the same [accountId] run strictly in the order they
  /// called this; different accounts never wait on each other.
  Future<T> runExclusive<T>(
    String accountId,
    Future<T> Function() body,
  ) {
    final prior = _tails[accountId] ?? Future.value();
    final result = prior.then((_) => body());
    // The tail swallows the outcome so one caller's failure never wedges the
    // next caller's turn; the real result/error still reaches this method's
    // own caller via [result].
    _tails[accountId] = result.then((_) {}, onError: (_) {});
    return result;
  }
}
