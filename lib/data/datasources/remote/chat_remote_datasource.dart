import 'dart:typed_data';

import '../../../domain/entities/chat.dart';

/// One provider's chat: Graph (Microsoft 365 and NightMail Server,
/// `GraphChatDatasource`) or Google Chat (`GoogleChatDatasource`).
///
/// Always the signed-in user's own chats. Built fresh per call by
/// `AccountManager.chatDatasourceForAccount`, so it holds nothing an account
/// switch could leave pointing at the wrong mailbox.
abstract interface class ChatRemoteDatasource {
  /// Whether [search] asks the server. False means the provider has no
  /// message search the user can call, and the repository scans recent
  /// history instead.
  bool get searchesOnServer;

  /// Whether [findOneOnOne] asks the server. False means the repository finds
  /// the one-on-one by scanning [listChats].
  bool get findsOneOnOneDirectly;

  /// Chats (and, on Google, spaces), in any order.
  Future<List<ChatConversation>> listChats();

  /// The most recent chats (one page, no members), only for their
  /// [ChatConversation.unread] — the cheap listing the unread dot polls.
  /// Empty where the provider has no read state NightMail can see.
  Future<List<ChatConversation>> listRecentChats();

  /// Tells the server the user has read [chat] up to its newest message.
  /// Chats only; a no-op where the provider has no read state.
  Future<void> markRead(ChatConversation chat);

  /// The signed-in user's id as a [ChatMessage.senderUserId] carries it, or
  /// null when it cannot be told. Google names it per space, so it asks
  /// [conversation]'s members.
  Future<String?> ownUserId(ChatConversation? conversation);

  /// Teams channels; empty where the provider has none.
  Future<List<ChatConversation>> listChannels();

  /// [channel] with its newest activity filled in.
  Future<ChatConversation> channelActivity(ChatConversation channel);

  /// The one-on-one with [email], or null when there is none. Only when
  /// [findsOneOnOneDirectly].
  Future<ChatConversation?> findOneOnOne(String email);

  /// Newest first. [cursor] is a previous page's [ChatMessagePage.nextLink],
  /// opaque to everyone but the datasource that issued it.
  Future<ChatMessagePage> messages(
    ChatConversation conversation, {
    String? cursor,
  });

  /// What changed in [conversation] since [since] — a previous
  /// [ChatMessageDelta.watermark] — or null where it cannot be asked that
  /// way (a Teams channel, a NightMail Server, a threaded Google space, more
  /// than a few pages of changes): the caller reads [messages] instead.
  Future<ChatMessageDelta?> messagesSince(
    ChatConversation conversation,
    DateTime since,
  );

  /// Whether a message in [conversation] can be answered in a thread of its
  /// own: every [ChatConversation.hasThreads] one, and on Slack a DM or
  /// group DM too, which thread exactly as channels do. A Teams chat has no
  /// threads (Graph documents no quoted reply either), nor does a Google DM
  /// (`messageReplyOption` is for named spaces only).
  bool canThread(ChatConversation conversation);

  /// [post]'s replies, oldest first.
  Future<List<ChatMessage>> replies(
    ChatConversation conversation,
    ChatMessage post,
  );

  /// Sends [text], as a reply in [replyTo]'s thread when given, with
  /// [image] under it when given ([text] may then be empty). Each of
  /// [mentions] still written in [text] as `@displayName` goes as the
  /// provider's tag for that person (`splitMentions`); with none found the
  /// message is sent exactly as before.
  Future<ChatMessage> send(
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
    ChatOutgoingImage? image,
    List<ChatMember> mentions = const [],
  });

  /// The people who can be tagged with `@` in [conversation], each with the
  /// [ChatMember.userId] the provider's mention names them by — the
  /// conversation's members where the access NightMail holds can list them,
  /// else none (the caller adds whoever has written in it). May include the
  /// user, whom the caller leaves out.
  Future<List<ChatMember>> mentionable(ChatConversation conversation);

  /// Whether [send] takes an image in [conversation]: not on a NightMail
  /// Server, whose chat API has no hosted contents.
  bool canSendImage(ChatConversation conversation);

  /// Whether the user's own messages in [conversation] can be edited with the
  /// access this datasource holds — false for a Microsoft 365 channel, whose
  /// edits need `ChannelMessage.ReadWrite` (admin consent) on top of the
  /// read-and-send pair NightMail asks for.
  bool canEdit(ChatConversation conversation);

  /// Replaces [message]'s text with [text] — one of the user's own, with an
  /// [ChatMessage.editableText] — and returns it as edited: [message] with
  /// the new body, so reactions and replies the server does not echo stay.
  Future<ChatMessage> edit(
    ChatConversation conversation,
    ChatMessage message,
    String text,
  );

  /// Whether [conversation] can be renamed with the access this datasource
  /// holds: a group chat or a channel, never a one-on-one, and not where the
  /// provider wants more than NightMail asks for (a Microsoft 365 channel, a
  /// Google space).
  bool canRename(ChatConversation conversation);

  /// Renames [conversation] to [title] and returns it under its new
  /// [ChatConversation.title], as the list shows it.
  Future<ChatConversation> rename(ChatConversation conversation, String title);

  /// Whether anyone's messages in [conversation] can take a reaction from
  /// the user with the access this datasource holds.
  bool canReact(ChatConversation conversation);

  /// Adds the user's [emoji] reaction to [message] — a character, or a
  /// Slack workspace's own `:name:`. True when that added one; false when
  /// the server says the user had already given it, so the caller does not
  /// count it twice.
  Future<bool> react(
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  );

  /// Takes the user's own [emoji] reaction off [message]. True when one was
  /// removed; false when the server had none of the user's to remove.
  Future<bool> unreact(
    ChatConversation conversation,
    ChatMessage message,
    String emoji,
  );

  /// Creates (or returns the existing) one-on-one with [email].
  Future<ChatConversation> createOneOnOne({
    required String ownEmail,
    required String email,
    required String displayName,
  });

  /// Which of [emails] (lower-cased) the provider's own directory knows, or
  /// null where the account's organisation decides instead
  /// ([ChatRepository.colleagues]) — Slack, whose workspace has no tie to the
  /// mail account's domains, answers with `users.lookupByEmail`.
  Future<Set<String>?> directoryMembers(List<String> emails);

  /// Only when [searchesOnServer].
  Future<List<ChatSearchHit>> search(String query);

  /// The bytes of an `<img src>` in a message body this datasource built or
  /// the server sent, or null when there is nothing to show. An image on the
  /// account's own server goes with its token; anywhere else only over https
  /// and with no credentials.
  Future<Uint8List?> image(String src);

  /// The photo of the user a [ChatMessage.senderUserId] names, or null when
  /// they have none (or are outside the directory). Best effort: never throws.
  Future<Uint8List?> photo(String userId);
}
