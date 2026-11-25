import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/presentation/blocs/chat/chat_list_cubit.dart';

/// The chat window's list: bold only where something is unread, which only
/// the unread poll knows, and newest first or by name.
void main() {
  ChatConversation chat(String id, String title, int day, {bool? unread}) =>
      ChatConversation(
        id: id,
        kind: ChatKind.group,
        title: title,
        lastActivity: DateTime.utc(2026, 11, day),
        unread: unread ?? false,
      );

  late _Repo repo;
  late ChatListCubit cubit;

  setUp(() {
    repo = _Repo();
    cubit = ChatListCubit(repository: repo);
  });

  tearDown(() => cubit.close());

  Map<String, bool> unread() =>
      {for (final c in cubit.state.conversations) c.id: c.unread};

  test('only what the unread poll names is unread', () async {
    // Graph's listing says unread from its own viewpoint, Slack's never
    // does; the poll (marks made here included) decides for both.
    repo.list = [chat('a', 'Ann', 3, unread: true), chat('b', 'Bob', 2)];
    repo.unread = [chat('b', 'Bob', 2, unread: true)];
    await cubit.load('acct');
    await pumpEventQueue();
    expect(unread(), {'a': false, 'b': true});
  });

  test('opening an unread chat un-bolds it at once', () async {
    repo.list = [chat('b', 'Bob', 2)];
    repo.unread = [chat('b', 'Bob', 2, unread: true)];
    await cubit.load('acct');
    await pumpEventQueue();
    cubit.select('b');
    expect(unread(), {'b': false});
  });

  test('sections sort by name when asked', () async {
    // Newest first, as the repository lists them.
    repo.list = [chat('z', 'zed', 9), chat('m', 'Mia', 5), chat('a', 'Ann', 1)];
    await cubit.load('acct');
    expect(cubit.state.chats.map((c) => c.title), ['zed', 'Mia', 'Ann']);
    cubit.setSortByName(true);
    expect(cubit.state.chats.map((c) => c.title), ['Ann', 'Mia', 'zed']);
    cubit.setSortByName(false);
    expect(cubit.state.chats.map((c) => c.title), ['zed', 'Mia', 'Ann']);
  });

  test('a Slack lookup that fails is asked again next poll, once done never',
      () async {
    const dm = ChatConversation(id: 'D1', kind: ChatKind.oneOnOne, title: 'Akash');
    repo.list = [dm];
    repo.refuse.add('D1');
    await cubit.load('slack:T1');
    await pumpEventQueue();
    expect(repo.looked, ['D1']);
    await cubit.refresh();
    await pumpEventQueue();
    expect(repo.looked, ['D1', 'D1']);
    await cubit.refresh();
    await pumpEventQueue();
    expect(repo.looked, ['D1', 'D1']);
  });

  test('quiet after a week or when not known, unless unread or open', () {
    final now = DateTime.utc(2026, 11, 25);
    const state = ChatListState(selectedKey: 'open');
    expect(state.isQuiet(chat('new', 'New', 20), now), isFalse);
    expect(state.isQuiet(chat('old', 'Old', 10), now), isTrue);
    expect(state.isQuiet(chat('u', 'Unread', 10, unread: true), now), isFalse);
    expect(state.isQuiet(chat('open', 'Open', 10), now), isFalse);
    // Made yesterday, never written in.
    expect(
        state.isQuiet(
            const ChatConversation(id: 'e', kind: ChatKind.meeting,
                    title: 'Sync', noMessages: true)
                .copyWith(),
            now),
        isTrue);
    // Its first message ends that.
    expect(
        const ChatConversation(
                id: 'e', kind: ChatKind.meeting, title: 'Sync',
                noMessages: true)
            .copyWith(lastMessagePreview: 'hi')
            .noMessages,
        isFalse);
    expect(
        state.isQuiet(
            const ChatConversation(
                id: 'ch', kind: ChatKind.channel, title: 'General',
                teamId: 't'),
            now),
        isTrue);
  });
}

class _Repo implements ChatRepository {
  List<ChatConversation> list = const [];
  List<ChatConversation> unread = const [];

  @override
  Future<List<ChatConversation>> cachedConversations(String accountId) async =>
      const [];

  @override
  Future<ChatAccess> access(String accountId) async => ChatAccess.chatsOnly;

  @override
  Future<Either<Failure, List<ChatConversation>>> conversations(
    String accountId, {
    bool refresh = false,
  }) async =>
      Right(list);

  @override
  Future<List<ChatConversation>> unreadConversations(String accountId) async =>
      unread;

  /// Each lookup's key, and whether the next one of each is refused.
  final looked = <String>[];
  final refuse = <String>{};

  @override
  Future<Either<Failure, ChatConversation>> channelActivity(
      String accountId, ChatConversation conversation) async {
    looked.add(conversation.key);
    if (refuse.remove(conversation.key)) {
      return const Left(ServerFailure(message: 'ratelimited'));
    }
    return Right(conversation);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
