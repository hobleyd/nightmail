import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/presentation/blocs/chat/chat_conversation_cubit.dart';

/// Opening a conversation paints what the cache held, then joins the
/// server's newest page onto it; polls after that ask only what changed.
void main() {
  final t0 = DateTime.utc(2026, 11, 25, 9);

  ChatMessage msg(String id, int minute, {String body = 'x'}) => ChatMessage(
        id: id,
        createdAt: t0.add(Duration(minutes: minute)),
        senderName: 'Ann',
        senderUserId: 'UANN',
        bodyHtml: body,
      );

  const chat = ChatConversation(id: 'c1', kind: ChatKind.oneOnOne, title: 'Ann');

  late _Repo repo;
  late ChatConversationCubit cubit;

  setUp(() {
    repo = _Repo();
    cubit = ChatConversationCubit(repository: repo, isForeground: () => false);
  });

  tearDown(() => cubit.close());

  List<String> ids() => cubit.state.messages.map((m) => m.id).toList();

  group('opening', () {
    test('paints the cache before the server answers', () async {
      repo.cached = [msg('b', 2), msg('a', 1)];
      final page = repo.held = Completer();
      final opening = cubit.open('acct', chat);
      await pumpEventQueue();
      expect(ids(), ['b', 'a']);
      expect(cubit.state.loading, isFalse);
      page.complete(ChatMessagePage(
          messages: [msg('c', 3), msg('b', 2)], nextLink: 'more'));
      await opening;
      expect(ids(), ['c', 'b', 'a'], reason: 'joined where they meet');
      expect(repo.saved.map((m) => m.id), ['c', 'b', 'a']);
    });

    test('a page that does not reach the cache stands alone', () async {
      repo.cached = [msg('a', 1)];
      repo.page = ChatMessagePage(
          messages: [msg('z', 90), msg('y', 80)], nextLink: 'more');
      await cubit.open('acct', chat);
      expect(ids(), ['z', 'y'], reason: 'a gap must not look like nothing');
    });

    test('a page that is the whole history drops what was deleted', () {
      final page = ChatMessagePage(messages: [msg('b', 2)]);
      expect(ChatConversationCubit.joinCached(page, [msg('b', 2), msg('a', 1)])
          .map((m) => m.id), ['b']);
    });

    test('reading further back refreshes what the cache supplied', () async {
      repo.cached = [msg('b', 2), msg('a', 1, body: ':x:')];
      repo.page = ChatMessagePage(
          messages: [msg('c', 3), msg('b', 2)], nextLink: 'more');
      await cubit.open('acct', chat);
      expect(cubit.state.messages.last.bodyHtml, ':x:');
      repo.page = ChatMessagePage(messages: [msg('a', 1, body: 'now an emoji')]);
      await cubit.loadOlder();
      expect(ids(), ['c', 'b', 'a']);
      expect(cubit.state.messages.last.bodyHtml, 'now an emoji');
      expect(repo.saved.last.bodyHtml, 'now an emoji');
    });

    test('offline, the cache stands', () async {
      repo.cached = [msg('a', 1)];
      repo.pageFailure = const NetworkFailure(message: 'offline');
      await cubit.open('acct', chat);
      expect(ids(), ['a']);
      expect(cubit.state.error, contains('Offline'));
      expect(cubit.state.unavailable, isFalse);
    });
  });

  group('polling', () {
    test('asks for changes since the newest message the server sent',
        () async {
      repo.page = ChatMessagePage(messages: [msg('b', 2), msg('a', 1)]);
      await cubit.open('acct', chat);
      repo.delta = ChatMessageDelta(
          messages: [msg('c', 3)], watermark: t0.add(const Duration(minutes: 3)));
      await cubit.pollNow();
      expect(repo.since.single, t0.add(const Duration(minutes: 2, seconds: -1)));
      expect(ids(), ['c', 'b', 'a']);
      expect(repo.pagesRead, 1, reason: 'no full page for a delta');

      repo.delta = const ChatMessageDelta(messages: []);
      await cubit.pollNow();
      expect(repo.since.last, t0.add(const Duration(minutes: 3, seconds: -1)),
          reason: 'the server\'s watermark, not the device clock');
    });

    test('an edit replaces the message it edits', () async {
      repo.page = ChatMessagePage(messages: [msg('b', 2), msg('a', 1)]);
      await cubit.open('acct', chat);
      repo.delta = ChatMessageDelta(
          messages: [msg('a', 1, body: 'edited')], complete: true);
      await cubit.pollNow();
      expect(ids(), ['b', 'a']);
      expect(cubit.state.messages.last.bodyHtml, 'edited');
      expect(repo.saved.last.bodyHtml, 'edited');
    });

    test('a change to a message older than any shown is left for later',
        () async {
      repo.page =
          ChatMessagePage(messages: [msg('b', 2), msg('a', 1)], nextLink: 'more');
      await cubit.open('acct', chat);
      repo.delta = ChatMessageDelta(
          messages: [msg('c', 3), msg('old', -9000, body: 'reacted to')],
          complete: true);
      await cubit.pollNow();
      expect(ids(), ['c', 'b', 'a'],
          reason: 'an orphan below the history would hide the gap above it');
    });

    test('new-messages-only deltas still read a full page now and then',
        () async {
      repo.page = ChatMessagePage(messages: [msg('a', 1)]);
      await cubit.open('acct', chat);
      repo.delta = const ChatMessageDelta(messages: []);
      for (var i = 0; i < ChatConversationCubit.fullPageEvery; i++) {
        await cubit.pollNow();
      }
      expect(repo.pagesRead, 2);
      expect(repo.since, hasLength(ChatConversationCubit.fullPageEvery - 1));
    });

    test('complete deltas never need a full page', () async {
      repo.page = ChatMessagePage(messages: [msg('a', 1)]);
      await cubit.open('acct', chat);
      repo.delta = const ChatMessageDelta(messages: [], complete: true);
      for (var i = 0; i < ChatConversationCubit.fullPageEvery * 2; i++) {
        await cubit.pollNow();
      }
      expect(repo.pagesRead, 1);
    });

    test('where no delta can be asked, each poll reads the page', () async {
      repo.page = ChatMessagePage(messages: [msg('a', 1)]);
      await cubit.open('acct', chat);
      repo.delta = null;
      repo.page = ChatMessagePage(messages: [msg('b', 2), msg('a', 1)]);
      await cubit.pollNow();
      expect(repo.pagesRead, 2);
      expect(ids(), ['b', 'a']);
    });
  });
}

class _Repo implements ChatRepository {
  List<ChatMessage> cached = const [];
  ChatMessagePage page = const ChatMessagePage(messages: []);
  Failure? pageFailure;
  ChatMessageDelta? delta;
  List<ChatMessage> saved = const [];
  final since = <DateTime>[];
  int pagesRead = 0;

  /// Set to keep the next page from arriving until it is completed.
  Completer<ChatMessagePage>? held;

  @override
  Future<Either<Failure, ChatMessagePage>> messages(
    String accountId,
    ChatConversation conversation, {
    String? nextLink,
  }) async {
    pagesRead++;
    if (pageFailure != null) return Left(pageFailure!);
    final hold = held;
    if (hold != null) {
      held = null;
      return Right(await hold.future);
    }
    return Right(page);
  }

  @override
  Future<Either<Failure, ChatMessageDelta?>> messagesSince(
    String accountId,
    ChatConversation conversation,
    DateTime since,
  ) async {
    this.since.add(since);
    return Right(delta);
  }

  @override
  Future<List<ChatMessage>> cachedMessages(
          String accountId, ChatConversation conversation) async =>
      cached;

  @override
  Future<void> cacheMessages(String accountId, ChatConversation conversation,
      List<ChatMessage> messages) async {
    saved = messages;
  }

  @override
  Future<String?> ownUserId(String accountId,
          {ChatConversation? conversation}) async =>
      'UME';

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
