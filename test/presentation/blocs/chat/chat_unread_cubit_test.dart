import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/sync/change_stream_service.dart';
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
        reason: 'the chats themselves, for the pane\'s unread list');
    expect(c.state.hasChoice, isTrue);
    expect(c.state.chosen, teams, reason: 'the account\'s own chat first');
  });

  test('an unread Slack channel lights the dot, as on Slack\'s dock icon — '
      'the pane\'s unread list already showed it', () async {
    final c = await cubit(const [teams, slack],
        unread: const {'work': 1, 'slack:T1': 2}, kind: ChatKind.space);
    expect(c.state.unreadIn('slack:T1'), 2);
    expect(c.state.total, 3);
    expect(c.state.unreadChats['slack:T1'], hasLength(2));
    expect(c.state.unreadIn('work'), 1);
  });

  test('picking a system points the pane at it', () async {
    final c = await cubit(const [teams, slack]);
    c.choose('slack:T1');
    expect(c.state.chosen, slack);
  });

  group('change stream', () {
    late StreamController<ChangeSignal> signals;
    late _Repo repo;
    late ChatUnreadCubit c;

    setUp(() async {
      signals = StreamController<ChangeSignal>.broadcast();
      repo = _Repo(const [teams, slack], const {'work': 1}, ChatKind.oneOnOne);
      c = ChatUnreadCubit(
        accountManager: _Accounts(),
        repository: repo,
        changeSignals: signals.stream,
      )..start();
      await pumpEventQueue();
    });

    tearDown(() async {
      await c.close();
      await signals.close();
    });

    test('a chat signal for the account refreshes at once, not at the next '
        'poll', () async {
      final before = repo.listings;
      signals.add(const ChangeSignal('work', {'chat'}));
      await pumpEventQueue();
      expect(repo.listings, greaterThan(before));
    });

    test('so does a (re)connected stream that watches chat — nothing in '
        'between was signalled', () async {
      final before = repo.listings;
      signals.add(const ChangeSignal('work', {'mail', 'chat'}, isReady: true));
      await pumpEventQueue();
      expect(repo.listings, greaterThan(before));
    });

    test('mail, calendar, an older server without chat, or another account '
        'leave it to the timer', () async {
      final before = repo.listings;
      signals
        ..add(const ChangeSignal('work', {'mail', 'calendar'}))
        ..add(const ChangeSignal('work', {'mail', 'calendar'}, isReady: true))
        ..add(const ChangeSignal('other', {'chat'}));
      await pumpEventQueue();
      expect(repo.listings, before);
    });
  });

  test('a chat read in the chat window drops out here, without a re-poll',
      () async {
    final repo = _Repo(const [teams, slack], const {'slack:T1': 2},
        ChatKind.space);
    final c = ChatUnreadCubit(accountManager: _Accounts(), repository: repo);
    c.start();
    await c.refresh();
    final polled = repo.listings;
    repo.readEvents
        .add((accountId: 'slack:T1', key: 'slack:T1-0', here: false));
    await pumpEventQueue();
    expect(c.state.unreadIn('slack:T1'), 1);
    expect(c.state.unreadChats['slack:T1']!.map((x) => x.key), ['slack:T1-1']);
    expect(repo.listings, polled);
    await c.close();
  });

  test('a chat read in this window drops out at once, before the server '
      'answers', () async {
    final repo = _Repo(const [teams, slack], const {'slack:T1': 2},
        ChatKind.space);
    final c = ChatUnreadCubit(accountManager: _Accounts(), repository: repo);
    c.start();
    await c.refresh();
    repo.readEvents
        .add((accountId: 'slack:T1', key: 'slack:T1-0', here: true));
    await pumpEventQueue();
    expect(c.state.unreadChats['slack:T1']!.map((x) => x.key), ['slack:T1-1']);
    expect(c.state.unreadIn('slack:T1'), 1);
    await c.close();
  });

  test('a chat read here lingers below the unread ones for readLinger, not '
      'bold and not counted, then goes', () {
    fakeAsync((async) {
      final repo = _Repo(const [teams, slack], const {'slack:T1': 2},
          ChatKind.space);
      final c = ChatUnreadCubit(accountManager: _Accounts(), repository: repo)
        ..start();
      async.flushMicrotasks();
      repo.readEvents
          .add((accountId: 'slack:T1', key: 'slack:T1-0', here: true));
      async.flushMicrotasks();
      expect(c.state.unreadIn('slack:T1'), 1);
      final read = c.state.recentlyRead['slack:T1']!;
      expect(read.map((x) => x.key), ['slack:T1-0']);
      expect(read.single.unread, isFalse);

      // A poll in the meantime (which no longer lists it) keeps it.
      repo.markedRead.add('slack:T1-0');
      unawaited(c.refresh());
      async.flushMicrotasks();
      expect(c.state.recentlyRead['slack:T1']!.map((x) => x.key),
          ['slack:T1-0']);

      async.elapse(ChatUnreadCubit.readLinger);
      expect(c.state.recentlyRead['slack:T1'], isEmpty);
      unawaited(c.close());
    });
  });

  test('a lingering chat that is unread again leaves the read ones', () {
    fakeAsync((async) {
      final repo = _Repo(const [teams, slack], const {'slack:T1': 2},
          ChatKind.space);
      final c = ChatUnreadCubit(accountManager: _Accounts(), repository: repo)
        ..start();
      async.flushMicrotasks();
      repo.readEvents
          .add((accountId: 'slack:T1', key: 'slack:T1-0', here: true));
      async.flushMicrotasks();
      // The poll still lists it unread — someone followed up.
      unawaited(c.refresh());
      async.flushMicrotasks();
      expect(c.state.unreadIn('slack:T1'), 2);
      expect(c.state.recentlyRead['slack:T1'], isEmpty);
      unawaited(c.close());
    });
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

  /// Keys the repository counts read, as after `markRead`.
  final markedRead = <String>{};

  /// How many times unread chats were listed — once per system a refresh.
  int listings = 0;

  @override
  Future<List<ChatSource>> sources(String? accountId) async => _sources;

  @override
  Stream<String> get reads => const Stream.empty();

  final readEvents =
      StreamController<({String accountId, String key, bool here})>.broadcast();

  @override
  Stream<({String accountId, String key, bool here})> get readKeys =>
      readEvents.stream;

  @override
  void readElsewhere(String accountId, String key) {}

  @override
  Stream<void> get sourcesChanged => const Stream.empty();

  @override
  Future<List<ChatConversation>> unreadConversations(String accountId) async {
    listings++;
    return [
      for (var i = 0; i < (_unread[accountId] ?? 0); i++)
        if (!markedRead.contains('$accountId-$i'))
          ChatConversation(
              id: '$accountId-$i', kind: _kind, title: 'Chat $i', unread: true),
    ];
  }
}
