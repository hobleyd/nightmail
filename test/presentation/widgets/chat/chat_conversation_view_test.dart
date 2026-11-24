import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/repositories/chat_repository.dart';
import 'package:nightmail/presentation/blocs/chat/chat_conversation_cubit.dart';
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

  test('everyone in a conversation gets their own colour, the same each time',
      () {
    final people = [
      for (var i = 0; i < ChatPersonStyle.hues.length; i++) 'u-$i',
    ];
    final slots = ChatPersonStyle.assign(people);
    expect(slots.values.toSet().length, ChatPersonStyle.hues.length);
    // A one-on-one's two people are the list's first two: blue and orange.
    expect(ChatPersonStyle.assign(['u-ann', 'u-bob']).values.toSet(), {0, 1});
    expect(ChatPersonStyle.assign(people.reversed), slots);
  });
}

class _Repo extends Fake implements ChatRepository {
  _Repo(this.history);

  final List<ChatMessage> history;
  final photosAsked = <String>{};

  @override
  Future<Either<Failure, ChatMessagePage>> messages(
    String accountId,
    ChatConversation conversation, {
    String? nextLink,
  }) async =>
      Right(ChatMessagePage(messages: history));

  @override
  Future<Uint8List?> photo(String accountId, String userId) async {
    photosAsked.add(userId);
    return null;
  }

  @override
  Future<Uint8List?> image(String accountId, String src) async => null;
}
