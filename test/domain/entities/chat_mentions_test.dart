import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/chat.dart';
import 'package:nightmail/domain/entities/chat_mentions.dart';

/// The composer's picks found in the text as sent: each provider turns the
/// mention runs into its own tag and escapes the rest its own way.
void main() {
  const ann = ChatMember(displayName: 'Ann', userId: 'a');
  const annLee = ChatMember(displayName: 'Ann Lee', userId: 'al');

  List<Object> shape(List<ChatTextPart> parts) => [
        for (final p in parts)
          switch (p) {
            ChatTextRun(:final text) => text,
            ChatMentionRun(:final member) => member.userId!,
          },
      ];

  test('the longest name wins', () {
    expect(shape(splitMentions('hi @Ann Lee and @Ann', [ann, annLee])),
        ['hi ', 'al', ' and ', 'a']);
  });

  test('an address or a longer word is not a mention', () {
    expect(shape(splitMentions('mail x@Ann or @Annie', [ann])),
        ['mail x@Ann or @Annie']);
  });

  test('punctuation may follow; a bracket may precede', () {
    expect(shape(splitMentions('(@Ann), thanks', [ann])), ['(', 'a', '), thanks']);
  });

  test('nothing picked, or a pick without an id, leaves the text whole', () {
    expect(shape(splitMentions('@Ann', const [])), ['@Ann']);
    expect(
        shape(splitMentions(
            '@Ann', const [ChatMember(displayName: 'Ann')])),
        ['@Ann']);
  });
}
