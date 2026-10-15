/// Drops the cross-folder context rows a folder listing kept for a thread whose
/// only in-folder message reconciliation has just taken out.
///
/// Both providers expand a folder page with the *other-folder* copies of every
/// thread on it (see `email_list/CLAUDE.md`), and that expansion is decided on
/// the server's page — before the outbox reconciliation drops the ids the user
/// has just moved or deleted. Exchange Online answers a listing from a replica
/// seconds behind a move, so the page can still name the moved message under
/// its old id; that id is tombstoned and goes, but the expansion has already
/// fetched its conversation, and on Graph a move assigns a **new id** the
/// tombstone deliberately does not cover (it is the message's new home — see
/// `OutboxDrainService._tombstoneAcknowledgedRemoval`). The moved message came
/// back into the folder it had just left, labelled with its destination, and
/// stayed until a listing from a caught-up replica replaced the folder.
library;

import '../../domain/entities/email.dart';

/// Returns [kept] without the rows of any thread that lost an in-folder message
/// to reconciliation ([removed]) and has nothing left in [folderId].
///
/// Two limits, both load-bearing:
///
/// - **Only threads that lost an in-folder row here.** A thread on screen with
///   no message in the folder is otherwise legitimate — Gmail lists a folder by
///   thread and can name one none of whose messages carries the label — so
///   nothing is inferred about a thread reconciliation did not touch. Requiring
///   the lost row to be `isInFolder` also makes a folder id the rows do not
///   compare equal to (Graph does not encode one consistently) a no-op rather
///   than a reason to hide every thread the user removed a message from.
/// - **Only when a sibling is not still in the folder.** Moving one message of
///   a thread whose others stay put leaves its new copy beside them as the
///   context the expansion exists to show.
///
/// A null [folderId] is a mailbox-wide listing, which has no folder to leave.
List<Email> dropThreadsLeftOutsideFolder(
  List<Email> kept, {
  required List<Email> removed,
  required String? folderId,
}) {
  if (folderId == null || removed.isEmpty) return kept;

  final stillInFolder = {
    for (final e in kept)
      if (e.conversationId != null && e.isInFolder(folderId)) e.conversationId!,
  };
  final orphaned = {
    for (final e in removed)
      if (e.conversationId != null &&
          e.isInFolder(folderId) &&
          !stillInFolder.contains(e.conversationId))
        e.conversationId!,
  };
  if (orphaned.isEmpty) return kept;
  return kept.where((e) => !orphaned.contains(e.conversationId)).toList();
}
