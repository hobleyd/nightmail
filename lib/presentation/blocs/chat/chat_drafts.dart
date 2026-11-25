import '../../../domain/entities/chat.dart';

/// A half-typed chat message, kept while the user looks elsewhere.
class ChatDraft {
  const ChatDraft(this.text, this.mentions);

  final String text;

  /// People picked from the `@` list for [text], so they still go as tags
  /// once it is sent.
  final List<ChatMember> mentions;
}

/// What was typed into each composer and not sent, by where it was typed:
/// one per conversation (or person not chatted with yet), and one per open
/// thread. Kept in memory for the life of the app — a lazy singleton, so it
/// outlives the Chat pane, whose cubit and composer go when it closes. Each
/// window is its own engine, so the Chat window keeps its own.
class ChatDrafts {
  final _drafts = <String, ChatDraft>{};

  ChatDraft? operator [](String key) => _drafts[key];

  /// Keeps [text] under [key], or forgets the key when nothing is typed.
  void put(String key, String text, List<ChatMember> mentions) {
    if (text.trim().isEmpty) {
      _drafts.remove(key);
    } else {
      _drafts[key] = ChatDraft(text, List.unmodifiable(mentions));
    }
  }

  /// Where a composer showing [accountId]'s [conversation] (or the
  /// not-yet-started chat with [personEmail]) types; null with nothing open.
  /// [threadPostId] is the open thread, for the thread's own composer.
  static String? keyOf({
    required String? accountId,
    required ChatConversation? conversation,
    required String? personEmail,
    String? threadPostId,
  }) {
    if (accountId == null) return null;
    final where = conversation != null
        ? 'c:${conversation.key}'
        : personEmail != null
            ? 'p:${personEmail.toLowerCase()}'
            : null;
    if (where == null) return null;
    return threadPostId == null
        ? '$accountId|$where'
        : '$accountId|$where|t:$threadPostId';
  }
}
