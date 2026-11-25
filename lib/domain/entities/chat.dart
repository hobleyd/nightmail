import 'dart:typed_data';

import 'package:equatable/equatable.dart';

/// What kind of conversation a [ChatConversation] is.
///
/// [oneOnOne], [group] and [meeting] are Graph's `chatType`s (Google's
/// `DIRECT_MESSAGE` and `GROUP_CHAT` map to the first two); [channel] is a
/// Teams channel, which Graph keeps under `/teams` rather than `/chats`;
/// [space] is a named Google Chat space.
enum ChatKind { oneOnOne, group, meeting, channel, space }

/// Which chat system a [ChatSource] is.
enum ChatSourceKind { teams, nightmailServer, googleChat, slack }

/// One chat system the Chat button can open: the active account's own
/// ("platform") chat, or a connected Slack workspace.
///
/// [id] is what every [ChatRepository] call takes as its `accountId`: the
/// email account's id for the platform chat, `slack:{teamId}` for Slack.
class ChatSource extends Equatable {
  const ChatSource({
    required this.id,
    required this.kind,
    required this.label,
    this.needsReconnect = false,
    this.missingScopes = false,
  });

  final String id;
  final ChatSourceKind kind;

  /// "Teams", "Google Chat", "Slack · Acme" — what the Chat menu shows.
  final String label;

  /// A Slack workspace whose token Slack no longer accepts.
  final bool needsReconnect;

  /// A Slack workspace connected before this version asked for something
  /// more (custom emoji): it works, and connecting again adds the rest.
  final bool missingScopes;

  bool get isSlack => kind == ChatSourceKind.slack;

  /// Whether a chat id names a Slack workspace rather than an email account.
  static bool isSlackId(String? id) => id?.startsWith('slack:') ?? false;

  @override
  List<Object?> get props => [id, kind, label, needsReconnect, missingScopes];
}

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
    this.unread = false,
    this.noMessages = false,
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

  /// Someone else has written since the user last read it. Always false for
  /// a Teams channel, which has no per-user read state.
  final bool unread;

  /// The provider says nothing has ever been written in it — a meeting's
  /// chat nobody used, a space only created. Its [lastActivity] is then just
  /// when it was made. False when not known.
  final bool noMessages;

  bool get isChannel => kind == ChatKind.channel;

  /// Whether messages here are posts with replies (Teams channels, threaded
  /// Google spaces) rather than one flat history.
  bool get hasThreads => isChannel || threaded;

  /// Unique across chats and channels of one account.
  String get key => isChannel ? '$teamId/$id' : id;

  ChatConversation copyWith({
    String? title,
    DateTime? lastActivity,
    String? lastMessagePreview,
    bool? unread,
    bool? noMessages,
  }) =>
      ChatConversation(
        id: id,
        kind: kind,
        title: title ?? this.title,
        teamId: teamId,
        teamName: teamName,
        lastActivity: lastActivity ?? this.lastActivity,
        lastMessagePreview: lastMessagePreview ?? this.lastMessagePreview,
        members: members,
        threaded: threaded,
        unread: unread ?? this.unread,
        // Activity or a preview means something was written.
        noMessages: noMessages ??
            (this.noMessages &&
                lastActivity == null &&
                lastMessagePreview == null),
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
        unread,
        noMessages,
      ];
}

/// One emoji reaction and how many gave it.
class ChatReaction extends Equatable {
  const ChatReaction({
    required this.emoji,
    required this.count,
    this.imageUrl,
    this.userIds = const [],
  });

  /// The character(s), or — for a workspace's own emoji — its `:name:`.
  final String emoji;
  final int count;

  /// A workspace's own emoji (Slack): the picture to show instead of [emoji].
  final String? imageUrl;

  /// Who gave it, as [ChatMessage.senderUserId] names people, as far as the
  /// provider lists them (Graph and Slack do; Google's summary does not).
  /// What tells the user's own reaction apart, so it is not counted twice.
  final List<String> userIds;

  /// This reaction with [userId]'s added to it.
  ChatReaction plus(String? userId) => ChatReaction(
        emoji: emoji,
        count: count + 1,
        imageUrl: imageUrl,
        userIds: [...userIds, ?userId],
      );

  @override
  List<Object?> get props => [emoji, count, imageUrl, userIds];
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
    this.editableText,
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

  /// The body as the user would type it to say the same again — what an
  /// edit starts from. Null when plain text cannot say it (a mention, a
  /// labelled link, formatting or a file the provider keeps in the body), so
  /// such a message offers no edit rather than losing them on save.
  final String? editableText;

  int get totalReplies => replyCount ?? replies.length;

  /// This message after the user changed its text to [editableText].
  ChatMessage withEdit({
    required String bodyHtml,
    required String? editableText,
    required DateTime editedAt,
  }) =>
      _copy(
          bodyHtml: bodyHtml, editableText: editableText, editedAt: editedAt);

  /// This post with [replies] in place of its own.
  ChatMessage withReplies(List<ChatMessage> replies) => _copy(replies: replies);

  /// This post with one more reply than it had.
  ChatMessage withOneMoreReply() => _copy(replyCount: totalReplies + 1);

  /// This message after [userId] (the user) reacted with [emoji]: one more
  /// on that reaction, or a new one at the end.
  ChatMessage withReaction(String emoji, String? userId) {
    final i = reactions.indexWhere((r) => r.emoji == emoji);
    return _copy(
      reactions: i < 0
          ? [
              ...reactions,
              ChatReaction(emoji: emoji, count: 1, userIds: [?userId]),
            ]
          : [
              for (var j = 0; j < reactions.length; j++)
                j == i ? reactions[j].plus(userId) : reactions[j],
            ],
    );
  }

  /// This message with [userId] known to be among [emoji]'s givers — the
  /// server said the user's was already there — without counting it again.
  ChatMessage withReactor(String emoji, String userId) => _copy(
        reactions: [
          for (final r in reactions)
            r.emoji == emoji && !r.userIds.contains(userId)
                ? ChatReaction(
                    emoji: r.emoji,
                    count: r.count,
                    imageUrl: r.imageUrl,
                    userIds: [...r.userIds, userId],
                  )
                : r,
        ],
      );

  /// This message after [userId] (the user) took their [emoji] reaction
  /// off: one fewer, gone at none.
  ChatMessage withoutReaction(String emoji, String? userId) => _copy(
        reactions: [
          for (final r in reactions)
            if (r.emoji != emoji)
              r
            else if (r.count > 1)
              ChatReaction(
                emoji: r.emoji,
                count: r.count - 1,
                imageUrl: r.imageUrl,
                userIds: [
                  for (final u in r.userIds)
                    if (u != userId) u,
                ],
              ),
        ],
      );

  ChatMessage _copy({
    String? bodyHtml,
    String? editableText,
    DateTime? editedAt,
    List<ChatMessage>? replies,
    List<ChatReaction>? reactions,
    int? replyCount,
  }) =>
      ChatMessage(
        id: id,
        createdAt: createdAt,
        senderName: senderName,
        senderUserId: senderUserId,
        bodyHtml: bodyHtml ?? this.bodyHtml,
        replyToId: replyToId,
        subject: subject,
        editedAt: editedAt ?? this.editedAt,
        isDeleted: isDeleted,
        isSystem: isSystem,
        reactions: reactions ?? this.reactions,
        replies: replies ?? this.replies,
        replyCount: replyCount ?? this.replyCount,
        attachmentNames: attachmentNames,
        conversationTitle: conversationTitle,
        threadId: threadId,
        editableText: editableText ?? this.editableText,
      );

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
        editableText,
      ];
}

/// A picture sent with a message — pasted into the composer.
class ChatOutgoingImage extends Equatable {
  const ChatOutgoingImage({
    required this.bytes,
    required this.mimeType,
    required this.name,
    this.width,
    this.height,
  });

  final Uint8List bytes;

  /// `image/png`, `image/jpeg` or `image/gif`.
  final String mimeType;

  /// A file name for providers that keep one (Google, Slack).
  final String name;

  /// Pixels, when known — Teams draws a hosted picture at the size its
  /// `<img>` gives.
  final int? width;
  final int? height;

  @override
  List<Object?> get props => [bytes, mimeType, name, width, height];
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

/// What changed in a conversation since a point in time
/// ([ChatRemoteDatasource.messagesSince]): new messages, and — where the
/// provider can tell — edited, deleted and reacted-to ones.
class ChatMessageDelta extends Equatable {
  const ChatMessageDelta({
    required this.messages,
    this.watermark,
    this.complete = false,
  });

  /// Top-level messages, any order; each replaces the one with its id.
  final List<ChatMessage> messages;

  /// The newest server timestamp among [messages] — what the next delta asks
  /// from, so the device's clock never decides what is missed. Null when
  /// nothing changed, which leaves the previous one standing.
  final DateTime? watermark;

  /// Whether this delta also reports edits, deletions and reactions to older
  /// messages (Graph's `lastModifiedDateTime`). Slack's and Google's only
  /// bring new messages, so a full page is still read now and then.
  final bool complete;

  @override
  List<Object?> get props => [messages, watermark, complete];
}
