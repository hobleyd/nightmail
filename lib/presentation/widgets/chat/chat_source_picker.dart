import 'package:flutter/material.dart';

import '../../../core/platform/touch_metrics.dart';
import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/chat.dart';

IconData chatSourceIcon(ChatSourceKind kind) => switch (kind) {
      ChatSourceKind.teams => Icons.groups_2_outlined,
      ChatSourceKind.nightmailServer => Icons.forum_outlined,
      ChatSourceKind.googleChat => Icons.chat_bubble_outline_rounded,
      ChatSourceKind.slack => Icons.tag_rounded,
    };

/// The chat system at the top of the Chat pane. With more than one — the
/// account's own chat and a Slack workspace, say — it is a dropdown of them,
/// each with its own unread dot and count and "Reconnect" on a refused
/// workspace; with one it is just its name.
class ChatSourcePicker extends StatelessWidget {
  const ChatSourcePicker({
    super.key,
    required this.sources,
    required this.chosen,
    required this.unreadIn,
    required this.onChoose,
  });

  final List<ChatSource> sources;
  final ChatSource? chosen;
  final int Function(String sourceId) unreadIn;
  final ValueChanged<String> onChoose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final chosen = this.chosen;
    // A dot beside the arrow when a system not on show has unread chats.
    final elsewhere = sources.any((s) => s.id != chosen?.id && unreadIn(s.id) > 0);
    final label = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
            chosen == null
                ? Icons.forum_outlined
                : chatSourceIcon(chosen.kind),
            size: touchIcon(16),
            color: AppColors.accent),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            chosen?.label ?? 'Chat',
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 14,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.2,
            ),
          ),
        ),
        if (sources.length > 1) ...[
          const SizedBox(width: 2),
          Icon(Icons.arrow_drop_down_rounded,
              size: touchIcon(20), color: c.textMuted),
          if (elsewhere) const _Dot(),
        ],
      ],
    );
    if (sources.length <= 1) return label;
    return PopupMenuButton<String>(
      tooltip: 'Switch chat service',
      color: c.surfacePanel,
      position: PopupMenuPosition.under,
      onSelected: onChoose,
      itemBuilder: (_) => [
        for (final s in sources)
          PopupMenuItem<String>(
            value: s.id,
            height: touchRowHeight(36),
            child: ChatSourceRow(
              source: s,
              unread: unreadIn(s.id),
              chosen: s.id == chosen?.id,
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: label,
      ),
    );
  }
}

/// One chat system in the pane's dropdown: its name, a red dot and count
/// when it has unread chats, and a tick on the one the pane shows.
class ChatSourceRow extends StatelessWidget {
  const ChatSourceRow({
    super.key,
    required this.source,
    required this.unread,
    required this.chosen,
  });

  final ChatSource source;
  final int unread;
  final bool chosen;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        SizedBox(
          width: 18,
          child: chosen
              ? Icon(Icons.check_rounded, size: 15, color: c.textSecondary)
              : null,
        ),
        const SizedBox(width: 4),
        Icon(chatSourceIcon(source.kind), size: 16, color: c.textMuted),
        const SizedBox(width: 8),
        Flexible(
          child: Text(
            source.label,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13, color: c.textPrimary),
          ),
        ),
        if (source.needsReconnect) ...[
          const SizedBox(width: 8),
          Text('Reconnect',
              style: TextStyle(fontSize: 11.5, color: c.errorBannerText)),
        ],
        if (unread > 0) ...[
          const SizedBox(width: 10),
          const _Dot(),
          const SizedBox(width: 4),
          Text('$unread',
              style: TextStyle(fontSize: 12, color: c.textTertiary)),
        ],
      ],
    );
  }
}

class _Dot extends StatelessWidget {
  const _Dot();

  @override
  Widget build(BuildContext context) => Container(
        width: 7,
        height: 7,
        decoration: const BoxDecoration(
          color: AppColors.notification,
          shape: BoxShape.circle,
        ),
      );
}
