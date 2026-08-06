import '../../domain/entities/email.dart';

// ---------------------------------------------------------------------------
// Conversation grouping logic
// ---------------------------------------------------------------------------

class EmailConversation {
  EmailConversation({
    required this.id,
    required this.emails,
    required this.anchor,
  });

  final String id;

  /// Every message of the thread this view holds, newest first.
  final List<Email> emails;

  /// The message the collapsed thread row stands for: the newest one the user
  /// did not send. A row headed by the user's own reply says nothing they don't
  /// already know — what they need to see is who is waiting on them.
  final Email anchor;

  Email get latest => emails.first;
  DateTime get latestDate => latest.receivedDateTime;

  /// What the row orders by. The row shows [anchor], so ordering the list on
  /// anything else runs the visible dates out of sequence.
  DateTime get anchorDate => anchor.receivedDateTime;

  bool get hasUnread => emails.any((e) => !e.isRead);

  bool isAnchor(Email email) => email.id == anchor.id;

  /// The rows drawn beneath the header once the thread is expanded.
  ///
  /// The whole thread, in order — **including** [anchor], which the header is
  /// already showing. Dropping it would leave a reply sitting above nothing,
  /// and the back-and-forth is the only thing the order is there to convey.
  /// The exception is an anchor that is also the newest message: repeating it
  /// directly beneath the header it just filled is noise, not context. See
  /// [isAnchor] for marking the repeat as a repeat.
  List<Email> get expandedEmails =>
      isAnchor(emails.first) ? emails.skip(1).toList() : emails;
}

/// Groups [emails] by conversation, newest message first within each thread and
/// threads ordered by [EmailConversation.anchorDate].
///
/// [selfAddress] is the account's own address — the only way to tell the user's
/// messages from everyone else's, and so to pick each thread's anchor. Omit it
/// and every thread is headed by its newest message.
List<EmailConversation> groupIntoConversations(
  List<Email> emails, {
  String? selfAddress,
}) {
  final sorted = [...emails]
    ..sort((a, b) => b.receivedDateTime.compareTo(a.receivedDateTime));

  final map = <String, List<Email>>{};
  for (final email in sorted) {
    final key = email.conversationId ?? email.id;
    map.putIfAbsent(key, () => []).add(email);
  }

  final self = selfAddress?.trim().toLowerCase();
  return map.entries
      .map((e) => EmailConversation(
            id: e.key,
            emails: e.value,
            anchor: _anchorOf(e.value, self),
          ))
      .toList()
    ..sort((a, b) => b.anchorDate.compareTo(a.anchorDate));
}

/// The newest message of [emails] (newest first) that [self] did not send.
///
/// Falls back to the newest of all when they are all the user's own — a thread
/// they started and nobody has answered, or any thread seen from Sent, still
/// has to be headed by something.
Email _anchorOf(List<Email> emails, String? self) {
  if (self == null || self.isEmpty) return emails.first;
  for (final email in emails) {
    if (!_isFromSelf(email, self)) return email;
  }
  return emails.first;
}

/// An empty from address is an unsent draft, which is the user's own.
bool _isFromSelf(Email email, String self) {
  final from = email.from.address.trim().toLowerCase();
  return from.isEmpty || from == self;
}

// ---------------------------------------------------------------------------
// Delete targets
// ---------------------------------------------------------------------------

/// What deleting a selection of list rows actually targets.
class DeleteTargets {
  const DeleteTargets({
    required this.conversationIds,
    required this.emailIds,
    required this.removed,
  });

  /// Threads to delete whole — every message of theirs this folder holds.
  final List<String> conversationIds;

  /// Standalone messages to delete by id.
  final List<String> emailIds;

  /// What leaves this folder, for the unread/total badge deltas.
  final List<Email> removed;

  bool get isEmpty => conversationIds.isEmpty && emailIds.isEmpty;
}

/// Resolves the rows [selectedIds] stands for into what a delete should do.
///
/// A conversation row is selected by its anchor's id, because that is the
/// message the row displays — but the row *is* the thread, so deleting by that
/// id alone would leave the rest of the thread sitting in the folder. Those ids
/// become thread deletes; everything else stays a single-message delete. An
/// expanded thread's repeat of its own anchor carries the same id, so selecting
/// it means the thread too — it is the same message as the header.
///
/// [removed] counts only what actually leaves [currentFolderId]. A thread's
/// already-filed replies and its copies in Sent are on screen for context and
/// are not going anywhere, so counting them out of the folder would walk the
/// badges down past what the folder holds.
DeleteTargets resolveDeleteTargets({
  required List<Email> emails,
  required List<String> selectedIds,
  required String? currentFolderId,
  String? selfAddress,
}) {
  final threadHeadIds = <String, String>{};
  for (final conversation
      in groupIntoConversations(emails, selfAddress: selfAddress)) {
    if (conversation.emails.length < 2) continue;
    threadHeadIds[conversation.anchor.id] = conversation.id;
  }
  final byId = {for (final e in emails) e.id: e};

  final conversationIds = <String>{};
  final singleIds = <String>[];
  for (final id in selectedIds) {
    final conversationId = threadHeadIds[id];
    if (conversationId != null) {
      conversationIds.add(conversationId);
    } else {
      singleIds.add(id);
    }
  }
  // A message selected alongside its own thread's row is already covered by the
  // thread delete. Ids the list doesn't know are passed through rather than
  // dropped — better a redundant delete than a silently skipped one.
  final emailIds = singleIds
      .where((id) => !conversationIds.contains(byId[id]?.conversationId))
      .toList();

  final emailIdSet = emailIds.toSet();
  final removed = [
    for (final e in emails)
      if (conversationIds.contains(e.conversationId ?? e.id)
          ? e.isDeletableFrom(currentFolderId)
          : emailIdSet.contains(e.id))
        e,
  ];

  return DeleteTargets(
    conversationIds: conversationIds.toList(),
    emailIds: emailIds,
    removed: removed,
  );
}
