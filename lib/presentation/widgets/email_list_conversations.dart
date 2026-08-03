import '../../domain/entities/email.dart';

// ---------------------------------------------------------------------------
// Conversation grouping logic
// ---------------------------------------------------------------------------

class EmailConversation {
  EmailConversation({required this.id, required this.emails});
  final String id;
  final List<Email> emails;

  Email get latest => emails.first;
  DateTime get latestDate => latest.receivedDateTime;
  bool get hasUnread => emails.any((e) => !e.isRead);
}

List<EmailConversation> groupIntoConversations(List<Email> emails) {
  final sorted = [...emails]
    ..sort((a, b) => b.receivedDateTime.compareTo(a.receivedDateTime));

  final map = <String, List<Email>>{};
  for (final email in sorted) {
    final key = email.conversationId ?? email.id;
    map.putIfAbsent(key, () => []).add(email);
  }

  return map.entries
      .map((e) => EmailConversation(id: e.key, emails: e.value))
      .toList()
    ..sort((a, b) => b.latestDate.compareTo(a.latestDate));
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
/// A conversation row is selected by its newest message's id, because that is
/// the message the row displays — but the row *is* the thread, so deleting by
/// that id alone would leave the rest of the thread sitting in the folder.
/// Those ids become thread deletes; everything else stays a single-message
/// delete.
///
/// [removed] counts only what actually leaves [currentFolderId]. A thread's
/// already-filed replies and its copies in Sent are on screen for context and
/// are not going anywhere, so counting them out of the folder would walk the
/// badges down past what the folder holds.
DeleteTargets resolveDeleteTargets({
  required List<Email> emails,
  required List<String> selectedIds,
  required String? currentFolderId,
}) {
  final threadHeadIds = <String, String>{};
  for (final conversation in groupIntoConversations(emails)) {
    if (conversation.emails.length < 2) continue;
    threadHeadIds[conversation.latest.id] = conversation.id;
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
