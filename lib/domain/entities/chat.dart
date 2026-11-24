import 'package:equatable/equatable.dart';

/// What kind of conversation a [ChatConversation] is.
///
/// [oneOnOne], [group] and [meeting] are Graph's `chatType`s (Google's
/// `DIRECT_MESSAGE` and `GROUP_CHAT` map to the first two); [channel] is a
/// Teams channel, which Graph keeps under `/teams` rather than `/chats`;
/// [space] is a named Google Chat space.
enum ChatKind { oneOnOne, group, meeting, channel, space }

/// One person in a conversation.
class ChatMember extends Equatable {
  const ChatMember({
    required this.displayName,
    this.userId,
    this.email,
  });

  final String displayName;

  /// The directory id. Null for a guest or bot the provider does not know.
  final String? userId;

  /// Lower-cased. Null when the provider did not say.
  final String? email;

  @override
  List<Object?> get props => [displayName, userId, email];
}

/// A chat (one-on-one, group or meeting) or a team channel.
class ChatConversation extends Equatable {
  const ChatConversation({
    required this.id,
    required this.kind,
    required this.title,
    this.teamId,
    this.teamName,
    this.lastActivity,
    this.lastMessagePreview,
    this.members = const [],
    this.threaded = false,
  });

  /// The chat id, or the channel id for a [ChatKind.channel] (which only
  /// means something together with [teamId]).
  final String id;
  final ChatKind kind;

  /// The topic, the channel name, or — for a chat without a topic — the other
  /// members' names, already resolved for display.
  final String title;

  final String? teamId;
  final String? teamName;

  /// When anything last happened in it; what the conversation list sorts by.
  /// Null for a channel whose latest message has not been looked up yet.
  final DateTime? lastActivity;

  /// Plain text of the newest message, for the list row.
  final String? lastMessagePreview;

  /// Empty when not expanded (channels never are).
  final List<ChatMember> members;

  /// A Google space whose messages are organised in threads. A Teams channel
  /// always is, see [hasThreads].
  final bool threaded;

  bool get isChannel => kind == ChatKind.channel;

  /// Whether messages here are posts with replies (Teams channels, threaded
  /// Google spaces) rather than one flat history.
  bool get hasThreads => isChannel || threaded;

  /// Unique across chats and channels of one account.
  String get key => isChannel ? '$teamId/$id' : id;

  ChatConversation copyWith({
    DateTime? lastActivity,
    String? lastMessagePreview,
  }) =>
      ChatConversation(
        id: id,
        kind: kind,
        title: title,
        teamId: teamId,
        teamName: teamName,
        lastActivity: lastActivity ?? this.lastActivity,
        lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
        members: members,
        threaded: threaded,
      );

  @override
  List<Object?> get props => [
        id,
        kind,
        title,
        teamId,
        teamName,
        lastActivity,
        lastMessagePreview,
        members,
        threaded,
      ];
}

/// One emoji reaction and how many gave it.
class ChatReaction extends Equatable {
  const ChatReaction({required this.emoji, required this.count});

  final String emoji;
  final int count;

  @override
  List<Object?> get props => [emoji, count];
}

/// A message in a chat, or a post or reply in a channel.
class ChatMessage extends Equatable {
  const ChatMessage({
    required this.id,
    required this.createdAt,
    required this.senderName,
    required this.bodyHtml,
    this.senderUserId,
    this.replyToId,
    this.subject,
    this.editedAt,
    this.isDeleted = false,
    this.isSystem = false,
    this.reactions = const [],
    this.replies = const [],
    this.replyCount,
    this.attachmentNames = const [],
    this.conversationTitle,
    this.threadId,
  });

  final String id;
  final DateTime createdAt;
  final String senderName;
  final String? senderUserId;

  /// The body as the provider sent it — HTML for both Graph and NightMail
  /// Server. Rendered through `chat_message_body.dart`, never a webview.
  final String bodyHtml;

  /// The post this reply belongs to (channels), or the message a chat message
  /// answers. Null for a top-level message.
  final String? replyToId;

  /// A channel post's subject line.
  final String? subject;
  final DateTime? editedAt;
  final bool isDeleted;

  /// A "member added", "call ended" and the like: rendered as a centred note.
  final bool isSystem;
  final List<ChatReaction> reactions;

  /// A channel post's replies, oldest first, as far as the provider listed
  /// them with the post. Empty for chats.
  final List<ChatMessage> replies;

  /// How many replies the post has, when known beyond [replies].
  final int? replyCount;

  /// File names of attachments (files are shown by name; opening them is
  /// the provider's web client's job).
  final List<String> attachmentNames;

  /// Search results only: where the message was found.
  final String? conversationTitle;

  /// The thread a post starts, where the provider names threads apart from
  /// messages (Google's `spaces/…/threads/…`). Null on Graph, where a post's
  /// own [id] is its thread.
  final String? threadId;

  int get totalReplies => replyCount ?? replies.length;

  @override
  List<Object?> get props => [
        id,
        createdAt,
        senderName,
        senderUserId,
        bodyHtml,
        replyToId,
        subject,
        editedAt,
        isDeleted,
        isSystem,
        reactions,
        replies,
        replyCount,
        attachmentNames,
        conversationTitle,
        threadId,
      ];
}

/// A page of a conversation's history, newest first, and how to read on.
class ChatMessagePage extends Equatable {
  const ChatMessagePage({required this.messages, this.nextLink});

  final List<ChatMessage> messages;

  /// The provider's link to the next (older) page; null at the beginning.
  final String? nextLink;

  @override
  List<Object?> get props => [messages, nextLink];
}

/// A search hit: the message and the conversation it lives in, as far as the
/// provider says (Microsoft Search names the chat or channel).
class ChatSearchHit extends Equatable {
  const ChatSearchHit({
    required this.message,
    this.chatId,
    this.teamId,
    this.channelId,
  });

  final ChatMessage message;
  final String? chatId;
  final String? teamId;
  final String? channelId;

  /// The [ChatConversation.key] this hit opens, when known.
  String? get conversationKey =>
      chatId ?? (teamId != null && channelId != null ? '$teamId/$channelId' : null);

  @override
  List<Object?> get props => [message, chatId, teamId, channelId];
}
