import 'dart:async';

/// Tells whoever is showing a commitments ledger that it changed behind
/// their back — a message tracked by hand from the reading pane, say, while
/// the Commitments pane is open on the same account.
///
/// One per process (`sl<CommitmentLedgerChanges>()`). Events carry the
/// account id; a listener compares it with the ledger it shows and re-reads.
/// The pane's own writes do not go through here — it already knows about
/// them — so a scan's many row updates never trigger a cascade of reloads.
class CommitmentLedgerChanges {
  final _controller = StreamController<String>.broadcast();

  /// Account ids whose ledger was changed outside the pane.
  Stream<String> get stream => _controller.stream;

  void notify(String accountId) {
    if (!_controller.isClosed) _controller.add(accountId);
  }

  Future<void> dispose() => _controller.close();
}
