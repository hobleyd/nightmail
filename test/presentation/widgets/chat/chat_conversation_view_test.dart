import 'dart:async';


import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/presentation/blocs/chat/chat_conversation_cubit.dart';
import 'package:nightmail/presentation/blocs/chat/chat_drafts.dart';
import 'package:nightmail/presentation/widgets/chat/chat_call_menu.dart';
import 'package:nightmail/presentation/widgets/chat/chat_conversation_view.dart';
import 'package:nightmail/presentation/widgets/chat/chat_person_style.dart';

/// Who is talking shows at a glance: each run of one sender's messages
/// starts with their avatar, and each person's bubbles wear their colour.
void main() {
  ChatMessage msg(String id, String who, String userId, int minute) =>
      ChatMessage(
        id: id,
        createdAt: DateTime(2026, 11, 25, 10, minute),
        senderName: who,
        senderUserId: userId,
        bodyHtml: '<p>message $id</p>',
      );

  testWidgets('one avatar per run of a sender, photo asked once per person',
      (tester) async {
    final repo = _Repo([
      // Newest first.
      msg('4', 'Bob Brown', 'u-bob', 4),
      msg('3', 'Ann Lee', 'u-ann', 3),
      msg('2', 'Ann Lee', 'u-ann', 2),
      msg('1', 'Ann Lee', 'u-ann', 1),
    ]);
    final cubit = ChatConversationCubit(repository: repo);
    await cubit.open('a', const ChatConversation(
        id: 'c', kind: ChatKind.group, title: 'G'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlocProvider.value(
          value: cubit,
          child: const ChatConversationView(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.byType(ChatAvatar), findsNWidgets(2));
    expect(find.text('AL'), findsOneWidget);
    expect(find.text('BB'), findsOneWidget);
    expect(repo.photosAsked, {'u-ann', 'u-bob'});
    final bubbles = tester
        .widgetList<Container>(find.byType(Container))
        .map((c) => c.decoration)
        .whereType<BoxDecoration>()
        .map((d) => d.color)
        .where((c) => c != null)
        .toSet();
    // Ann's and Bob's bubbles differ, whatever their hashes.
    expect(bubbles.length, greaterThanOrEqualTo(2));
    await cubit.close();
  });

  group('calling from an avatar', () {
    Future<(_Repo, ChatConversationCubit, List<String>)> pump(
        WidgetTester tester, ChatCalling calling) async {
      final repo = _Repo([
        msg('2', 'Bob Brown', 'u-bob', 2),
        msg('1', 'Ann Lee', 'u-ann', 1),
      ])
        ..callingAs = calling;
      final launched = <String>[];
      final original = ChatCallableAvatar.launch;
      ChatCallableAvatar.launch = (link) async => launched.add(link);
      addTearDown(() => ChatCallableAvatar.launch = original);
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open('a',
          const ChatConversation(id: 'c', kind: ChatKind.group, title: 'G'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const ChatConversationView(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (repo, cubit, launched);
    }

    testWidgets('voice or video; the chosen one is asked for and handed over',
        (tester) async {
      final (repo, cubit, launched) =
          await pump(tester, ChatCalling.voiceAndVideo);
      await tester.tap(find.text('AL'));
      await tester.pumpAndSettle();
      expect(find.text('Voice call Ann Lee'), findsOneWidget);
      await tester.tap(find.text('Video call Ann Lee'));
      await tester.pumpAndSettle();
      expect(repo.callsAsked, [('u-ann', true)]);
      expect(launched, ['https://call.example/u-ann?video=true']);
      await cubit.close();
    });

    testWidgets('Slack offers one huddle', (tester) async {
      final (repo, cubit, launched) = await pump(tester, ChatCalling.huddle);
      await tester.tap(find.text('BB'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Voice call'), findsNothing);
      await tester.tap(find.text('Start a huddle with Bob Brown in Slack'));
      await tester.pumpAndSettle();
      expect(repo.callsAsked, [('u-bob', false)]);
      expect(launched, hasLength(1));
      await cubit.close();
    });

    testWidgets('Google: one Meet item, said first that Google will ask',
        (tester) async {
      final (repo, cubit, launched) = await pump(tester, ChatCalling.meet);
      repo.needsCallConsent = true;
      await tester.tap(find.text('AL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start a Google Meet and send Ann Lee the link'));
      await tester.pumpAndSettle();
      expect(find.text('Allow Google Meet calls?'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.callsAsked, isEmpty);

      await tester.tap(find.text('AL'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Start a Google Meet and send Ann Lee the link'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Continue'));
      await tester.pumpAndSettle();
      expect(repo.callsAsked, [('u-ann', true)]);
      expect(launched, hasLength(1));
      await cubit.close();
    });

    testWidgets('nothing offered where the system cannot call',
        (tester) async {
      final (repo, cubit, _) = await pump(tester, ChatCalling.none);
      await tester.tap(find.text('AL'));
      await tester.pumpAndSettle();
      expect(find.textContaining('call'), findsNothing);
      expect(repo.callsAsked, isEmpty);
      await cubit.close();
    });
  });

  test('everyone in a conversation gets their own colour, the same each time',
      () {
    final people = [
      for (var i = 0; i < ChatPersonStyle.hues.length; i++) 'u-$i',
    ];
    final slots = ChatPersonStyle.assign(people, own: 'u-3');
    expect(slots.values.toSet().length, ChatPersonStyle.hues.length);
    expect(ChatPersonStyle.assign(people.reversed, own: 'u-3'), slots);
    // A one-on-one is the list's first two: blue (you) and orange.
    expect(ChatPersonStyle.assign(['u-ann', 'u-bob'], own: 'u-bob'),
        {'u-bob': 0, 'u-ann': 1});
  });

  test('your colour is the same in every conversation, and nobody else\'s',
      () {
    for (final others in [
      ['u-ann'],
      ['u-ann', 'u-bob', 'u-cy'],
      [for (var i = 0; i < 25; i++) 'u-$i'],
    ]) {
      final slots = ChatPersonStyle.assign([...others, 'u-me'], own: 'u-me');
      expect(slots['u-me'], ChatPersonStyle.ownSlot);
      expect(
          others.map((o) => slots[o]), everyElement(isNot(ChatPersonStyle.ownSlot)));
    }
    // Before your id is known, nobody else takes your colour either.
    expect(ChatPersonStyle.assign(['u-ann', 'u-bob']).values,
        everyElement(isNot(ChatPersonStyle.ownSlot)));
  });

  testWidgets('a deleted message is one line, with no sender', (tester) async {
    final repo = _Repo([
      msg('2', 'Ann Lee', 'u-ann', 2),
      ChatMessage(
        id: '1',
        createdAt: DateTime(2026, 11, 25, 10, 1),
        senderName: '',
        bodyHtml: '',
        isDeleted: true,
      ),
    ]);
    final cubit = ChatConversationCubit(repository: repo);
    await cubit.open('a', const ChatConversation(
        id: 'c', kind: ChatKind.group, title: 'G'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlocProvider.value(
          value: cubit,
          child: const ChatConversationView(),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('Deleted message'), findsOneWidget);
    expect(find.text('Unknown'), findsNothing);
    expect(find.text('This message was deleted.'), findsNothing);
    // Ann's message after it still heads its own run.
    expect(find.byType(ChatAvatar), findsOneWidget);
    await cubit.close();
  });

  group('reading a chat', () {
    const chat = ChatConversation(id: 'c', kind: ChatKind.group, title: 'G');

    test('marks it read when someone else wrote last, once per message',
        () async {
      final repo = _Repo([msg('2', 'Ann Lee', 'u-ann', 2)], ownId: 'u-me');
      final cubit = ChatConversationCubit(
          repository: repo, isForeground: () => true);
      await cubit.open('a', chat);
      expect(cubit.state.ownUserId, 'u-me');
      expect(repo.marked, ['c']);

      await cubit.open('a', chat);
      expect(repo.marked, ['c'], reason: 'same newest message');
      await cubit.close();
    });

    test('leaves it alone when the last message is yours, or a channel',
        () async {
      final repo = _Repo([msg('2', 'Me', 'u-me', 2)], ownId: 'u-me');
      final cubit = ChatConversationCubit(
          repository: repo, isForeground: () => true);
      await cubit.open('a', chat);
      expect(repo.marked, isEmpty);

      final channels = _Repo([msg('2', 'Ann Lee', 'u-ann', 2)], ownId: 'u-me');
      final inChannel = ChatConversationCubit(
          repository: channels, isForeground: () => true);
      await inChannel.open('a', const ChatConversation(
          id: 'ch', kind: ChatKind.channel, title: 'General', teamId: 't'));
      expect(channels.marked, isEmpty);
      await cubit.close();
      await inChannel.close();
    });

    test('waits while the app is in the background', () async {
      final repo = _Repo([msg('2', 'Ann Lee', 'u-ann', 2)], ownId: 'u-me');
      var foreground = false;
      final cubit = ChatConversationCubit(
          repository: repo, isForeground: () => foreground);
      await cubit.open('a', chat);
      expect(repo.marked, isEmpty);

      foreground = true;
      await cubit.open('a', chat);
      expect(repo.marked, ['c']);
      await cubit.close();
    });
  });

  group('replying in a chat', () {
    const dm =
        ChatConversation(id: 'D1', kind: ChatKind.oneOnOne, title: 'Ann Lee');

    Future<(_Repo, ChatConversationCubit)> pump(WidgetTester tester,
        {required bool slack, bool wide = false}) async {
      final repo = _Repo([msg('1', 'Ann Lee', 'u-ann', 1)], ownId: 'u-me')
        ..threadsChats = slack;
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open('a', dm);
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: ChatConversationView(wideThreads: wide),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (repo, cubit);
    }

    testWidgets('a Slack DM\'s message opens its thread like a post; the '
        'reply goes there and is counted', (tester) async {
      final (repo, cubit) = await pump(tester, slack: true);
      expect(find.byType(ChatAvatar), findsOneWidget,
          reason: 'still a chat\'s bubbles, not post cards');
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.text('Thread'), findsOneWidget);
      expect(find.byTooltip('Back to messages'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'on it');
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(repo.sent, [('on it', '1')]);
      expect(cubit.state.threadReplies.map((m) => m.bodyHtml), ['on it']);
      await tester.tap(find.byTooltip('Back to messages'));
      await tester.pumpAndSettle();
      expect(find.text('1 reply'), findsOneWidget);
      expect(cubit.state.messages.map((m) => m.id), ['1'],
          reason: 'the reply is in the thread, not the DM');
      await cubit.close();
    });

    testWidgets('beside an open thread, the list\'s box writes to the DM',
        (tester) async {
      final (repo, cubit) = await pump(tester, slack: true, wide: true);
      await tester.tap(find.text('Reply'));
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNWidgets(2));
      await tester.enterText(find.byType(TextField).first, 'new topic');
      await tester.tap(find.byTooltip('Send').first);
      await tester.pumpAndSettle();
      expect(repo.sent, [('new topic', null)]);
      expect(cubit.state.threadReplies, isEmpty);
      await cubit.close();
    });

    for (final wide in [false, true]) {
      testWidgets('Reply puts the caret in the thread\'s box '
          '(${wide ? 'beside the list' : 'in place of it'})', (tester) async {
        final (_, cubit) = await pump(tester, slack: true, wide: wide);
        await tester.tap(find.text('Reply'));
        await tester.pumpAndSettle();
        final box = find.byType(TextField).last;
        expect(tester.widget<TextField>(box).decoration!.hintText, 'Reply');
        expect(tester.widget<TextField>(box).focusNode!.hasFocus, isTrue);
        await cubit.close();
      });
    }

    testWidgets('a Teams chat has no threads: no Reply', (tester) async {
      final (_, cubit) = await pump(tester, slack: false);
      expect(find.text('Reply'), findsNothing);
      await cubit.close();
    });
  });

  group('reactions', () {
    Future<(_Repo, ChatConversationCubit)> pump(
        WidgetTester tester, ChatMessage m) async {
      final repo = _Repo([m], ownId: 'u-me');
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open('a',
          const ChatConversation(id: 'c', kind: ChatKind.group, title: 'G'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const ChatConversationView(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (repo, cubit);
    }

    double opacityOf(WidgetTester tester) => tester
        .widget<Opacity>(find
            .ancestor(
                of: find.byTooltip('Add reaction'),
                matching: find.byType(Opacity))
            .first)
        .opacity;

    testWidgets('someone else\'s message: the hover button\'s menu adds one',
        (tester) async {
      final (repo, cubit) = await pump(tester, msg('1', 'Ann Lee', 'u-ann', 1));
      expect(find.byTooltip('Edit'), findsNothing);
      expect(opacityOf(tester), 0, reason: 'shown on hover, like the pencil');
      final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await mouse.addPointer(location: Offset.zero);
      await mouse.moveTo(tester.getCenter(find.text('message 1')));
      await tester.pumpAndSettle();
      expect(opacityOf(tester), 1);

      await tester.tap(find.byTooltip('Add reaction'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('🎉'));
      await tester.pumpAndSettle();
      expect(repo.reactions, [('1', '🎉')]);
      expect(find.text('🎉'), findsOneWidget, reason: 'the chip, menu closed');
      await mouse.removePointer();
      await cubit.close();
    }, variant: TargetPlatformVariant.only(TargetPlatform.macOS));

    testWidgets('a touch screen has no hover: a long press offers them',
        (tester) async {
      final (repo, cubit) = await pump(tester, msg('1', 'Ann Lee', 'u-ann', 1));
      expect(find.byTooltip('Add reaction'), findsNothing);
      await tester.longPress(find.text('message 1'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('🙏'));
      await tester.pumpAndSettle();
      expect(repo.reactions, [('1', '🙏')]);
      await cubit.close();
    });

    testWidgets('tapping someone\'s reaction adds the user\'s; tapping '
        'their own takes it off', (tester) async {
      final (repo, cubit) = await pump(
        tester,
        ChatMessage(
          id: '1',
          createdAt: DateTime(2026, 11, 25, 10),
          senderName: 'Ann Lee',
          senderUserId: 'u-ann',
          bodyHtml: 'hi',
          reactions: const [
            ChatReaction(emoji: '👍', count: 1, userIds: ['u-ann']),
            ChatReaction(emoji: '❤️', count: 1, userIds: ['u-me']),
          ],
        ),
      );
      await tester.tap(find.text('👍'));
      await tester.pumpAndSettle();
      expect(repo.reactions, [('1', '👍')]);
      expect(find.text('👍 2'), findsOneWidget);
      await tester.tap(find.text('❤️'));
      await tester.pumpAndSettle();
      expect(repo.reactions, [('1', '👍')]);
      expect(repo.unreactions, [('1', '❤️')]);
      expect(find.text('❤️'), findsNothing, reason: 'it was the only one');
      await cubit.close();
    });
  });

  group('editing', () {
    ChatMessage mine(String id, String text, int minute) => ChatMessage(
          id: id,
          createdAt: DateTime(2026, 11, 25, 10, minute),
          senderName: 'Me',
          senderUserId: 'u-me',
          bodyHtml: text,
          editableText: text,
        );

    Future<(_Repo, ChatConversationCubit)> pump(WidgetTester tester) async {
      final repo = _Repo([
        mine('2', 'second', 2),
        msg('1', 'Ann Lee', 'u-ann', 1),
      ], ownId: 'u-me');
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open('a',
          const ChatConversation(id: 'c', kind: ChatKind.group, title: 'G'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const ChatConversationView(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (repo, cubit);
    }

    testWidgets('the pencil edits in the composer; Enter saves, the draft '
        'comes back', (tester) async {
      final (repo, cubit) = await pump(tester);
      expect(find.byTooltip('Edit'), findsOneWidget,
          reason: 'only on the user\'s own message');
      await tester.enterText(find.byType(TextField), 'half a thought');
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Editing message'), findsOneWidget);
      expect(find.byTooltip('Save'), findsOneWidget);
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, 'second');

      await tester.enterText(find.byType(TextField), 'second, fixed');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(repo.edits, [('2', 'second, fixed')]);
      expect(find.textContaining('Editing message'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'half a thought');
      expect(find.text('Edited'), findsOneWidget);
      await cubit.close();
    });

    Future<(_Repo, ChatConversationCubit)> pumpThread(WidgetTester tester,
        {required bool wide}) async {
      final repo = _Repo([mine('p1', 'my post', 1)], ownId: 'u-me')
        ..threadReplies = [msg('r1', 'Ann Lee', 'u-ann', 2)];
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open(
          'a',
          const ChatConversation(
              id: 'ch', kind: ChatKind.channel, title: 'General', teamId: 'T'));
      await cubit.openThread('p1');
      await tester.binding.setSurfaceSize(const Size(1200, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: ChatConversationView(wideThreads: wide),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (repo, cubit);
    }

    testWidgets('the post\'s pencil in a thread edits in the thread\'s '
        'composer, the one on screen', (tester) async {
      final (repo, cubit) = await pumpThread(tester, wide: false);
      expect(find.byType(TextField), findsOneWidget,
          reason: 'the thread covers the posts and their composer');
      await tester.tap(find.byTooltip('Edit'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Editing message'), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'my post');
      await tester.enterText(find.byType(TextField), 'my post, fixed');
      await tester.tap(find.byTooltip('Save'));
      await tester.pumpAndSettle();
      expect(repo.edits, [('p1', 'my post, fixed')]);
      expect(repo.sent, isEmpty);
      await cubit.close();
    });

    testWidgets('an edit open in one composer is never saved from the other',
        (tester) async {
      final (repo, cubit) = await pumpThread(tester, wide: true);
      expect(find.byType(TextField), findsNWidgets(2));
      // The post's pencil in the list, not the one in the thread.
      await tester.tap(find.byTooltip('Edit').first);
      await tester.pumpAndSettle();
      expect(cubit.state.editingInThread, isFalse);
      final main = find.byType(TextField).first;
      final reply = find.byType(TextField).last;
      expect(tester.widget<TextField>(main).controller!.text, 'my post');
      expect(tester.widget<TextField>(reply).controller!.text, isEmpty);

      await tester.enterText(reply, 'a reply');
      await tester.tap(find.byTooltip('Send').last);
      await tester.pumpAndSettle();
      expect(repo.sent, [('a reply', 'p1')]);
      expect(repo.edits, isEmpty);
      expect(cubit.state.editing?.id, 'p1', reason: 'still open where it was');
      await cubit.close();
    });

    testWidgets('Up in an empty box edits the last one; Esc leaves it',
        (tester) async {
      final (repo, cubit) = await pump(tester);
      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pumpAndSettle();
      expect(cubit.state.editing?.id, '2');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(cubit.state.editing, isNull);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          isEmpty);
      expect(repo.edits, isEmpty);
      await cubit.close();
    });
  });

  group('pasting a picture', () {
    const channel = MethodChannel('au.com.sharpblue.nightmail/clipboard');
    // A 1×1 PNG.
    final png = Uint8List.fromList([
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D,
      0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
      0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00,
      0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0xF8, 0xCF, 0xC0, 0xF0,
      0x1F, 0x00, 0x05, 0x00, 0x01, 0xFF, 0x89, 0x99, 0x3D, 0x1D, 0x00, 0x00,
      0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
    ]);
    late Map<String, Object?>? onClipboard;
    late String? clipboardText;

    setUp(() {
      onClipboard = null;
      clipboardText = null;
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, (call) async =>
          call.method == 'readImage' ? onClipboard : null);
      messenger.setMockMethodCallHandler(SystemChannels.platform,
          (call) async => switch (call.method) {
                'Clipboard.getData' => clipboardText == null
                    ? null
                    : {'text': clipboardText},
                'Clipboard.hasStrings' => {'value': clipboardText != null},
                _ => null,
              });
    });

    tearDown(() {
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(channel, null);
      messenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<(_Repo, ChatConversationCubit)> pump(WidgetTester tester) async {
      final repo = _Repo([msg('1', 'Ann Lee', 'u-ann', 1)]);
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open('a', const ChatConversation(
          id: 'c', kind: ChatKind.group, title: 'G'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const ChatConversationView(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(TextField));
      await tester.pump();
      return (repo, cubit);
    }

    // Cmd+V on macOS, Ctrl+V on Windows and Linux.
    Future<void> paste(WidgetTester tester) async {
      final modifier = defaultTargetPlatform == TargetPlatform.macOS
          ? LogicalKeyboardKey.metaLeft
          : LogicalKeyboardKey.controlLeft;
      await tester.sendKeyDownEvent(modifier);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyV);
      await tester.sendKeyUpEvent(modifier);
      await tester.pumpAndSettle();
    }

    final desktops = TargetPlatformVariant(
        {TargetPlatform.macOS, TargetPlatform.windows, TargetPlatform.linux});

    testWidgets('a paste stages the picture; Send sends it without text',
        (tester) async {
      onClipboard = {
        'bytes': png,
        'mimeType': 'image/png',
        'name': 'image.png',
        'width': 1,
        'height': 1,
      };
      final (repo, cubit) = await pump(tester);
      await paste(tester);
      expect(find.bySemanticsLabel('Pasted picture'), findsOneWidget);
      await tester.tap(find.byTooltip('Send'));
      await tester.pumpAndSettle();
      expect(repo.sent, [('', null)]);
      expect(repo.images.single?.bytes, png);
      expect(find.bySemanticsLabel('Pasted picture'), findsNothing);
      await cubit.close();
    }, variant: desktops);

    testWidgets('× drops it, and Enter with nothing typed sends nothing',
        (tester) async {
      onClipboard = {'bytes': png, 'mimeType': 'image/png', 'name': 'a.png'};
      final (repo, cubit) = await pump(tester);
      await paste(tester);
      await tester.tap(find.descendant(
          of: find.byTooltip('Remove picture'),
          matching: find.byIcon(Icons.close)));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Pasted picture'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repo.sent, isEmpty);
      await cubit.close();
    }, variant: desktops);

    testWidgets('a picture pasted in one conversation is dropped on '
        'opening another', (tester) async {
      onClipboard = {'bytes': png, 'mimeType': 'image/png', 'name': 'a.png'};
      final (repo, cubit) = await pump(tester);
      await paste(tester);
      expect(find.bySemanticsLabel('Pasted picture'), findsOneWidget);
      await cubit.open('a', const ChatConversation(
          id: 'other', kind: ChatKind.group, title: 'H'));
      await tester.pumpAndSettle();
      expect(find.bySemanticsLabel('Pasted picture'), findsNothing);
      await cubit.close();
    }, variant: desktops);

    testWidgets('text on the clipboard still pastes as text', (tester) async {
      clipboardText = 'hello';
      final (repo, cubit) = await pump(tester);
      await paste(tester);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'hello');
      expect(find.bySemanticsLabel('Pasted picture'), findsNothing);
      await cubit.close();
    }, variant: desktops);

    testWidgets('where pictures cannot be sent, a paste is text',
        (tester) async {
      onClipboard = {'bytes': png, 'mimeType': 'image/png', 'name': 'a.png'};
      clipboardText = 'words';
      final (repo, cubit) = await pump(tester);
      repo.imagesAllowed = false;
      await paste(tester);
      expect(find.bySemanticsLabel('Pasted picture'), findsNothing);
      expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
          'words');
      await cubit.close();
    }, variant: desktops);
  });

  group('@ typeahead', () {
    const bob = ChatMember(
        displayName: 'Bob Brown', userId: 'u-bob', email: 'bob@x.com');
    const carol = ChatMember(displayName: 'Carol Diaz', userId: 'u-carol');
    const me = ChatMember(displayName: 'Me', userId: 'u-me');

    Future<(_Repo, ChatConversationCubit)> pump(WidgetTester tester) async {
      final repo = _Repo([
        ChatMessage(
          id: '2',
          createdAt: DateTime(2026, 11, 25, 10, 2),
          senderName: 'Workflows',
          senderUserId: 'u-app',
          bodyHtml: '<p>build passed</p>',
          senderIsApp: true,
        ),
        msg('1', 'Ann Lee', 'u-ann', 1),
      ], ownId: 'u-me')
        ..roster = [me, bob, carol];
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open('a',
          const ChatConversation(id: 'c', kind: ChatKind.group, title: 'G'));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const ChatConversationView(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      return (repo, cubit);
    }

    String typed(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    testWidgets('Enter picks the person rather than sending; the next Enter '
        'sends with them tagged', (tester) async {
      final (repo, cubit) = await pump(tester);
      await tester.enterText(find.byType(TextField), 'hi @bo');
      await tester.pumpAndSettle();
      expect(find.text('Bob Brown'), findsOneWidget);
      expect(find.text('Carol Diaz'), findsNothing);

      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repo.sent, isEmpty);
      expect(typed(tester), 'hi @Bob Brown ');
      expect(find.text('Bob Brown'), findsNothing, reason: 'list closed');

      await tester.enterText(find.byType(TextField), 'hi @Bob Brown look');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repo.sent.single.$1, 'hi @Bob Brown look');
      expect(repo.sentMentions.single, [bob]);
      expect(typed(tester), '');
      await cubit.close();
    });

    testWidgets('a bare @ lists the members and whoever wrote, never the '
        'user; Down and Tab pick the second', (tester) async {
      final (repo, cubit) = await pump(tester);
      await tester.enterText(find.byType(TextField), '@');
      await tester.pumpAndSettle();
      expect(find.text('Bob Brown'), findsOneWidget);
      expect(find.text('Carol Diaz'), findsOneWidget);
      expect(find.text('Ann Lee'), findsWidgets, reason: 'wrote in it');
      expect(find.text('Me'), findsNothing);
      expect(find.byKey(const ValueKey('mention-u-app')), findsNothing,
          reason: 'an app is no one to tag');
      expect(find.byKey(const ValueKey('mention-u-ann')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pumpAndSettle();
      expect(typed(tester), '@Carol Diaz ');
      expect(repo.sent, isEmpty);
      await cubit.close();
    });

    testWidgets('an address\'s @ opens nothing, and Esc closes the list so '
        'Enter sends', (tester) async {
      final (repo, cubit) = await pump(tester);
      await tester.enterText(find.byType(TextField), 'mail bob@x');
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('mention-u-bob')), findsNothing);

      await tester.enterText(find.byType(TextField), 'ask @car');
      await tester.pumpAndSettle();
      expect(find.text('Carol Diaz'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.text('Carol Diaz'), findsNothing);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repo.sent.single.$1, 'ask @car');
      expect(repo.sentMentions.single, isEmpty);
      await cubit.close();
    });

    testWidgets('tapping a row picks it', (tester) async {
      final (repo, cubit) = await pump(tester);
      await tester.enterText(find.byType(TextField), '@b');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('mention-u-bob')));
      await tester.pumpAndSettle();
      expect(typed(tester), '@Bob Brown ');
      await cubit.close();
    });

    test('matchMentions ranks a name prefix, then word prefixes, then '
        'an address', () {
      const ann = ChatMember(
          displayName: 'Ann Lee', userId: 'a', email: 'zed@x.com');
      const lee = ChatMember(displayName: 'Lee Park', userId: 'l');
      const z = ChatMember(displayName: 'Zoe', userId: 'z', email: 'lee@x');
      final roster = [ann, z, lee];
      expect(matchMentions(roster, 'lee'), [lee, ann, z]);
      expect(matchMentions(roster, 'ann l'), [ann]);
      expect(matchMentions(roster, ''), roster);
      expect(matchMentions(roster, 'q'), isEmpty);
    });
  });

  group('drafts', () {
    const g = ChatConversation(id: 'c', kind: ChatKind.group, title: 'G');
    const h = ChatConversation(id: 'other', kind: ChatKind.group, title: 'H');

    String typed(WidgetTester tester) =>
        tester.widget<TextField>(find.byType(TextField)).controller!.text;

    Future<void> show(WidgetTester tester, ChatConversationCubit cubit) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: BlocProvider.value(
            value: cubit,
            child: const ChatConversationView(),
          ),
        ),
      ));
      await tester.pumpAndSettle();
    }

    testWidgets('what was typed stays with its conversation', (tester) async {
      final repo = _Repo([msg('1', 'Ann Lee', 'u-ann', 1)]);
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open('a', g);
      await show(tester, cubit);
      await tester.enterText(find.byType(TextField), 'half a thought');

      await cubit.open('a', h);
      await tester.pumpAndSettle();
      expect(typed(tester), '', reason: 'never carried to another chat');
      await tester.enterText(find.byType(TextField), 'for H');

      await cubit.open('a', g);
      await tester.pumpAndSettle();
      expect(typed(tester), 'half a thought');
      await cubit.open('a', h);
      await tester.pumpAndSettle();
      expect(typed(tester), 'for H');
      expect(repo.sent, isEmpty);
      await cubit.close();
    });

    testWidgets('it survives the pane closing, with its tags, and goes once '
        'sent', (tester) async {
      const bob = ChatMember(userId: 'u-bob', displayName: 'Bob Brown');
      final repo = _Repo([msg('1', 'Ann Lee', 'u-ann', 1)])..roster = [bob];
      final drafts = ChatDrafts();
      final cubit = ChatConversationCubit(repository: repo, drafts: drafts);
      await cubit.open('a', g);
      await show(tester, cubit);
      await tester.enterText(find.byType(TextField), 'hi @bo');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(typed(tester), 'hi @Bob Brown ');
      await tester.pumpWidget(const SizedBox());
      await cubit.close();

      // The pane opens again with a new cubit, as it does.
      final again = ChatConversationCubit(repository: repo, drafts: drafts);
      await again.open('a', g);
      await show(tester, again);
      expect(typed(tester), 'hi @Bob Brown ');
      await tester.enterText(find.byType(TextField), 'hi @Bob Brown look');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repo.sent.single.$1, 'hi @Bob Brown look');
      expect(repo.sentMentions.single, [bob]);

      await again.open('a', h);
      await tester.pumpAndSettle();
      await again.open('a', g);
      await tester.pumpAndSettle();
      expect(typed(tester), '');
      expect(drafts['a|c:c'], isNull);
      await again.close();
    });

    testWidgets('its tags come back after another chat was opened',
        (tester) async {
      const bob = ChatMember(userId: 'u-bob', displayName: 'Bob Brown');
      final repo = _Repo([msg('1', 'Ann Lee', 'u-ann', 1)])..roster = [bob];
      final cubit = ChatConversationCubit(repository: repo);
      await cubit.open('a', g);
      await show(tester, cubit);
      await tester.enterText(find.byType(TextField), 'hi @bo');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();

      await cubit.open('a', h);
      await tester.pumpAndSettle();
      expect(typed(tester), '');
      await cubit.open('a', g);
      await tester.pumpAndSettle();

      expect(typed(tester), 'hi @Bob Brown ');
      await tester.enterText(find.byType(TextField), 'hi @Bob Brown look');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(repo.sentMentions.single, [bob]);
      await cubit.close();
    });

    testWidgets('a message still sending when the user moves on is not '
        'left behind as a draft', (tester) async {
      final repo = _Repo([msg('1', 'Ann Lee', 'u-ann', 1)]);
      final drafts = ChatDrafts();
      final cubit = ChatConversationCubit(repository: repo, drafts: drafts);
      await cubit.open('a', g);
      await show(tester, cubit);
      await tester.enterText(find.byType(TextField), 'on its way');
      repo.sendGate = Completer();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();

      repo.loadGate = Completer();
      unawaited(cubit.open('a', h));
      await tester.pump();
      expect(drafts['a|c:c']?.text, 'on its way', reason: 'kept until sent');
      repo.sendGate!.complete();
      repo.loadGate!.complete();
      repo.loadGate = null;
      await tester.pumpAndSettle();
      expect(repo.sent.single.$1, 'on its way');
      expect(drafts['a|c:c'], isNull);

      await tester.enterText(find.byType(TextField), 'for H');
      await cubit.open('a', g);
      await tester.pumpAndSettle();
      expect(typed(tester), '');
      await cubit.open('a', h);
      await tester.pumpAndSettle();
      expect(typed(tester), 'for H', reason: 'the other box was not emptied');
      await cubit.close();
    });
  });
}

class _Repo extends Fake implements ChatRepository {
  _Repo(this.history, {this.ownId});

  final List<ChatMessage> history;
  final String? ownId;
  final photosAsked = <String>{};
  final marked = <String>[];

  @override
  Future<String?> ownUserId(
    String accountId, {
    ChatConversation? conversation,
  }) async =>
      ownId;

  @override
  Future<void> markRead(
      String accountId, ChatConversation conversation) async {
    marked.add(conversation.id);
  }

  @override
  Future<Either<Failure, ChatMessagePage>> messages(
    String accountId,
    ChatConversation conversation, {
    String? nextLink,
  }) async {
    await loadGate?.future;
    return Right(ChatMessagePage(messages: history));
  }

  /// Hold a load or a send open, as the network does.
  Completer<void>? loadGate;
  Completer<void>? sendGate;

  @override
  Future<Uint8List?> photo(String accountId, String userId) async {
    photosAsked.add(userId);
    return null;
  }

  @override
  Future<Uint8List?> image(String accountId, String src) async => null;

  @override
  Future<List<ChatMessage>> cachedMessages(
          String accountId, ChatConversation conversation) async =>
      const [];

  @override
  Future<void> cacheMessages(String accountId, ChatConversation conversation,
      List<ChatMessage> messages) async {}

  final edits = <(String, String)>[];
  final sent = <(String, String?)>[];
  List<ChatMessage> threadReplies = const [];

  @override
  Future<Either<Failure, List<ChatMessage>>> replies(String accountId,
          ChatConversation conversation, ChatMessage post) async =>
      Right(threadReplies);

  @override
  Future<Either<Failure, ChatMessage>> sendMessage(
    String accountId,
    ChatConversation conversation,
    String text, {
    ChatMessage? replyTo,
    ChatOutgoingImage? image,
    List<ChatMember> mentions = const [],
  }) async {
    await sendGate?.future;
    sent.add((text, replyTo?.id));
    images.add(image);
    sentMentions.add(mentions);
    return Right(ChatMessage(
      id: 'new-${sent.length}',
      createdAt: DateTime(2026, 11, 25, 11),
      senderName: 'Me',
      senderUserId: 'u-me',
      bodyHtml: text,
    ));
  }

  final images = <ChatOutgoingImage?>[];
  final sentMentions = <List<ChatMember>>[];
  List<ChatMember> roster = const [];

  @override
  Future<Either<Failure, List<ChatMember>>> mentionable(
          String accountId, ChatConversation conversation) async =>
      Right(roster);
  bool imagesAllowed = true;

  @override
  bool canSendImage(String accountId, ChatConversation conversation) =>
      imagesAllowed;

  @override
  bool canEdit(String accountId, ChatConversation conversation) => true;

  final reactions = <(String, String)>[];

  /// A Slack DM's answer: its messages thread though it is not a channel.
  bool threadsChats = false;

  @override
  bool canThread(String accountId, ChatConversation conversation) =>
      conversation.hasThreads || threadsChats;

  @override
  bool canReact(String accountId, ChatConversation conversation) => true;

  ChatCalling callingAs = ChatCalling.voiceAndVideo;
  final callsAsked = <(String?, bool)>[];

  @override
  ChatCalling calling(String accountId) => callingAs;

  bool needsCallConsent = false;

  @override
  Future<bool> callNeedsConsent(String accountId) async => needsCallConsent;

  @override
  Future<Either<Failure, bool>> requestCallConsent(String accountId) async {
    needsCallConsent = false;
    return const Right(true);
  }

  @override
  Future<Either<Failure, String>> callLink(
    String accountId,
    ChatConversation conversation,
    ChatMember person, {
    required bool video,
  }) async {
    callsAsked.add((person.userId, video));
    return Right('https://call.example/${person.userId}?video=$video');
  }

  final unreactions = <(String, String)>[];

  @override
  Future<Either<Failure, bool>> unreact(String accountId,
      ChatConversation conversation, ChatMessage message, String emoji) async {
    unreactions.add((message.id, emoji));
    return const Right(true);
  }

  @override
  Future<Either<Failure, bool>> react(String accountId,
      ChatConversation conversation, ChatMessage message, String emoji) async {
    reactions.add((message.id, emoji));
    return const Right(true);
  }

  @override
  Future<Either<Failure, ChatMessage>> editMessage(
    String accountId,
    ChatConversation conversation,
    ChatMessage message,
    String text,
  ) async {
    edits.add((message.id, text));
    return Right(message.withEdit(
        bodyHtml: text, editableText: text, editedAt: DateTime(2026)));
  }
}
