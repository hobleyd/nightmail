/// A provider whose folder membership is a property of the *thread* as well as
/// of each message in it, and which can therefore be asked to take a whole
/// conversation out of a folder in one operation.
///
/// Only Gmail. Graph and IMAP put a message in exactly one folder and have no
/// thread-level membership at all, so for them the per-message move is already
/// the whole story and there is nothing this could mean.
///
/// The case it exists for: a Gmail folder listing is
/// `GET /users/me/threads?labelIds=<folder>`, which returns a **thread** the
/// label applies to and then every message in it — so a thread can be listed in
/// the Inbox while not one of its messages carries `INBOX`. Real mailboxes
/// reach that state (a move applied to some messages and not others, a filter,
/// a label edit from another client), and once there the folder-scoped move is
/// stuck: it acts per message, no message is in the folder, so it does nothing
/// and the thread comes back on the next listing.
///
/// See [EmailListBloc._onEmailsMoved] for the fallback that uses this.
abstract interface class ConversationFolderDatasource {
  /// Removes [folderId] from every message of [conversationId], and from the
  /// conversation itself.
  ///
  /// **Removal only, never an add.** The messages this reaches include the
  /// thread's copies in Sent, and adding a destination label to those is
  /// exactly what [Email.isMovableFrom]'s Sent guard exists to prevent — it
  /// would file the record of what was sent into the folder the user was
  /// tidying. Removing a label a message does not carry is a no-op, so the
  /// removal has no such reach.
  Future<void> removeConversationFromFolder(
    String conversationId,
    String folderId,
  );
}
