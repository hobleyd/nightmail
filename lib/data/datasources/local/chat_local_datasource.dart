import 'dart:convert';

import 'package:drift/drift.dart';

import '../../../domain/entities/chat.dart';
import '../../../infrastructure/cache/cache_encryption_service.dart';
import '../../database/app_database.dart';

/// What each chat system last showed, on disk: its conversation list and the
/// newest messages of each conversation opened, so the Chat pane and window
/// paint at once and the server only has to say what changed.
///
/// Keyed by the chat id every `ChatRepository` call takes — an email
/// account's id, or `slack:{team}`. Everything is one encrypted JSON blob per
/// list or conversation (`cached_chat_lists`, `cached_chat_messages`), the
/// way the mail cache keeps message content: nothing a person wrote is
/// readable in the file. Pagination cursors are never stored — Graph's
/// expire — so reading further back always starts from a fresh page.
abstract interface class ChatLocalDatasource {
  /// How many of a conversation's newest messages are kept.
  static const maxMessages = 100;

  /// Empty when nothing is cached (or the blob no longer decrypts).
  Future<List<ChatConversation>> conversations(String accountId);

  Future<void> saveConversations(
      String accountId, List<ChatConversation> conversations);

  /// Newest first; empty when nothing is cached.
  Future<List<ChatMessage>> messages(String accountId, String conversationKey);

  /// Keeps the newest [maxMessages] of [messages] (newest first) in place of
  /// whatever was there.
  Future<void> saveMessages(
      String accountId, String conversationKey, List<ChatMessage> messages);

  /// Everything cached for [accountId]: a removed account, a disconnected
  /// Slack workspace.
  Future<void> clear(String accountId);
}

class ChatLocalDatasourceImpl implements ChatLocalDatasource {
  ChatLocalDatasourceImpl({
    required AppDatabase database,
    required CacheEncryptionService encryption,
  })  : _db = database,
        _encryption = encryption; // ignore: prefer_initializing_formals

  final AppDatabase _db;
  final CacheEncryptionService _encryption;

  @override
  Future<List<ChatConversation>> conversations(String accountId) async {
    final row = await (_db.select(_db.cachedChatLists)
          ..where((t) => t.accountId.equals(accountId)))
        .getSingleOrNull();
    final list = await _decode(row?.encryptedData);
    return [
      for (final c in list)
        if (c is Map<String, dynamic>) conversationFromJson(c),
    ];
  }

  @override
  Future<void> saveConversations(
      String accountId, List<ChatConversation> conversations) async {
    final data = await _encryption.encrypt(
        jsonEncode([for (final c in conversations) conversationToJson(c)]));
    await _db.into(_db.cachedChatLists).insertOnConflictUpdate(
          CachedChatListsCompanion.insert(
            accountId: accountId,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            encryptedData: data,
          ),
        );
  }

  @override
  Future<List<ChatMessage>> messages(
      String accountId, String conversationKey) async {
    final row = await (_db.select(_db.cachedChatMessages)
          ..where((t) =>
              t.accountId.equals(accountId) &
              t.conversationKey.equals(conversationKey)))
        .getSingleOrNull();
    final list = await _decode(row?.encryptedData);
    return [
      for (final m in list)
        if (m is Map<String, dynamic>) messageFromJson(m),
    ];
  }

  @override
  Future<void> saveMessages(String accountId, String conversationKey,
      List<ChatMessage> messages) async {
    final data = await _encryption.encrypt(jsonEncode([
      for (final m in messages.take(ChatLocalDatasource.maxMessages))
        messageToJson(m),
    ]));
    await _db.into(_db.cachedChatMessages).insertOnConflictUpdate(
          CachedChatMessagesCompanion.insert(
            accountId: accountId,
            conversationKey: conversationKey,
            updatedAtMs: DateTime.now().millisecondsSinceEpoch,
            encryptedData: data,
          ),
        );
  }

  @override
  Future<void> clear(String accountId) async {
    await (_db.delete(_db.cachedChatLists)
          ..where((t) => t.accountId.equals(accountId)))
        .go();
    await (_db.delete(_db.cachedChatMessages)
          ..where((t) => t.accountId.equals(accountId)))
        .go();
  }

  /// A blob that will not decrypt — a key reset, a format from another
  /// version — is a cache miss, not an error: the server fills it again.
  Future<List<Object?>> _decode(String? stored) async {
    if (stored == null) return const [];
    try {
      final decoded = jsonDecode(await _encryption.decrypt(stored));
      return decoded is List ? decoded : const [];
    } catch (_) {
      return const [];
    }
  }

  // ---- JSON ---------------------------------------------------------------

  static Map<String, Object?> conversationToJson(ChatConversation c) => {
        'id': c.id,
        'kind': c.kind.name,
        'title': c.title,
        'teamId': ?c.teamId,
        'teamName': ?c.teamName,
        'lastActivity': ?c.lastActivity?.toIso8601String(),
        'preview': ?c.lastMessagePreview,
        if (c.members.isNotEmpty)
          'members': [
            for (final m in c.members)
              {
                'name': m.displayName,
                'userId': ?m.userId,
                'email': ?m.email,
              },
          ],
        if (c.threaded) 'threaded': true,
        if (c.unread) 'unread': true,
        if (c.noMessages) 'noMessages': true,
      };

  static ChatConversation conversationFromJson(Map<String, dynamic> j) =>
      ChatConversation(
        id: j['id'] as String,
        kind: ChatKind.values.asNameMap()[j['kind']] ?? ChatKind.group,
        title: j['title'] as String? ?? '',
        teamId: j['teamId'] as String?,
        teamName: j['teamName'] as String?,
        lastActivity: _date(j['lastActivity']),
        lastMessagePreview: j['preview'] as String?,
        members: [
          for (final m in (j['members'] as List?) ?? const [])
            if (m is Map)
              ChatMember(
                displayName: m['name'] as String? ?? '',
                userId: m['userId'] as String?,
                email: m['email'] as String?,
              ),
        ],
        threaded: j['threaded'] == true,
        unread: j['unread'] == true,
        noMessages: j['noMessages'] == true,
      );

  static Map<String, Object?> messageToJson(ChatMessage m) => {
        'id': m.id,
        'createdAt': m.createdAt.toIso8601String(),
        'sender': m.senderName,
        'senderId': ?m.senderUserId,
        'body': m.bodyHtml,
        'replyToId': ?m.replyToId,
        'subject': ?m.subject,
        'editedAt': ?m.editedAt?.toIso8601String(),
        if (m.isDeleted) 'deleted': true,
        if (m.isSystem) 'system': true,
        if (m.senderIsApp) 'app': true,
        if (m.reactions.isNotEmpty)
          'reactions': [
            for (final r in m.reactions)
              {
                'emoji': r.emoji,
                'count': r.count,
                'image': ?r.imageUrl,
                if (r.userIds.isNotEmpty) 'users': r.userIds,
              },
          ],
        if (m.replies.isNotEmpty)
          'replies': [for (final r in m.replies) messageToJson(r)],
        'replyCount': ?m.replyCount,
        if (m.attachmentNames.isNotEmpty) 'attachments': m.attachmentNames,
        'threadId': ?m.threadId,
        'editable': ?m.editableText,
      };

  static ChatMessage messageFromJson(Map<String, dynamic> j) => ChatMessage(
        id: j['id'] as String,
        createdAt: _date(j['createdAt']) ?? DateTime.fromMillisecondsSinceEpoch(0),
        senderName: j['sender'] as String? ?? '',
        senderUserId: j['senderId'] as String?,
        bodyHtml: j['body'] as String? ?? '',
        replyToId: j['replyToId'] as String?,
        subject: j['subject'] as String?,
        editedAt: _date(j['editedAt']),
        isDeleted: j['deleted'] == true,
        isSystem: j['system'] == true,
        senderIsApp: j['app'] == true,
        reactions: [
          for (final r in (j['reactions'] as List?) ?? const [])
            if (r is Map)
              ChatReaction(
                emoji: r['emoji'] as String? ?? '',
                count: (r['count'] as num?)?.toInt() ?? 1,
                imageUrl: r['image'] as String?,
                userIds: [
                  for (final u in (r['users'] as List?) ?? const [])
                    if (u is String) u,
                ],
              ),
        ],
        replies: [
          for (final r in (j['replies'] as List?) ?? const [])
            if (r is Map<String, dynamic>) messageFromJson(r),
        ],
        replyCount: (j['replyCount'] as num?)?.toInt(),
        attachmentNames: [
          for (final a in (j['attachments'] as List?) ?? const [])
            if (a is String) a,
        ],
        threadId: j['threadId'] as String?,
        editableText: j['editable'] as String?,
      );

  static DateTime? _date(Object? v) =>
      v is String ? DateTime.tryParse(v) : null;
}
