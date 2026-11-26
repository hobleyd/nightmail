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

  group('marking read', () {
    test('a message that came in while away is marked once the user is back',
        () async {
      var foreground = true;
      final c = ChatConversationCubit(
          repository: repo, isForeground: () => foreground);
      addTearDown(c.close);
      repo.page = ChatMessagePage(messages: [msg('a', 1)]);
      await c.open('acct', chat);
      expect(repo.marked, ['c1'], reason: 'read on opening');

      foreground = false;
      repo.delta = ChatMessageDelta(
          messages: [msg('b', 2)], complete: true,
          watermark: t0.add(const Duration(minutes: 2)));
      await c.pollNow();
      expect(repo.marked, ['c1'], reason: 'not read while the app is away');

      foreground = true;
      repo.delta = const ChatMessageDelta(messages: [], complete: true);
      await c.pollNow();
      expect(repo.marked, ['c1', 'c1'],
          reason: 'nothing new arrived, but b is now on screen');
      await c.pollNow();
      expect(repo.marked, ['c1', 'c1'], reason: 'once per newest message');
    });

    // A Slack channel lit by a thread reply: its newest post can be the
    // user's own, or one already marked, so the posts alone mark nothing.
    const channel = ChatConversation(
        id: 'C1', kind: ChatKind.space, title: 'general', unread: true);
    ChatMessage mine(String id, int minute) => ChatMessage(
        id: id,
        createdAt: t0.add(Duration(minutes: minute)),
        senderName: 'Me',
        senderUserId: 'UME',
        bodyHtml: 'x');

    test('one listed unread is marked on opening, whoever wrote the newest',
        () async {
      final c = ChatConversationCubit(repository: repo, isForeground: () => true);
      addTearDown(c.close);
      repo.page = ChatMessagePage(messages: [mine('p', 1)]);
      await c.open('acct', channel);
      expect(repo.marked, ['C1']);
      repo.delta = const ChatMessageDelta(messages: [], complete: true);
      await c.pollNow();
      expect(repo.marked, ['C1'], reason: 'once');

      await c.open('acct', channel);
      expect(repo.marked, ['C1', 'C1'],
          reason: 'lit again by another reply, though the newest post was '
              'marked before');
    });

    test('a reply in the open thread newer than every post is marked',
        () async {
      final c = ChatConversationCubit(repository: repo, isForeground: () => true);
      addTearDown(c.close);
      repo.page = ChatMessagePage(messages: [msg('p', 1)]);
      await c.open('acct', channel.copyWith(unread: false));
      expect(repo.marked, ['C1']);

      repo.threadReplies = [mine('r1', 2)];
      await c.openThread('p');
      expect(repo.marked, ['C1'], reason: 'the user\'s own reply');

      repo.threadReplies = [mine('r1', 2), msg('r2', 3)];
      repo.delta = const ChatMessageDelta(messages: [], complete: true);
      await c.pollNow();
      await pumpEventQueue();
      expect(repo.marked, ['C1', 'C1']);
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

    test('the user\'s own comes off: one fewer, gone at none', () async {
      await opened([
        reacted('a', const [
          ChatReaction(emoji: '👍', count: 1, userIds: ['UME']),
          ChatReaction(emoji: '❤️', count: 2, userIds: ['UME', 'UANN']),
          ChatReaction(emoji: '🎉', count: 1, userIds: ['UANN']),
        ]),
      ]);
      await cubit.unreact(cubit.state.messages[0], '👍');
      await cubit.unreact(cubit.state.messages[0], '❤️');
      await cubit.unreact(cubit.state.messages[0], '🎉');
      expect(repo.unreactions, [('a', '👍'), ('a', '❤️')],
          reason: 'someone else\'s is not the user\'s to take off');
      expect(cubit.state.messages[0].reactions, const [
        ChatReaction(emoji: '❤️', count: 1, userIds: ['UANN']),
        ChatReaction(emoji: '🎉', count: 1, userIds: ['UANN']),
      ]);
      expect(repo.saved.single.reactions.length, 2, reason: 'cached');
    });

    test('a refusal to take it off is worded and leaves it', () async {
      await opened([
        reacted('a', const [
          ChatReaction(emoji: '👍', count: 1, userIds: ['UME']),
        ]),
      ]);
      repo.reactFailure = const ServerFailure(message: 'Connect again');
      await cubit.unreact(cubit.state.messages[0], '👍');
      expect(cubit.state.error, 'Could not remove the reaction: Connect again');
      expect(cubit.state.messages[0].reactions.single.count, 1);
    });

    test('a repeat the server reports marks it the user\'s, to take off',
        () async {
      // Google: the summary names no one, so only the server's 409 tells.
      await opened([
        reacted('a', const [ChatReaction(emoji: '👍', count: 1)]),
      ]);
      repo.reactAdds = false;
      await cubit.react(cubit.state.messages[0], '👍');
      final r = cubit.state.messages[0].reactions.single;
      expect(r.count, 1);
      expect(cubit.isOwnReaction(r), isTrue);
      await cubit.unreact(cubit.state.messages[0], '👍');
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

  group('calling from an avatar', () {
    const group =
        ChatConversation(id: 'g1', kind: ChatKind.group, title: 'Ann, Bob');
    ChatMessage from(String? id, {bool app = false, bool system = false}) =>
        ChatMessage(
          id: 'm-$id',
          createdAt: DateTime.utc(2026, 11, 26),
          senderName: 'Ann',
          senderUserId: id,
          bodyHtml: 'hi',
          senderIsApp: app,
          isSystem: system,
        );

    test('offered for other people only', () async {
      await cubit.open('acct', group);
      expect(cubit.callingFor(from('UANN')), ChatCalling.voiceAndVideo);
      expect(cubit.callingFor(from(cubit.state.ownUserId)), ChatCalling.none);
      expect(cubit.callingFor(from(null)), ChatCalling.none);
      expect(cubit.callingFor(from('BOT', app: true)), ChatCalling.none);
      expect(cubit.callingFor(from('UANN', system: true)), ChatCalling.none);
    });

    test('the link comes back; a refusal is worded instead', () async {
      await cubit.open('acct', group);
      expect(await cubit.callLink(from('UANN'), video: true),
          'call:UANN:video');
      expect(repo.calls.single.displayName, 'Ann');
      repo.callFailure = const ServerFailure(message: 'Calls are off');
      expect(await cubit.callLink(from('UANN'), video: false), isNull);
      expect(cubit.state.error, 'Could not call Ann: Calls are off');
    });

    test('permission is asked first where needed, and once', () async {
      repo.needsCallConsent = true;
      await cubit.open('acct', group);
      expect(await cubit.callNeedsConsent(), isTrue);
      expect(await cubit.callLink(from('UANN'), video: true), isNotNull);
      expect(await cubit.callLink(from('UANN'), video: true), isNotNull);
      expect(repo.consentsAsked, 1);
    });

    test('declined permission calls nobody', () async {
      repo
        ..needsCallConsent = true
        ..grantsCallConsent = false;
      await cubit.open('acct', group);
      expect(await cubit.callLink(from('UANN'), video: true), isNull);
      expect(repo.calls, isEmpty);
      expect(cubit.state.error, contains('Google Meet'));
    });

    test('moving to another conversation during consent calls nobody',
        () async {
      repo
        ..needsCallConsent = true
        ..duringConsent = () => cubit.open('acct',
            const ChatConversation(
                id: 'g2', kind: ChatKind.group, title: 'Other'));
      await cubit.open('acct', group);
      expect(await cubit.callLink(from('UANN'), video: true), isNull);
      expect(repo.calls, isEmpty);
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

  final marked = <String>[];

  List<ChatMessage> threadReplies = const [];

  @override
  Future<Either<Failure, List<ChatMessage>>> replies(String accountId,
          ChatConversation conversation, ChatMessage post) async =>
      Right(threadReplies);

  @override
  Future<void> markRead(
      String accountId, ChatConversation conversation) async {
    marked.add(conversation.id);
  }

  bool threadsChats = false;

  @override
  bool canThread(String accountId, ChatConversation conversation) =>
      conversation.hasThreads || threadsChats;

  bool reactable = true;
  bool reactAdds = true;
  Failure? reactFailure;
  final reactions = <(String, String)>[];

  @override
  bool canReact(String accountId, ChatConversation conversation) => reactable;

  final unreactions = <(String, String)>[];

  @override
  Future<Either<Failure, bool>> unreact(String accountId,
      ChatConversation conversation, ChatMessage message, String emoji) async {
    if (reactFailure != null) return Left(reactFailure!);
    unreactions.add((message.id, emoji));
    return const Right(true);
  }

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

  Failure? callFailure;
  final calls = <ChatMember>[];

  @override
  ChatCalling calling(String accountId) => ChatCalling.voiceAndVideo;

  bool needsCallConsent = false;
  bool grantsCallConsent = true;
  int consentsAsked = 0;

  /// Runs while the consent "sits in the browser".
  Future<void> Function()? duringConsent;

  @override
  Future<bool> callNeedsConsent(String accountId) async => needsCallConsent;

  @override
  Future<Either<Failure, bool>> requestCallConsent(String accountId) async {
    consentsAsked++;
    await duringConsent?.call();
    if (grantsCallConsent) needsCallConsent = false;
    return Right(grantsCallConsent);
  }

  @override
  Future<Either<Failure, String>> callLink(
    String accountId,
    ChatConversation conversation,
    ChatMember person, {
    required bool video,
  }) async {
    calls.add(person);
    if (callFailure != null) return Left(callFailure!);
    return Right('call:${person.userId}:${video ? 'video' : 'voice'}');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnimplementedError(invocation.memberName.toString());
}
