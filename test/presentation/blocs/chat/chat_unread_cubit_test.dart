import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/presentation/blocs/chat/chat_unread_cubit.dart';

/// The Chat button's model: the systems, unread per system, and whether a
/// pick from its menu switched an open pane rather than closing it.
void main() {
  const teams =
      ChatSource(id: 'work', kind: ChatSourceKind.teams, label: 'Teams');
  const slack = ChatSource(
      id: 'slack:T1', kind: ChatSourceKind.slack, label: 'Slack · Acme');

  Future<ChatUnreadCubit> cubit(List<ChatSource> sources,
      {Map<String, int> unread = const {},
      ChatKind kind = ChatKind.oneOnOne}) async {
    final c = ChatUnreadCubit(
      accountManager: _Accounts(),
      repository: _Repo(sources, unread, kind),
    );
    await c.refresh();
    return c;
  }

  test('counts each system and adds them up for the dot', () async {
    final c = await cubit(const [teams, slack],
        unread: const {'work': 1, 'slack:T1': 2});
    expect(c.state.unreadIn('slack:T1'), 2);
    expect(c.state.total, 3);
    expect(c.state.unreadChats['slack:T1']!.map((c) => c.title),
        ['Chat 0', 'Chat 1'],
        reason: 'the chats themselves, for the pane\'s dropdown');
    expect(c.state.hasChoice, isTrue);
    expect(c.state.chosen, teams, reason: 'the account\'s own chat first');
  });

  test('an unread Slack channel is offered but leaves the dot alone, as on '
      'Slack\'s badge; a Google space still counts', () async {
    final c = await cubit(const [teams, slack],
        unread: const {'work': 1, 'slack:T1': 2}, kind: ChatKind.space);
    expect(c.state.unreadIn('slack:T1'), 0);
    expect(c.state.unreadChats['slack:T1'], hasLength(2));
    expect(c.state.unreadIn('work'), 1);
  });

  test('picking another system switches; picking the same one toggles',
      () async {
    final c = await cubit(const [teams, slack]);
    c.choose('slack:T1');
    expect(c.takeSwitched(), isTrue);
    expect(c.takeSwitched(), isFalse, reason: 'read once');
    c.choose('slack:T1');
    expect(c.takeSwitched(), isFalse);
    expect(c.state.chosen, slack);
  });

  test('without a menu nothing is ever switched — the plain toggle',
      () async {
    final c = await cubit(const [teams]);
    expect(c.takeSwitched(), isFalse);
  });

  test('a choice no longer offered falls back to the first', () async {
    final c = await cubit(const [teams, slack]);
    c.choose('slack:T9');
    expect(c.state.chosen, teams);
  });
}

class _Accounts extends Fake implements AccountManager {
  @override
  Account? get activeAccount => null;
}

class _Repo extends Fake implements ChatRepository {
  _Repo(this._sources, this._unread, this._kind);

  final List<ChatSource> _sources;
  final Map<String, int> _unread;
  final ChatKind _kind;

  @override
  Future<List<ChatSource>> sources(String? accountId) async => _sources;

  @override
  Future<List<ChatConversation>> unreadConversations(String accountId) async =>
      [
        for (var i = 0; i < (_unread[accountId] ?? 0); i++)
          ChatConversation(
              id: '$accountId-$i',
              kind: _kind,
              title: 'Chat $i',
              unread: true),
      ];
}
