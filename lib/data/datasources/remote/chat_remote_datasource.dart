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

  /// [post]'s replies, oldest first.
  Future<List<ChatMessage>> replies(
    ChatConversation conversation,
    ChatMessage post,
  );

  /// Sends [text], as a reply in [replyTo]'s thread when given.
  Future<ChatMessage> send(
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
  });

  /// Creates (or returns the existing) one-on-one with [email].
  Future<ChatConversation> createOneOnOne({
    required String ownEmail,
    required String email,
    required String displayName,
  });

  /// Only when [searchesOnServer].
  Future<List<ChatSearchHit>> search(String query);
}
