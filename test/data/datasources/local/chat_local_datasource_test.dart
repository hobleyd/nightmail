import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/database/app_database.dart';
import 'package:nightmail/data/datasources/local/chat_local_datasource.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/infrastructure/cache/cache_encryption_service.dart';

/// Reversible but unreadable, so a test can tell the blob went through it.
class _ReversingEncryption extends CacheEncryptionService {
  _ReversingEncryption() : super(const FlutterSecureStorage());

  @override
  Future<void> initialize() async {}

  @override
  Future<String> encrypt(String plaintext) async =>
      'enc:${String.fromCharCodes(plaintext.runes.toList().reversed)}';

  @override
  Future<String> decrypt(String stored) async {
    if (!stored.startsWith('enc:')) throw const FormatException('not ours');
    return String.fromCharCodes(stored.substring(4).runes.toList().reversed);
  }
}

/// A chat system's list and each conversation's newest messages, kept
/// encrypted on disk so the Chat pane and window paint before the server
/// answers.
void main() {
  late AppDatabase db;
  late ChatLocalDatasourceImpl ds;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    ds = ChatLocalDatasourceImpl(
        database: db, encryption: _ReversingEncryption());
  });

  tearDown(() => db.close());

  final post = ChatMessage(
    id: 'p1',
    createdAt: DateTime.utc(2026, 11, 20, 9),
    senderName: 'Ann',
    senderUserId: 'UANN',
    bodyHtml: '<b>Launch</b> notes',
    subject: 'Launch',
    editedAt: DateTime.utc(2026, 11, 20, 10),
    reactions: const [ChatReaction(emoji: '👍🏼', count: 2)],
    replies: [
      ChatMessage(
        id: 'r1',
        createdAt: DateTime.utc(2026, 11, 20, 11),
        senderName: 'Bob',
        bodyHtml: 'ok',
        replyToId: 'p1',
        editableText: 'ok',
      ),
    ],
    replyCount: 4,
    attachmentNames: const ['plan.pdf'],
    threadId: 'spaces/A/threads/1',
  );

  test('a conversation\'s messages come back as they went in', () async {
    await ds.saveMessages('slack:T1', 'C1', [post]);
    expect(await ds.messages('slack:T1', 'C1'), [post]);
    expect(await ds.messages('slack:T1', 'C2'), isEmpty);
  });

  test('a list comes back as it went in, members and all', () async {
    final list = [
      ChatConversation(
        id: 'c1',
        kind: ChatKind.oneOnOne,
        title: 'Ann',
        lastActivity: DateTime.utc(2026, 11, 20, 9),
        lastMessagePreview: 'hi',
        members: const [
          ChatMember(displayName: 'Ann', userId: 'u1', email: 'ann@x.test'),
        ],
        unread: true,
      ),
      const ChatConversation(
        id: 'ch1',
        kind: ChatKind.channel,
        title: 'General',
        teamId: 't1',
        teamName: 'Eng',
      ),
      const ChatConversation(
          id: 'spaces/A', kind: ChatKind.space, title: 'A', threaded: true),
    ];
    await ds.saveConversations('acct', list);
    expect(await ds.conversations('acct'), list);
  });

  test('nothing a person wrote is readable in the file', () async {
    await ds.saveMessages('acct', 'c1', [post]);
    await ds.saveConversations('acct', [
      const ChatConversation(
          id: 'c1', kind: ChatKind.group, title: 'Launch crew'),
    ]);
    final rows = [
      ...(await db.select(db.cachedChatMessages).get())
          .map((r) => r.encryptedData),
      ...(await db.select(db.cachedChatLists).get())
          .map((r) => r.encryptedData),
    ];
    expect(rows, hasLength(2));
    for (final blob in rows) {
      expect(blob, startsWith('enc:'));
      expect(blob, isNot(contains('Launch')));
    }
  });

  test('only the newest are kept', () async {
    final many = [
      for (var i = 0; i < ChatLocalDatasource.maxMessages + 20; i++)
        ChatMessage(
          id: '$i',
          createdAt: DateTime.utc(2026).subtract(Duration(minutes: i)),
          senderName: 'Ann',
          bodyHtml: 'm$i',
        ),
    ];
    await ds.saveMessages('acct', 'c1', many);
    final kept = await ds.messages('acct', 'c1');
    expect(kept, hasLength(ChatLocalDatasource.maxMessages));
    expect(kept.first.id, '0');
  });

  test('a blob that no longer decrypts is a miss, not an error', () async {
    await db.into(db.cachedChatMessages).insert(
          CachedChatMessagesCompanion.insert(
            accountId: 'acct',
            conversationKey: 'c1',
            updatedAtMs: 0,
            encryptedData: 'from another key',
          ),
        );
    expect(await ds.messages('acct', 'c1'), isEmpty);
  });

  test('clearing an account leaves the others', () async {
    await ds.saveMessages('acct', 'c1', [post]);
    await ds.saveMessages('slack:T1', 'C1', [post]);
    await ds.saveConversations('acct', const [
      ChatConversation(id: 'c1', kind: ChatKind.group, title: 'x'),
    ]);
    await ds.clear('acct');
    expect(await ds.messages('acct', 'c1'), isEmpty);
    expect(await ds.conversations('acct'), isEmpty);
    expect(await ds.messages('slack:T1', 'C1'), [post]);
  });
}
