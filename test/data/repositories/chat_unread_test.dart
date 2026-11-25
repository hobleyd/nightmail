import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/chat_remote_datasource.dart';
import 'package:nightmail/data/repositories/chat_repository_impl.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/slack/slack_workspaces.dart';

import '../../fakes/memory_secure_storage.dart';
import '../../fakes/memory_chat_local_datasource.dart';

/// The dot on the Chat button: counted from the cheap recent listing, never
/// for an account that has not consented (the poll must not prompt), and
/// cleared here as soon as a chat is marked read.
void main() {
  ChatConversation chat(String id, {bool unread = false}) => ChatConversation(
      id: id, kind: ChatKind.oneOnOne, title: id, unread: unread);

  test('counts the recent chats someone has written in', () async {
    final ds = _Chats([chat('a', unread: true), chat('b'), chat('c', unread: true)]);
    final repo = ChatRepositoryImpl(
        accountManager: _Accounts(ds, chats: true), contacts: _NoContacts(),
        slack: SlackWorkspaces(storage: MemorySecureStorage()),
        local: MemoryChatLocalDatasource());
    expect(await repo.unreadCount('acct'), 2);
  });

  test('an account without chat consent is never asked', () async {
    final ds = _Chats([chat('a', unread: true)]);
    final repo = ChatRepositoryImpl(
        accountManager: _Accounts(ds, chats: false), contacts: _NoContacts(),
        slack: SlackWorkspaces(storage: MemorySecureStorage()),
        local: MemoryChatLocalDatasource());
    expect(await repo.unreadCount('acct'), 0);
    expect(ds.listed, 0);
  });

  test('a chat marked here stays read until something newer arrives',
      () async {
    final before = DateTime.now().subtract(const Duration(minutes: 1));
    final later = DateTime.now().add(const Duration(minutes: 1));
    ChatConversation at(DateTime t) => ChatConversation(
        id: 'a', kind: ChatKind.oneOnOne, title: 'a',
        unread: true, lastActivity: t);
    final ds = _Chats([at(before)]);
    final repo = ChatRepositoryImpl(
        accountManager: _Accounts(ds, chats: true), contacts: _NoContacts(),
        slack: SlackWorkspaces(storage: MemorySecureStorage()),
        local: MemoryChatLocalDatasource());
    await repo.markRead('acct', at(before));
    expect(await repo.unreadCount('acct'), 0, reason: 'server lagging');

    ds.recent = [at(later)];
    expect(await repo.unreadCount('acct'), 1);
  });

  test('marking read tells the server and announces it', () async {
    final ds = _Chats(const []);
    final repo = ChatRepositoryImpl(
        accountManager: _Accounts(ds, chats: true), contacts: _NoContacts(),
        slack: SlackWorkspaces(storage: MemorySecureStorage()),
        local: MemoryChatLocalDatasource());
    final reads = repo.reads.first;
    await repo.markRead('acct', chat('a', unread: true));
    expect(ds.marked, ['a']);
    expect(await reads, 'acct');
  });
}

class _Accounts extends Fake implements AccountManager {
  _Accounts(this.ds, {required this.chats});

  final ChatRemoteDatasource ds;
  final bool chats;

  @override
  ChatRemoteDatasource? chatDatasourceForAccount(String accountId) => ds;

  @override
  Future<({bool chats, bool channels})?> chatGrants(String accountId) async =>
      (chats: chats, channels: false);
}

class _Chats extends Fake implements ChatRemoteDatasource {
  _Chats(this.recent);

  List<ChatConversation> recent;
  var listed = 0;
  final marked = <String>[];

  @override
  Future<List<ChatConversation>> listRecentChats() async {
    listed++;
    return recent;
  }

  @override
  Future<void> markRead(ChatConversation chat) async => marked.add(chat.id);
}

class _NoContacts extends Fake implements ContactCacheRepository {}
