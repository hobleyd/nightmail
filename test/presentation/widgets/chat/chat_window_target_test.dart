import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/presentation/widgets/chat/chat_window_target.dart';

/// What the Chat pane hands the chat window: it crosses isolates as JSON.
void main() {
  ChatWindowTarget? roundTrip(ChatWindowTarget t) =>
      ChatWindowTarget.fromJson(jsonDecode(jsonEncode(t.toJson())));

  test('a Teams channel keeps what names it, so its key matches the list',
      () {
    const channel = ChatConversation(
      id: '19:abc',
      kind: ChatKind.channel,
      title: 'General',
      teamId: 'T9',
      teamName: 'Ops',
      threaded: true,
    );
    final back = roundTrip(
        const ChatWindowTarget(sourceId: 'work', conversation: channel))!;
    expect(back.sourceId, 'work');
    expect(back.conversation!.key, channel.key);
    expect(back.conversation!.kind, ChatKind.channel);
    expect(back.conversation!.threaded, isTrue);
  });

  test('a Slack system alone, with no conversation open', () {
    final back = roundTrip(const ChatWindowTarget(sourceId: 'slack:T1'))!;
    expect(back.sourceId, 'slack:T1');
    expect(back.conversation, isNull);
  });

  test('no target, or a malformed one, is none', () {
    expect(ChatWindowTarget.fromJson(null), isNull);
    expect(ChatWindowTarget.fromJson({'source': ''}), isNull);
  });
}
