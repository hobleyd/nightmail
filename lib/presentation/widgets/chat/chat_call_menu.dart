import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/entities/chat.dart';
import '../../blocs/chat/chat_conversation_cubit.dart';
import '../body_link_opener.dart';
import 'chat_person_style.dart';

/// [ChatAvatar] for [message]'s sender that, when the chat system can call
/// them ([ChatConversationCubit.callingFor]), offers a call on a click: the
/// call itself is handed to the system's own app or web page.
///
/// Only the avatar heading a run of messages — the mention picker's avatars
/// sit inside its own tap target.
class ChatCallableAvatar extends StatelessWidget {
  const ChatCallableAvatar({
    super.key,
    required this.message,
    required this.size,
  });

  final ChatMessage message;
  final double size;

  /// Hands the call link over; a test swaps it for a recorder.
  @visibleForTesting
  static Future<void> Function(String link) launch = launchMeetingJoinUrl;

  @override
  Widget build(BuildContext context) {
    final avatar = ChatAvatar(message: message, size: size);
    // Selected, not read: the user's own id arrives after the first
    // messages, and their avatar must stop offering a call when it does.
    final calling = context.select<ChatConversationCubit, ChatCalling>(
        (c) => c.callingFor(message));
    if (calling == ChatCalling.none) return avatar;
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTapUp: (d) => _offer(context, d.globalPosition, calling),
        child: avatar,
      ),
    );
  }

  Future<void> _offer(
      BuildContext context, Offset at, ChatCalling calling) async {
    final cubit = context.read<ChatConversationCubit>();
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox;
    final name = message.senderName;
    PopupMenuItem<bool> item(bool video, IconData icon, String label) =>
        PopupMenuItem<bool>(
          value: video,
          height: 36,
          child: Row(
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 10),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          ),
        );
    final video = await showMenu<bool>(
      context: context,
      position: RelativeRect.fromRect(
          at & const Size(1, 1), Offset.zero & overlay.size),
      items: switch (calling) {
        ChatCalling.voiceAndVideo => [
            item(false, Icons.call_outlined, 'Voice call $name'),
            item(true, Icons.videocam_outlined, 'Video call $name'),
          ],
        ChatCalling.huddle => [
            item(false, Icons.headset_mic_outlined,
                'Start a huddle with $name in Slack'),
          ],
        ChatCalling.meet => [
            item(true, Icons.videocam_outlined,
                'Start a Google Meet and send $name the link'),
          ],
        ChatCalling.none => const [],
      },
    );
    if (video == null) return;
    if (await cubit.callNeedsConsent()) {
      if (!context.mounted) return;
      final go = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Allow Google Meet calls?'),
          content: const Text(
              'Google will ask, in your browser, to let NightMail create '
              'Google Meet meetings for this account. NightMail can only '
              'see the meetings it creates. You are asked once.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Continue'),
            ),
          ],
        ),
      );
      if (go != true) return;
    }
    final link = await cubit.callLink(message, video: video);
    if (link != null) await launch(link);
  }
}
