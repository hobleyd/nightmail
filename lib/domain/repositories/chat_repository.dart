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
/// `docs/claude/chat.md`.
abstract interface class ChatRepository {
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

  /// [conversation] with [ChatConversation.lastActivity] read from its newest
  /// post; channels list without it.
  Future<Either<Failure, ChatConversation>> channelActivity(
    String accountId,
    ChatConversation conversation,
  );

  /// The one-on-one chat with [email], or null when there has never been one.
  /// Never creates one — that happens on the first [sendMessage] to a person.
  Future<Either<Failure, ChatConversation?>> findOneOnOne(
    String accountId,
    String email,
  );

  /// Newest first. [nextLink] continues an earlier page.
  Future<Either<Failure, ChatMessagePage>> messages(
    String accountId,
    ChatConversation conversation, {
    String? nextLink,
  });

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

  /// Messages matching [query] across every chat and channel the account can
  /// read, newest first.
  Future<Either<Failure, List<ChatSearchHit>>> search(
    String accountId,
    String query,
  );
}
