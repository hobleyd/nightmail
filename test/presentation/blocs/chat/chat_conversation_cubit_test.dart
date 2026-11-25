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

  group('editing', () {
    ChatMessage mine(String id, int minute, {String? text = 'typo'}) =>
        ChatMessage(
          id: id,
          createdAt: t0.add(Duration(minutes: minute)),
          senderName: 'Me',
          senderUserId: 'UME',
          bodyHtml: text ?? 'x',
          editableText: text,
        );

    Future<void> opened(List<ChatMessage> messages) async {
      repo.page = ChatMessagePage(messages: messages);
      await cubit.open('acct', chat);
      await pumpEventQueue();
      expect(cubit.state.ownUserId, 'UME');
    }

    test('only the user\'s own, editable messages offer it', () async {
      await opened([mine('m2', 2), msg('a', 1), mine('m0', 0, text: null)]);
      expect(cubit.canEdit(cubit.state.messages[0]), isTrue);
      expect(cubit.canEdit(cubit.state.messages[1]), isFalse,
          reason: 'someone else\'s');
      expect(cubit.canEdit(cubit.state.messages[2]), isFalse,
          reason: 'plain text cannot say it again');
      repo.editable = false;
      expect(cubit.canEdit(cubit.state.messages[0]), isFalse,
          reason: 'the provider cannot edit here');
    });

    test('send while editing replaces the text in place, then sends again',
        () async {
      await opened([mine('m2', 2), msg('a', 1), mine('m0', 0)]);
      expect(cubit.lastEditable(inThread: false)?.id, 'm2');
      cubit.startEdit(cubit.state.messages[2]);
      expect(cubit.state.editing?.id, 'm0');
      expect(await cubit.saveEdit('  fixed '), isTrue);
      expect(repo.edits, [('m0', 'fixed')]);
      expect(cubit.state.editing, isNull);
      expect(ids(), ['m2', 'a', 'm0'], reason: 'it keeps its place');
      final m0 = cubit.state.messages[2];
      expect(m0.bodyHtml, '<i>fixed</i>');
      expect(m0.editedAt, isNotNull);
      expect(repo.saved[2].bodyHtml, '<i>fixed</i>', reason: 'cached');
    });

    test('an unchanged edit just closes; a refused one stays open', () async {
      await opened([mine('m2', 2)]);
      cubit.startEdit(cubit.state.messages[0]);
      expect(await cubit.saveEdit('typo'), isTrue);
      expect(repo.edits, isEmpty);
      expect(cubit.state.editing, isNull);

      repo.editFailure = const ServerFailure(message: 'Too late to edit');
      cubit.startEdit(cubit.state.messages[0]);
      expect(await cubit.saveEdit('better'), isFalse);
      expect(cubit.state.editing?.id, 'm2');
      expect(cubit.state.error, contains('Too late to edit'));
      cubit.cancelEdit();
      expect(cubit.state.editing, isNull);
    });

    test('opening another conversation leaves the edit', () async {
      await opened([mine('m2', 2)]);
      cubit.startEdit(cubit.state.messages[0]);
      await cubit.open('acct',
          const ChatConversation(id: 'c2', kind: ChatKind.group, title: 'G'));
      expect(cubit.state.editing, isNull);
    });
  });

  group('reactions', () {
    Future<void> opened(List<ChatMessage> messages) async {
      repo.page = ChatMessagePage(messages: messages);
      await cubit.open('acct', chat);
      await pumpEventQueue();
      expect(cubit.state.ownUserId, 'UME');
    }

    ChatMessage reacted(String id, List<ChatReaction> reactions) => ChatMessage(
          id: id,
          createdAt: t0,
          senderName: 'Ann',
          senderUserId: 'UANN',
          bodyHtml: 'hi',
          reactions: reactions,
        );

    test('anyone\'s message takes one, counted once the server has it',
        () async {
      await opened([msg('a', 1)]);
      expect(cubit.canReact(cubit.state.messages[0]), isTrue);
      await cubit.react(cubit.state.messages[0], '🎉');
      await cubit.react(cubit.state.messages[0], '🎉');
      expect(repo.reactions, [('a', '🎉')],
          reason: 'the second is the user\'s own already there');
      final r = cubit.state.messages[0].reactions.single;
      expect(r, const ChatReaction(emoji: '🎉', count: 1, userIds: ['UME']));
      expect(cubit.isOwnReaction(r), isTrue);
      expect(repo.saved.single.reactions.single.count, 1, reason: 'cached');
    });

    test('joins someone else\'s reaction; never doubles the user\'s own',
        () async {
      await opened([
        reacted('a', const [
          ChatReaction(emoji: '👍', count: 1, userIds: ['UANN']),
          ChatReaction(emoji: '❤️', count: 2, userIds: ['UME', 'UANN']),
        ]),
      ]);
      await cubit.react(cubit.state.messages[0], '👍');
      await cubit.react(cubit.state.messages[0], '❤️');
      expect(repo.reactions, [('a', '👍')]);
      expect(cubit.state.messages[0].reactions.map((r) => r.count), [2, 2]);
    });

    test('a reply in the open thread takes it there too', () async {
      const channel = ChatConversation(
          id: 'ch', kind: ChatKind.channel, title: 'G', teamId: 'T');
      final reply = ChatMessage(
          id: 'r1',
          createdAt: t0,
          senderName: 'Ann',
          bodyHtml: 'ok',
          replyToId: 'p1');
      repo.page = ChatMessagePage(messages: [
        ChatMessage(
            id: 'p1',
            createdAt: t0,
            senderName: 'Ann',
            bodyHtml: 'post',
            replies: [reply]),
      ]);
      await cubit.open('acct', channel);
      await cubit.react(reply, '👀');
      expect(
          cubit.state.messages.single.replies.single.reactions.single.emoji,
          '👀');
    });

    test('a repeat the server reports is not counted', () async {
      await opened([msg('a', 1)]);
      repo.reactAdds = false;
      await cubit.react(cubit.state.messages[0], '👍');
      expect(repo.reactions, [('a', '👍')]);
      expect(cubit.state.messages[0].reactions, isEmpty);
    });

    test('a refusal is worded and changes nothing', () async {
      await opened([msg('a', 1)]);
      repo.reactFailure = const ServerFailure(message: 'Connect again');
      await cubit.react(cubit.state.messages[0], '👍');
      expect(cubit.state.error, 'Could not add the reaction: Connect again');
      expect(cubit.state.messages[0].reactions, isEmpty);
    });

    test('not offered on a deleted message or where the provider cannot',
        () async {
      await opened([
        ChatMessage(
            id: 'd',
            createdAt: t0,
            senderName: '',
            bodyHtml: '',
            isDeleted: true),
        msg('a', 1),
      ]);
      expect(cubit.canReact(cubit.state.messages[0]), isFalse);
      repo.reactable = false;
      expect(cubit.canReact(cubit.state.messages[1]), isFalse);
    });
  });

  group('renaming', () {
    const group =
        ChatConversation(id: 'g1', kind: ChatKind.group, title: 'Ann, Bob');

    test('the open conversation takes its new title', () async {
      await cubit.open('acct', group);
      expect(cubit.canRename, isTrue);
      expect(await cubit.rename('  Launch '), isNull);
      expect(repo.renames, [('g1', 'Launch')]);
      expect(cubit.state.conversation?.title, 'Launch');
      expect(cubit.state.conversation?.key, 'g1');
    });

    test('a refusal is worded and changes nothing; empty is not sent',
        () async {
      await cubit.open('acct', group);
      expect(await cubit.rename('   '), isNotNull);
      repo.renameFailure =
          const ServerFailure(message: 'Only owners can rename it');
      expect(await cubit.rename('Launch'), contains('Only owners'));
      expect(repo.renames, [('g1', 'Launch')]);
      expect(cubit.state.conversation?.title, 'Ann, Bob');
    });

    test('not offered where the provider cannot', () async {
      repo.renamable = false;
      await cubit.open('acct', group);
      expect(cubit.canRename, isFalse);
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

  bool reactable = true;
  bool reactAdds = true;
  Failure? reactFailure;
  final reactions = <(String, String)>[];

  @override
  bool canReact(String accountId, ChatConversation conversation) => reactable;

  @override
  Future<Either<Failure, bool>> react(String accountId,
      ChatConversation conversation, ChatMessage message, String emoji) async {
    if (reactFailure != null) return Left(reactFailure!);
    reactions.add((message.id, emoji));
    return Right(reactAdds);
  }

  bool editable = true;
  Failure? editFailure;
  final edits = <(String, String)>[];

  @override
  bool canEdit(String accountId, ChatConversation conversation) => editable;

  @override
  Future<Either<Failure, ChatMessage>> editMessage(
    String accountId,
    ChatConversation conversation,
    ChatMessage message,
    String text,
  ) async {
    edits.add((message.id, text));
    if (editFailure != null) return Left(editFailure!);
    return Right(message.withEdit(
      bodyHtml: '<i>$text</i>',
      editableText: text,
      editedAt: DateTime.utc(2026, 11, 25, 12),
    ));
  }

  bool renamable = true;
  Failure? renameFailure;
  final renames = <(String, String)>[];

  @override
  bool canRename(String accountId, ChatConversation conversation) =>
      renamable;

  @override
  Future<Either<Failure, ChatConversation>> renameConversation(
    String accountId,
    ChatConversation conversation,
    String title,
  ) async {
    renames.add((conversation.id, title));
    if (renameFailure != null) return Left(renameFailure!);
    return Right(conversation.copyWith(title: title));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
