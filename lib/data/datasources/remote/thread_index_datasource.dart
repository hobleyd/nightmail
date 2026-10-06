import '../../models/email_model.dart';

/// One thread as a folder listing names it: its id, and the id of the last
/// history record that changed it.
class ThreadIndexEntry {
  const ThreadIndexEntry({required this.threadId, required this.historyId});

  final String threadId;

  /// Moves whenever anything about the thread changes — a reply, a read, a
  /// star, a label — so two readings with the same stamp are the same thread
  /// in the same state.
  final String historyId;
}

/// A provider whose folder listing can be read as an *index* — which threads,
/// each stamped with when it last changed — for a fraction of the cost of the
/// page it describes.
///
/// Only Gmail. Its `threads.list` carries each thread's `historyId` and costs
/// 10 quota units, where the page [EmailRemoteDatasource.getEmails] builds from
/// it is that call plus one `threads.get` per thread at 40 units each: 1,010
/// units for a 25-thread page. The poller re-reads the folder on screen every
/// cycle to notice what changed there (`MailPollerCubit._syncWatchedFolder`),
/// and under Gmail's 6,000 units/minute per-user quota that one re-read was a
/// third of the budget spent on a folder where nothing had happened. With the
/// index a quiet cycle costs the 10 units, and a changed thread costs its own
/// fetch and nobody else's.
///
/// Graph and IMAP are not here: Graph's listing carries no per-conversation
/// change stamp and its page is two requests whatever its size, and IMAP's
/// listing *is* the page.
abstract interface class ThreadIndexDatasource {
  /// The newest [top] threads in [folderId], in listing order.
  ///
  /// Must not disturb the paging state of [EmailRemoteDatasource.getEmails]:
  /// the list on screen may be mid-way through loading more of this folder.
  Future<List<ThreadIndexEntry>> listThreadIndex(
    String folderId, {
    int top = 25,
  });

  /// The messages of [threadIds], exactly as [EmailRemoteDatasource.getEmails]
  /// would list them for [folderId] — same exclusions, same folder stamping —
  /// grouped by thread.
  ///
  /// All of them or an error: a listing skips a thread it could not fetch, but
  /// a page built from an index replaces the cache and records the stamps it
  /// was built from, so a thread quietly missing from it would be gone until
  /// it next changed.
  Future<List<EmailModel>> getThreadMessages(
    List<String> threadIds, {
    required String folderId,
  });
}
