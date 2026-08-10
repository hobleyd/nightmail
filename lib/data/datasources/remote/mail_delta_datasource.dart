import '../../models/mail_delta_result.dart';

/// Incremental mail sync, for a provider that can report what changed rather
/// than only what a folder currently holds.
///
/// Provider-neutral on purpose: the poller's one `is` check decides whether an
/// account gets change detection or falls back to comparing two integers, and
/// two offsetting changes in one interval (one message read, one arriving
/// unread) leave both integers identical — so anything that *can* answer this
/// interface should, and the poller should not have to name the providers that
/// do. Graph implements it over `/messages/delta`, Gmail over
/// `users.history.list`; IMAP does not implement it at all and stays on counts.
abstract interface class MailDeltaDatasource {
  /// Fetches changes to messages in [folderId] since [deltaLink] was issued.
  ///
  /// [deltaLink] is an opaque cursor — a Graph `@odata.deltaLink`, a Gmail
  /// `historyId` — and is only ever handed back to the same provider that
  /// issued it. Pass null for the initial sync, which establishes a cursor and
  /// returns it; whether that first call also carries messages is up to the
  /// provider (Graph pages through the folder under a client-side budget, Gmail
  /// only reads the mailbox's current `historyId`, having nothing to page).
  /// There is deliberately no date filter: Graph bakes the originating query
  /// into the delta link, so a cutoff would be frozen there for its whole life.
  ///
  /// On subsequent calls, supply the stored cursor to receive only new,
  /// modified, or deleted messages since the last sync. A cursor the provider
  /// no longer recognises must be reported as a `ServerException` the poller
  /// can see (Graph 410/400, Gmail 404), which clears it and re-bootstraps.
  Future<MailDeltaResult> syncMailDelta(
    String folderId, {
    String? deltaLink,
  });
}
