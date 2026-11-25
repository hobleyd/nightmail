import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/chat.dart';

/// What an account can do with chat right now.
enum ChatAccess {
  /// The provider has no chat NightMail can reach (Gmail, IMAP).
  unsupported,

  /// A Microsoft 365 account that has not yet consented to the chat scopes.
  needsConsent,

  /// Chats work; team channels have not been consented to (or the tenant's
  /// administrator has not approved `ChannelMessage.Read.All`).
  chatsOnly,

  /// Chats and channels.
  full,
}

/// Chats and team channels, for any account — every method names the account
/// it acts as, so the pane, the window and an account switch in between can
/// never act on the wrong one.
///
/// Graph-backed for Microsoft 365 and NightMail Server accounts alike; see
/// `docs/claude/chat.md`. A connected Slack workspace is named by its
/// [ChatSource.id] (`slack:{teamId}`) wherever an `accountId` is taken.
abstract interface class ChatRepository {
  /// The chat systems the Chat button offers with [accountId] active: the
  /// account's own chat when its provider has one, then every connected
  /// Slack workspace. [accountId] null gives the Slack workspaces alone.
  Future<List<ChatSource>> sources(String? accountId);

  /// Fires when a Slack workspace is connected, removed or needs
  /// reconnecting in this isolate.
  Stream<void> get sourcesChanged;

  /// Signs in to a Slack workspace through the internal Slack app
  /// [clientId] names, or reconnects one already listed.
  Future<Either<Failure, ChatSource>> connectSlack(String clientId);

  /// Forgets the Slack workspace [sourceId] and revokes its token.
  Future<void> disconnectSlack(String sourceId);

  /// The Slack app client id [sourceId] was connected with, for reconnecting
  /// it; null for anything else.
  Future<String?> slackClientId(String sourceId);

  Future<ChatAccess> access(String accountId);

  /// Runs the incremental consent for chats (and, with [channels], for team
  /// channels too). Returns the access the account ends up with.
  Future<Either<Failure, ChatAccess>> requestAccess(
    String accountId, {
    bool channels = false,
  });

  /// Every chat and (with channel access) every channel, newest activity
  /// first. Channels' activity is filled in as far as [channelActivity] has
  /// been asked.
  Future<Either<Failure, List<ChatConversation>>> conversations(
    String accountId, {
    bool refresh = false,
  });

  /// The list [conversations] last answered, from the encrypted cache on
  /// disk — what a window paints while the server is asked. Empty when
  /// nothing is cached.
  Future<List<ChatConversation>> cachedConversations(String accountId);

  /// [conversation] with [ChatConversation.lastActivity] read from its newest
  /// post; channels list without it.
  Future<Either<Failure, ChatConversation>> channelActivity(
    String accountId,
    ChatConversation conversation,
  );

  /// How many of the account's recent chats someone has written in since
  /// the user last read them — the dot on the Chat button. Zero for an
  /// account without chat access (never asks for consent) and on any error.
  Future<int> unreadCount(String accountId);

  /// The chats [unreadCount] counts, titled as the conversation list titles
  /// them, newest first.
  Future<List<ChatConversation>> unreadConversations(String accountId);

  /// Records [conversation] as read on the server. Best effort: a refusal
  /// leaves the dot until the chat is read elsewhere.
  Future<void> markRead(String accountId, ChatConversation conversation);

  /// Fires the account id whenever [markRead] has run here, so the dot can
  /// clear without waiting for its next poll.
  Stream<String> get reads;

  /// Each conversation read, by [ChatConversation.key]: [markRead] here
  /// (`here`), or [readElsewhere].
  Stream<({String accountId, String key, bool here})> get readKeys;

  /// A conversation read in the other window (its own isolate): counted read
  /// here until something newer arrives, as one [markRead] here is — the
  /// server's state may trail the mark, or a Slack channel stay unread there.
  void readElsewhere(String accountId, String key);

  /// The user's own id as [ChatMessage.senderUserId] carries it, or null.
  /// Google names it per space, hence [conversation].
  Future<String?> ownUserId(
    String accountId, {
    ChatConversation? conversation,
  });

  /// The one-on-one chat with [email], or null when there has never been one.
  /// Never creates one — that happens on the first [sendMessage] to a person.
  ///
  /// [name] finds a one-on-one whose other member has no address: Teams often
  /// leaves it off a federated (external) user. Only when exactly one such
  /// chat carries that name.
  Future<Either<Failure, ChatConversation?>> findOneOnOne(
    String accountId,
    String email, {
    String name = '',
  });

  /// Newest first. [nextLink] continues an earlier page.
  Future<Either<Failure, ChatMessagePage>> messages(
    String accountId,
    ChatConversation conversation, {
    String? nextLink,
  });

  /// What changed in [conversation] since [since] (a previous
  /// [ChatMessageDelta.watermark]); Right(null) when the provider cannot say,
  /// and [messages] has to be read instead.
  Future<Either<Failure, ChatMessageDelta?>> messagesSince(
    String accountId,
    ChatConversation conversation,
    DateTime since,
  );

  /// The newest messages last shown for [conversation], newest first, from
  /// the encrypted cache on disk. Empty when nothing is cached.
  Future<List<ChatMessage>> cachedMessages(
    String accountId,
    ChatConversation conversation,
  );

  /// Keeps [messages] (newest first) as what [conversation] last showed.
  Future<void> cacheMessages(
    String accountId,
    ChatConversation conversation,
    List<ChatMessage> messages,
  );

  /// Drops everything cached for a removed account.
  Future<void> forgetAccount(String accountId);

  /// A post's replies, oldest first (conversations with threads only).
  Future<Either<Failure, List<ChatMessage>>> replies(
    String accountId,
    ChatConversation conversation,
    ChatMessage post,
  );

  /// Sends [text] to [conversation], as a reply in [replyTo]'s thread when
  /// given (conversations with threads only).
  Future<Either<Failure, ChatMessage>> sendMessage(
    String accountId,
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
  });

  /// Whether the user's own messages in [conversation] can be edited — see
  /// `ChatRemoteDatasource.canEdit`.
  bool canEdit(String accountId, ChatConversation conversation);

  /// Changes the text of [message], one of the user's own, to [text], and
  /// returns it as edited.
  Future<Either<Failure, ChatMessage>> editMessage(
    String accountId,
    ChatConversation conversation,
    ChatMessage message,
    String text,
  );

  /// Creates the one-on-one chat with [email] and sends [text] to it.
  Future<Either<Failure, (ChatConversation, ChatMessage)>> startOneOnOne(
    String accountId,
    String email,
    String displayName,
    String text,
  );

  /// Which of [addresses] (lower-cased) belong to [accountId]'s organisation —
  /// the only people a chat can be started with. Local: the account's own
  /// domains and its cached directory, never a lookup per email.
  Future<Set<String>> colleagues(String accountId, Iterable<String> addresses);

  /// The bytes of an `<img src>` in a message body, or null when it cannot
  /// be shown. Remembered for the session, misses included.
  Future<Uint8List?> image(String accountId, String src);

  /// The photo of [userId] (a [ChatMessage.senderUserId]), or null when they
  /// have none. Remembered for the session, misses included.
  Future<Uint8List?> photo(String accountId, String userId);

  /// Which of [people] the Chat pane may offer: [colleagues], plus anyone
  /// outside the organisation the account already has a one-on-one with —
  /// a chat that exists has already passed the tenants' external-access
  /// rules, which no API lets a user check beforehand. Addresses come back
  /// lower-cased.
  Future<Set<String>> reachable(
    String accountId,
    List<({String email, String name})> people,
  );

  /// Messages matching [query] across every chat and channel the account can
  /// read, newest first.
  Future<Either<Failure, List<ChatSearchHit>>> search(
    String accountId,
    String query,
  );
}
