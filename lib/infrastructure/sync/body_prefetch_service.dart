import '../../data/datasources/local/email_local_datasource.dart';
import '../../data/datasources/remote/email_remote_datasource.dart';
import '../../domain/entities/email.dart';

/// Warms the message cache by downloading full bodies for newly-arrived mail
/// in the background, so opening a message later is instant instead of
/// triggering a per-message network round-trip on tap.
///
/// List/delta syncs fetch only envelope/preview data (no body) to keep folder
/// loads and polling cheap — see [ImapDatasourceImpl.getEmails] and friends.
/// A row cached from one of those has an empty body, so [EmailRepositoryImpl.getEmail]
/// falls through to the network the first time the reading pane opens it. This
/// service closes that gap: right after a sync lands new messages it upgrades
/// their thin rows to full copies (body + inline images + attachment metadata)
/// by reusing each provider's own single-message [EmailRemoteDatasource.getEmail]
/// — the identical fetch the tap would otherwise run.
///
/// Attachment *bytes* are deliberately not persisted (getEmail caches inline
/// images and attachment metadata, not attachment payloads); regular file
/// attachments still download on demand when opened. That keeps the prefetch
/// "body + inline images" rather than a full offline mirror of every payload.
class BodyPrefetchService {
  BodyPrefetchService({required EmailLocalDatasource localDatasource})
      : _local = localDatasource;

  final EmailLocalDatasource _local;

  /// Accounts with a prefetch batch currently running. A second trigger for
  /// the same account while one is in flight is dropped rather than queued —
  /// the next sync re-supplies whatever still lacks a body.
  final Set<String> _inFlight = {};

  /// Upper bound on messages fetched per batch, so a large sync can't turn
  /// into a long serial run of round-trips that starves the poll loop.
  static const _maxPerBatch = 20;

  /// One frame, yielded to between messages so the batch never runs as one
  /// tight burst.
  ///
  /// Parsing a message does not happen on the calling isolate any more — each
  /// provider's `getEmail` hands the undecoded response to a background isolate
  /// (see `gmail_message_parser.dart` and friends). What that leaves here is
  /// small but not free: one `compute()` spawn per message, plus the request.
  /// Spacing them keeps a 20-message batch from queueing 20 isolate startups
  /// back to back behind whatever the user is doing.
  ///
  /// A plain `await` would not do it — microtasks run before the next frame, so
  /// the loop would resume without one ever being drawn. This has to be a timer,
  /// i.e. a real event-loop turn.
  static const _betweenMessages = Duration(milliseconds: 16);

  /// Fetches and caches full bodies for the body-less messages in [emails].
  ///
  /// Runs the fetches serially: IMAP accounts share one connection whose
  /// selected mailbox is mutated per fetch, so concurrent [getEmail] calls on
  /// a single datasource would race each other. Per-message failures are
  /// swallowed — a message that fails to prefetch simply stays lazy and loads
  /// on tap exactly as before.
  ///
  /// Deliberately takes no folder. A prefetch runs for the folder on screen but
  /// the message may be listed in several, and the upgrade is addressed to the
  /// message alone — handing a folder down here is what used to re-file the row
  /// and empty another folder's cache of it.
  Future<void> prefetchBodies({
    required String accountId,
    required EmailRemoteDatasource datasource,
    required List<Email> emails,
  }) async {
    if (_inFlight.contains(accountId)) return;

    final candidates =
        emails.where((e) => e.body.isEmpty).take(_maxPerBatch).toList();
    if (candidates.isEmpty) return;

    _inFlight.add(accountId);
    try {
      for (final candidate in candidates) {
        try {
          // Skip if the row has since vanished (deleted/moved between the sync
          // and now) or another path already filled its body: nothing here
          // should spend a round-trip on a message that no longer needs one.
          final cached = await _local.getCachedEmailById(
            accountId: accountId,
            emailId: candidate.id,
          );
          if (cached == null || cached.body.isNotEmpty) continue;

          final full = await datasource.getEmail(candidate.id);
          if (full.body.isEmpty) continue;

          // Never a plain cacheEmails: that inserts, and this write lands after
          // a network fetch and an isolate parse — the window in which the user,
          // who is most likely reading this very message, deletes it. The check
          // above cannot cover that; it ran before the fetch, and re-doing it
          // here would still leave the delete free to commit between the check
          // and the insert. upgradeCachedEmailBody decides "still cached?"
          // inside its own transaction and writes nothing if the answer is no.
          //
          // It also keeps the cached read state over the fetched one — see there.
          await _local.upgradeCachedEmailBody(
            accountId: accountId,
            email: full,
          );
        } catch (_) {
          // Best-effort: leave this one to load lazily on tap.
        }
        // Outside the catch so a failed fetch still yields, but after the
        // `continue`s above, which skip it — those did no parsing to yield for.
        await Future<void>.delayed(_betweenMessages);
      }
    } finally {
      _inFlight.remove(accountId);
    }
  }
}
