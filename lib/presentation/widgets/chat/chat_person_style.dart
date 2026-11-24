import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/chat.dart';
import '../../blocs/chat/chat_conversation_cubit.dart';

/// Each person's colours in a conversation: a pastel bubble, a deeper avatar
/// and a readable name, all from one hue.
///
/// The hues are a fixed list ordered for contrast — each far from the ones
/// before it — and [ChatPeopleColors] deals them out in that order to the
/// conversation's people, so a one-on-one is always blue and orange and a
/// group of five never has two neighbours on the colour wheel. Hashing each
/// person to a hue instead collides (two people in one colour) or lands
/// 30° apart, which reads as the same colour in pastel.
class ChatPersonStyle {
  const ChatPersonStyle._(this._hue, this._dark);

  /// [m]'s sender in the colours [ChatPeopleColors] gave them, or by hash
  /// outside one.
  factory ChatPersonStyle.of(BuildContext context, ChatMessage m) {
    final key = personKey(m);
    final slot =
        ChatPeopleColors.slotOf(context, key) ?? _hash(key) % hues.length;
    return ChatPersonStyle._(
        hues[slot], Theme.of(context).brightness == Brightness.dark);
  }

  factory ChatPersonStyle.forKey(String key, Brightness brightness) =>
      ChatPersonStyle._(
          hues[_hash(key) % hues.length], brightness == Brightness.dark);

  /// Blue, orange, green, purple, teal, pink, yellow, indigo, lime, red.
  static const hues = <double>[210, 25, 135, 280, 175, 335, 50, 245, 95, 0];

  /// A slot in [hues] for each of [keys]: dealt in an order fixed by the
  /// people themselves (their hash), so the same people always get the same
  /// colours, and distinct until there are more people than hues.
  static Map<String, int> assign(Iterable<String> keys) {
    final people = keys.toSet().toList()
      ..sort((a, b) {
        final byHash = _hash(a).compareTo(_hash(b));
        return byHash != 0 ? byHash : a.compareTo(b);
      });
    return {
      for (var i = 0; i < people.length; i++) people[i]: i % hues.length,
    };
  }

  final double _hue;
  final bool _dark;

  Color get bubble => _dark
      ? HSLColor.fromAHSL(1, _hue, 0.28, 0.21).toColor()
      : HSLColor.fromAHSL(1, _hue, 0.80, 0.94).toColor();

  Color get avatar => _dark
      ? HSLColor.fromAHSL(1, _hue, 0.40, 0.42).toColor()
      : HSLColor.fromAHSL(1, _hue, 0.50, 0.60).toColor();

  Color get name => _dark
      ? HSLColor.fromAHSL(1, _hue, 0.65, 0.76).toColor()
      : HSLColor.fromAHSL(1, _hue, 0.60, 0.33).toColor();

  /// Who sent [m]: their directory id when the provider gives one, else
  /// their name.
  static String personKey(ChatMessage m) {
    final id = m.senderUserId;
    return id != null && id.isNotEmpty
        ? id
        : m.senderName.trim().toLowerCase();
  }

  /// FNV-1a — `String.hashCode` is not promised to be stable across runs.
  static int _hash(String s) {
    var h = 0x811c9dc5;
    for (final c in s.codeUnits) {
      h = ((h ^ c) * 0x01000193) & 0xffffffff;
    }
    return h;
  }
}

/// The colours of everyone in the conversation below it, kept distinct by
/// [ChatPersonStyle.assign].
class ChatPeopleColors extends InheritedWidget {
  ChatPeopleColors({
    super.key,
    required Iterable<ChatMessage> messages,
    required super.child,
  }) : slots = ChatPersonStyle.assign(
            messages.where((m) => !m.isSystem).map(ChatPersonStyle.personKey));

  final Map<String, int> slots;

  static int? slotOf(BuildContext context, String key) => context
      .dependOnInheritedWidgetOfExactType<ChatPeopleColors>()
      ?.slots[key];

  @override
  bool updateShouldNotify(ChatPeopleColors old) =>
      !_sameSlots(old.slots, slots);

  static bool _sameSlots(Map<String, int> a, Map<String, int> b) =>
      a.length == b.length && a.entries.every((e) => b[e.key] == e.value);
}

/// A sender's photo, or their initials on their colour until (or unless) a
/// photo arrives.
class ChatAvatar extends StatefulWidget {
  const ChatAvatar({super.key, required this.message, this.size = 28});

  final ChatMessage message;
  final double size;

  @override
  State<ChatAvatar> createState() => _ChatAvatarState();
}

class _ChatAvatarState extends State<ChatAvatar> {
  Uint8List? _photo;
  String? _askedFor;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _load();
  }

  @override
  void didUpdateWidget(ChatAvatar old) {
    super.didUpdateWidget(old);
    _load();
  }

  void _load() {
    final id = widget.message.senderUserId;
    if (id == null || id.isEmpty || id == _askedFor) return;
    _askedFor = id;
    _photo = null;
    context.read<ChatConversationCubit>().photo(id).then((bytes) {
      if (mounted && _askedFor == id && bytes != null) {
        setState(() => _photo = bytes);
      }
    });
  }

  static String initials(String name) {
    final words = name
        .split(RegExp(r'[\s,]+'))
        .where((w) => w.isNotEmpty && RegExp(r'^\p{L}', unicode: true).hasMatch(w))
        .toList();
    if (words.isEmpty) return name.isEmpty ? '?' : name.characters.first;
    final first = words.first.characters.first;
    final last = words.length > 1 ? words.last.characters.first : '';
    return (first + last).toUpperCase();
  }

  @override
  Widget build(BuildContext context) {
    final size = widget.size;
    final style = ChatPersonStyle.of(context, widget.message);
    final photo = _photo;
    return Tooltip(
      message: widget.message.senderName,
      child: SizedBox.square(
        dimension: size,
        child: ClipOval(
          child: photo != null
              ? Image.memory(
                  photo,
                  width: size,
                  height: size,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => _initials(style, size),
                )
              : _initials(style, size),
        ),
      ),
    );
  }

  Widget _initials(ChatPersonStyle style, double size) => ColoredBox(
        color: style.avatar,
        child: Center(
          child: Text(
            initials(widget.message.senderName),
            style: TextStyle(
              color: Colors.white,
              fontSize: size * 0.4,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      );
}
