import 'dart:convert';

import 'package:desktop_multi_window/desktop_multi_window.dart';
import 'package:flutter/foundation.dart';

import '../../../core/platform/window_utils.dart';
import '../../../domain/entities/chat.dart';

/// What the chat window should open on: a chat system (an account id or a
/// `slack:{team}` id) and, when the Chat pane has one open, its
/// conversation — so "Open chat window" carries on where the pane was.
///
/// Crosses isolates as JSON: in the window's creation arguments, or — when
/// the window is already open — pushed to it with [openMethod]. Only what
/// names the conversation travels; the window takes members and the rest
/// from its own copy of the list ([ChatWindowTarget.conversation] is the
/// fallback until that loads).
class ChatWindowTarget {
  const ChatWindowTarget({required this.sourceId, this.conversation});

  final String sourceId;
  final ChatConversation? conversation;

  static const windowType = 'chat';
  static const argument = 'target';
  static const openMethod = 'openTarget';

  Map<String, Object?> toJson() => {
        'source': sourceId,
        if (conversation case final c?)
          'conversation': {
            'id': c.id,
            'kind': c.kind.name,
            'title': c.title,
            'teamId': ?c.teamId,
            'teamName': ?c.teamName,
            if (c.threaded) 'threaded': true,
          },
      };

  static ChatWindowTarget? fromJson(Object? json) {
    if (json is! Map) return null;
    final source = json['source'];
    if (source is! String || source.isEmpty) return null;
    final c = json['conversation'];
    return ChatWindowTarget(
      sourceId: source,
      conversation: c is Map && c['id'] is String
          ? ChatConversation(
              id: c['id'] as String,
              kind: ChatKind.values.asNameMap()[c['kind']] ?? ChatKind.group,
              title: c['title'] as String? ?? '',
              teamId: c['teamId'] as String?,
              teamName: c['teamName'] as String?,
              threaded: c['threaded'] == true,
            )
          : null,
    );
  }
}

/// Fronts the chat window on [target], opening it if none is.
Future<void> openChatWindow(ChatWindowTarget target) async {
  final existing = await findSubWindow(ChatWindowTarget.windowType);
  if (existing != null) {
    try {
      await existing.show();
      await existing.invokeMethod<void>(
          ChatWindowTarget.openMethod, target.toJson());
      return;
    } catch (e) {
      // Closed since the lookup — open a fresh one below.
      debugPrint('[Chat] could not point the open window: $e');
    }
  }
  await createSubWindow(WindowConfiguration(
    arguments: jsonEncode({
      'type': ChatWindowTarget.windowType,
      ChatWindowTarget.argument: target.toJson(),
    }),
  ));
}
