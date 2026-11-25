import 'emoji_shortcodes.dart';

/// The emoji Slack's [name] stands for — `thumbsup`, or a reaction's
/// `thumbsup::skin-tone-3` — or null for a name it does not have (a
/// workspace's custom emoji).
String? shortcodeEmoji(String name) {
  final parts = name.split('::');
  return _toned(parts.first, parts.length > 1 ? parts[1] : null);
}

/// [name], in [tone] (`skin-tone-3`) when given: the exact sequence
/// emoji-data has for it, else the plain emoji with the modifier after it.
String? _toned(String name, String? tone) {
  if (tone != null) {
    final exact = emojiShortcodes['$name::$tone'];
    if (exact != null) return exact;
  }
  final base = emojiShortcodes[name];
  if (base == null) return null;
  final modifier = tone == null ? null : emojiShortcodes[tone];
  // A modifier changes the character before it, so the base's presentation
  // selector (U+FE0F) has to go or the two render apart.
  return modifier == null ? base : base.replaceAll('\u{FE0F}', '') + modifier;
}

/// `:+1:` and `:wave::skin-tone-3:` in [text] as the characters they stand
/// for. Not inside `` `code` `` or ```` ```blocks``` ````, which Slack shows
/// as typed, and not glued to a word or number either side, so `a:b:c` and
/// `10:30:00` stay text. A name that is not a standard emoji is offered to
/// [custom] (a workspace's own emoji); without an answer it stays `:name:`.
String replaceShortcodes(
  String text, {
  String? Function(String name)? custom,
}) {
  if (!text.contains(':')) return text;
  return text.replaceAllMapped(_token, (m) {
    final name = m[1];
    if (name == null) return m[0]!;
    return _toned(name, m[2] == null ? null : 'skin-tone-${m[2]}') ??
        custom?.call(name) ??
        m[0]!;
  });
}

final _token = RegExp(
  r'```[\s\S]*?```|`[^`\n]+`'
  r'|(?<!\w):([a-z0-9_+\-]+):(?::skin-tone-([2-6]):)?(?![\w])',
);
