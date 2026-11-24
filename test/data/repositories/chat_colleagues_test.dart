import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/chat_remote_datasource.dart';
import 'package:nightmail/data/repositories/chat_repository_impl.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/contact_cache_repository.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';

/// The Chat pane offers only colleagues: someone on one of the account's own
/// domains, or in its cached directory (a tenant with several domains). A
/// personal domain makes nobody a colleague.
void main() {
  ChatRepositoryImpl repo(
    Account account, {
    Set<String> directory = const {},
    List<ChatConversation> chats = const [],
  }) =>
      ChatRepositoryImpl(
        accountManager: _Accounts(account, _Chats(chats)),
        contacts: _Directory(directory),
      );

  final work = MicrosoftAccount(
    id: 'a',
    displayName: 'Work',
    emailAddress: 'me@contoso.com',
    aliases: const ['me@contoso.co.uk'],
    tenantId: 't',
  );

  test('own domains and aliases\' domains are colleagues', () async {
    final found = await repo(work).colleagues('a', [
      'Bob@Contoso.com',
      'ann@contoso.co.uk',
      'eve@fabrikam.com',
    ]);
    expect(found, {'bob@contoso.com', 'ann@contoso.co.uk'});
  });

  test('the cached directory adds the tenant\'s other domains', () async {
    final found = await repo(work, directory: {'kim@contoso-labs.com'})
        .colleagues('a', ['kim@contoso-labs.com', 'eve@fabrikam.com']);
    expect(found, {'kim@contoso-labs.com'});
  });

  test('a personal domain makes nobody a colleague', () async {
    final personal = MicrosoftAccount(
      id: 'p',
      displayName: 'Me',
      emailAddress: 'me@outlook.com',
      tenantId: 'consumers',
    );
    final found = await repo(personal).colleagues('p', ['you@outlook.com']);
    expect(found, isEmpty);
  });

  ChatConversation oneOnOne(String id, ChatMember other) => ChatConversation(
        id: id,
        kind: ChatKind.oneOnOne,
        title: other.displayName,
        members: [
          const ChatMember(displayName: 'Me', email: 'me@contoso.com'),
          other,
        ],
      );

  group('reachable', () {
    test('adds an outsider with an existing one-on-one', () async {
      final found = await repo(work, chats: [
        oneOnOne('1', const ChatMember(
            displayName: 'Eve', email: 'eve@fabrikam.com')),
      ]).reachable('a', [
        (email: 'bob@contoso.com', name: 'Bob'),
        (email: 'Eve@Fabrikam.com', name: 'Eve'),
        (email: 'zed@other.com', name: 'Zed'),
      ]);
      expect(found, {'bob@contoso.com', 'eve@fabrikam.com'});
    });

    test('a federated member without an address matches by name', () async {
      final r = repo(work, chats: [
        oneOnOne('1', const ChatMember(displayName: 'Eve Smith')),
      ]);
      expect(
          await r.reachable('a', [(email: 'eve@fabrikam.com', name: 'eve smith')]),
          {'eve@fabrikam.com'});
      final chat =
          await r.findOneOnOne('a', 'eve@fabrikam.com', name: 'Eve Smith');
      expect(chat.toNullable()?.id, '1');
    });

    test('two address-less chats sharing the name match neither', () async {
      final found = await repo(work, chats: [
        oneOnOne('1', const ChatMember(displayName: 'Sam Lee')),
        oneOnOne('2', const ChatMember(displayName: 'Sam Lee')),
      ]).reachable('a', [(email: 'sam@fabrikam.com', name: 'Sam Lee')]);
      expect(found, isEmpty);
    });

    test('a group chat does not make an outsider reachable', () async {
      final found = await repo(work, chats: [
        const ChatConversation(
          id: 'g',
          kind: ChatKind.group,
          title: 'Project',
          members: [ChatMember(displayName: 'Eve', email: 'eve@fabrikam.com')],
        ),
      ]).reachable('a', [(email: 'eve@fabrikam.com', name: 'Eve')]);
      expect(found, isEmpty);
    });
  });
}

class _Accounts extends Fake implements AccountManager {
  _Accounts(this.account, this.chats);

  final Account account;
  final ChatRemoteDatasource chats;

  @override
  Account? accountById(String? id) => id == account.id ? account : null;

  @override
  ChatRemoteDatasource? chatDatasourceForAccount(String accountId) => chats;

  @override
  Future<({bool chats, bool channels})?> chatGrants(String accountId) async =>
      (chats: true, channels: false);
}

/// A Graph-style datasource: one-on-ones are found by listing chats.
class _Chats extends Fake implements ChatRemoteDatasource {
  _Chats(this.chats);

  final List<ChatConversation> chats;

  @override
  bool get findsOneOnOneDirectly => false;

  @override
  Future<List<ChatConversation>> listChats() async => chats;
}

class _Directory extends Fake implements ContactCacheRepository {
  _Directory(this.members);

  final Set<String> members;

  @override
  Future<Set<String>> directoryAddresses({
    required String accountId,
    required Iterable<String> addresses,
  }) async =>
      addresses.where(members.contains).toSet();
}
