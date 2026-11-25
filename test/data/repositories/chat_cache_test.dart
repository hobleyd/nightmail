import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/chat_remote_datasource.dart';
import 'package:nightmail/data/repositories/chat_repository_impl.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/slack/slack_workspaces.dart';

import '../../fakes/memory_chat_local_datasource.dart';
import '../../fakes/memory_secure_storage.dart';

/// The repository's side of the chat cache: what a listing lacks, the cache
/// on disk supplies; a server that refuses deltas is asked for pages from
/// then on; a removed account leaves nothing behind.
void main() {
  late _Chats ds;
  late MemoryChatLocalDatasource local;
  late ChatRepository repo;

  setUp(() {
    ds = _Chats();
    local = MemoryChatLocalDatasource();
    repo = ChatRepositoryImpl(
      accountManager: _Accounts(ds),
      contacts: _NoContacts(),
      slack: SlackWorkspaces(storage: MemorySecureStorage()),
      local: local,
    );
  });

  test('a listing without activity takes what the cache last knew', () async {
    final seen = DateTime.utc(2026, 11, 20);
    local.lists['acct'] = [
      ChatConversation(
          id: 'old',
          kind: ChatKind.group,
          title: 'Old',
          lastActivity: seen,
          lastMessagePreview: 'last week'),
    ];
    ds.chats = const [
      ChatConversation(id: 'new', kind: ChatKind.group, title: 'A new one'),
      ChatConversation(id: 'old', kind: ChatKind.group, title: 'Old'),
    ];
    final list = (await repo.conversations('acct', refresh: true))
        .getOrElse((f) => fail(f.message));
    expect(list.map((c) => c.id), ['old', 'new'],
        reason: 'sorted by the cached activity, not by name');
    expect(list.first.lastMessagePreview, 'last week');
  });

  test('a sent picture shows from the pasted bytes, not a fetch that could '
      'miss while the server processes it', () async {
    final bytes = Uint8List.fromList([1, 2, 3]);
    const chat = ChatConversation(id: 'c', kind: ChatKind.group, title: 'G');
    await repo.sendMessage('acct', chat, 'look',
        image: ChatOutgoingImage(
            bytes: bytes, mimeType: 'image/png', name: 'a.png'));
    expect(await repo.image('acct', 'https://x/a?b=1&c=2'), bytes);
    expect(ds.imagesFetched, isEmpty);
  });

  test('a rename retitles the listed conversation without moving it',
      () async {
    ds.chats = [
      ChatConversation(
          id: 'a',
          kind: ChatKind.group,
          title: 'A',
          lastActivity: DateTime.utc(2026, 11, 25)),
      ChatConversation(
          id: 'b',
          kind: ChatKind.group,
          title: 'B',
          lastActivity: DateTime.utc(2026, 11, 24)),
    ];
    await repo.conversations('acct', refresh: true);
    final renamed = (await repo.renameConversation(
            'acct', ds.chats.last, 'Launch'))
        .getOrElse((f) => fail(f.message));
    expect(renamed.title, 'Launch');
    final list = (await repo.conversations('acct'))
        .getOrElse((f) => fail(f.message));
    expect(list.map((c) => (c.id, c.title)), [('a', 'A'), ('b', 'Launch')]);
    expect(ds.listed, 1);
  });

  test('activity looked up before a rename never brings the old name back',
      () async {
    const channel =
        ChatConversation(id: 'c', kind: ChatKind.space, title: '#general');
    ds.chats = const [channel];
    await repo.conversations('acct', refresh: true);
    await repo.channelActivity('acct', channel);
    await repo.renameConversation('acct', channel, '#releases');
    ds.chats = const [
      ChatConversation(id: 'c', kind: ChatKind.space, title: '#releases'),
    ];
    final list = (await repo.conversations('acct', refresh: true))
        .getOrElse((f) => fail(f.message));
    expect(list.single.title, '#releases');
    expect(list.single.lastActivity, DateTime.utc(2026, 11, 25, 8),
        reason: 'the activity learned is still kept');

    // An activity lookup that began before the rename lands after it.
    await repo.channelActivity('acct', channel);
    final again = (await repo.conversations('acct'))
        .getOrElse((f) => fail(f.message));
    expect(again.single.title, '#releases');
  });

  test('before the server answers, the cached list is what there is',
      () async {
    local.lists['acct'] = const [
      ChatConversation(id: 'c', kind: ChatKind.group, title: 'C'),
    ];
    expect((await repo.cachedConversations('acct')).single.id, 'c');
    expect(ds.listed, 0);
  });

  test('after a restart, a cached one-on-one opens without waiting',
      () async {
    local.lists['acct'] = const [
      ChatConversation(
        id: 'dm',
        kind: ChatKind.oneOnOne,
        title: 'Ann',
        members: [ChatMember(displayName: 'Ann', email: 'ann@x.test')],
      ),
    ];
    ds.hold = Completer();
    final found = (await repo.findOneOnOne('acct', 'Ann@x.test'))
        .getOrElse((f) => fail(f.message));
    expect(found?.id, 'dm');
    expect(ds.listed, 0, reason: 'answered before anything was listed');
    await pumpEventQueue();
    expect(ds.listed, 1, reason: 'the listing refreshes behind it');
    ds.hold!.complete();
  });

  test('someone not in the cached list is looked for on the server',
      () async {
    ds.chats = const [
      ChatConversation(
        id: 'dm2',
        kind: ChatKind.oneOnOne,
        title: 'Bob',
        members: [ChatMember(displayName: 'Bob', email: 'bob@x.test')],
      ),
    ];
    final found = (await repo.findOneOnOne('acct', 'bob@x.test'))
        .getOrElse((f) => fail(f.message));
    expect(found?.id, 'dm2');
  });

  test('unread chats are titled as the full list titles them', () async {
    local.lists['acct'] = const [
      ChatConversation(
        id: 'dm',
        kind: ChatKind.oneOnOne,
        title: 'Ann',
        members: [ChatMember(displayName: 'Ann', email: 'ann@x.test')],
      ),
    ];
    ds.recent = [
      ChatConversation(
          id: 'dm',
          kind: ChatKind.oneOnOne,
          title: 'Chat',
          lastActivity: DateTime.utc(2026, 11, 25),
          unread: true),
      const ChatConversation(id: 'read', kind: ChatKind.group, title: 'R'),
    ];
    final unread = await repo.unreadConversations('acct');
    expect(unread.map((c) => (c.title, c.unread)), [('Ann', true)]);
    expect(unread.single.members.single.email, 'ann@x.test');
    expect(await repo.unreadCount('acct'), 1);
  });

  test('a server that refuses a delta is not asked again', () async {
    const c = ChatConversation(id: 'c', kind: ChatKind.group, title: 'C');
    ds.deltaError = const ServerException(message: 'no', statusCode: 400);
    expect((await repo.messagesSince('acct', c, DateTime(2026))).isRight(),
        isTrue);
    expect((await repo.messagesSince('acct', c, DateTime(2026)))
        .getOrElse((_) => fail('')), isNull);
    expect(ds.deltasAsked, 1);
  });

  test('a delta that fails for another reason is a failure, asked again',
      () async {
    const c = ChatConversation(id: 'c', kind: ChatKind.group, title: 'C');
    ds.deltaError = const NetworkException(message: 'offline');
    expect((await repo.messagesSince('acct', c, DateTime(2026))).isLeft(),
        isTrue);
    await repo.messagesSince('acct', c, DateTime(2026));
    expect(ds.deltasAsked, 2);
  });

  test('a removed account leaves nothing cached', () async {
    const c = ChatConversation(id: 'c', kind: ChatKind.group, title: 'C');
    await repo.cacheMessages('acct', c, [
      ChatMessage(
          id: 'm', createdAt: DateTime(2026), senderName: 'A', bodyHtml: 'x'),
    ]);
    local.lists['acct'] = const [c];
    await repo.forgetAccount('acct');
    expect(await repo.cachedMessages('acct', c), isEmpty);
    expect(await repo.cachedConversations('acct'), isEmpty);
  });
}

class _Accounts extends Fake implements AccountManager {
  _Accounts(this.ds);

  final ChatRemoteDatasource ds;

  @override
  ChatRemoteDatasource? chatDatasourceForAccount(String accountId) => ds;

  @override
  Future<({bool chats, bool channels})?> chatGrants(String accountId) async =>
      (chats: true, channels: false);
}

class _Chats extends Fake implements ChatRemoteDatasource {
  List<ChatConversation> chats = const [];
  var listed = 0;
  Exception? deltaError;
  var deltasAsked = 0;

  /// Holds the listing back, to show nothing waits for it.
  Completer<void>? hold;

  List<ChatConversation> recent = const [];

  @override
  Future<List<ChatConversation>> listRecentChats() async => recent;

  @override
  bool get findsOneOnOneDirectly => false;

  @override
  Future<List<ChatConversation>> listChats() async {
    listed++;
    await hold?.future;
    return chats;
  }

  @override
  Future<ChatConversation> channelActivity(ChatConversation channel) async =>
      channel.copyWith(
          lastActivity: DateTime.utc(2026, 11, 25, 8),
          lastMessagePreview: 'hi');

  final imagesFetched = <String>[];

  @override
  Future<Uint8List?> image(String src) async {
    imagesFetched.add(src);
    return null;
  }

  @override
  Future<ChatMessage> send(
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
    ChatOutgoingImage? image,
  }) async =>
      ChatMessage(
        id: 'm',
        createdAt: DateTime.utc(2026, 11, 25, 9),
        senderName: 'Me',
        bodyHtml: '<p>$text</p><img data-emoji src="https://e/x.png" '
            'alt=":x:"><img src="https://x/a?b=1&amp;c=2" alt="a.png">',
      );

  @override
  Future<ChatConversation> rename(
          ChatConversation conversation, String title) async =>
      conversation.copyWith(title: title);

  @override
  Future<ChatMessageDelta?> messagesSince(
      ChatConversation conversation, DateTime since) async {
    deltasAsked++;
    if (deltaError != null) throw deltaError!;
    return const ChatMessageDelta(messages: []);
  }
}

class _NoContacts extends Fake implements ContactCacheRepository {}
