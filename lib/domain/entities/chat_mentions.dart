import 'chat.dart';

/// A piece of an outgoing message: plain text, or a person tagged in it.
sealed class ChatTextPart {
  const ChatTextPart();
}

/// Typed text, unescaped — each provider escapes it its own way.
class ChatTextRun extends ChatTextPart {
  const ChatTextRun(this.text);
  final String text;
}

/// `@Name` the composer filled in from its typeahead, for [member].
class ChatMentionRun extends ChatTextPart {
  const ChatMentionRun(this.member);
  final ChatMember member;
}

/// Splits [text] into runs of typed text and the [mentions] the composer
/// picked, each still written as `@displayName`. Only an `@` at the start or
/// after a space can begin one (so `bob@example.com` stays text), the longest
/// name wins (`@Ann Lee` before `@Ann`), and the name must end there — not
/// run on into a letter or digit. A pick whose `@Name` was deleted or
/// retyped is simply not found, and goes as the text it now is.
///
/// Splitting first and escaping each run after is the point: a provider that
/// replaced `@Name` in already-escaped text would miss a name holding `&`
/// or `<`.
List<ChatTextPart> splitMentions(String text, List<ChatMember> mentions) {
  final named = {
    for (final m in mentions)
      if (m.displayName.trim().isNotEmpty && m.userId != null)
        m.displayName.trim(): m,
  };
  if (named.isEmpty || !text.contains('@')) return [ChatTextRun(text)];
  final names = named.keys.toList()
    ..sort((a, b) => b.length.compareTo(a.length));
  final parts = <ChatTextPart>[];
  var from = 0;
  for (var i = 0; i < text.length; i++) {
    if (text.codeUnitAt(i) != 0x40) continue; // '@'
    if (i > 0 && !_isSpace(text[i - 1])) continue;
    final name = names.firstWhere(
      (n) =>
          text.startsWith(n, i + 1) &&
          (i + 1 + n.length == text.length ||
              !_isWordChar(text[i + 1 + n.length])),
      orElse: () => '',
    );
    if (name.isEmpty) continue;
    if (i > from) parts.add(ChatTextRun(text.substring(from, i)));
    parts.add(ChatMentionRun(named[name]!));
    from = i + 1 + name.length;
    i = from - 1;
  }
  if (from < text.length) parts.add(ChatTextRun(text.substring(from)));
  return parts;
}

bool _isSpace(String c) => c.trim().isEmpty || c == '(';

bool _isWordChar(String c) => RegExp(r'[\p{L}\p{N}_]', unicode: true).hasMatch(c);
