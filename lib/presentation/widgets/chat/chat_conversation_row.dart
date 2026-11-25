import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/chat.dart';

/// A conversation's or message's time: the hour today, the weekday this
/// week, otherwise the date.
String chatWhen(DateTime? at) {
  if (at == null) return '';
  final now = DateTime.now();
  if (at.year == now.year && at.month == now.month && at.day == now.day) {
    return DateFormat.jm().format(at);
  }
  if (now.difference(at).inDays < 7) return DateFormat.E().format(at);
  return DateFormat(at.year == now.year ? 'd MMM' : 'd/M/yy').format(at);
}

/// One chat or channel in a list: kind icon, title (bold with a dot while
/// unread), time, and the newest message's preview. The chat window's list
/// and the Chat pane's unread list.
class ChatConversationRow extends StatelessWidget {
  const ChatConversationRow({
    super.key,
    required this.conversation,
    required this.selected,
    required this.onTap,
    this.indent = false,
  });

  final ChatConversation conversation;
  final bool selected;
  final bool indent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final icon = switch (conversation.kind) {
      ChatKind.oneOnOne => Icons.person_outline,
      ChatKind.group => Icons.people_outline,
      ChatKind.meeting => Icons.event_outlined,
      ChatKind.channel => Icons.tag,
      ChatKind.space => Icons.workspaces_outline,
    };
    final unread = conversation.unread && !selected;
    return Material(
      color: selected ? c.selectionBg : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: EdgeInsets.fromLTRB(indent ? 30 : 12, 7, 12, 7),
          child: Row(
            children: [
              Icon(icon, size: 16, color: c.textTertiary),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            conversation.title,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13,
                              // Bold is "unread", as in the mail list.
                              fontWeight: unread
                                  ? FontWeight.w700
                                  : FontWeight.w400,
                              color: c.textPrimary,
                            ),
                          ),
                        ),
                        if (unread) ...[
                          Container(
                            width: 7,
                            height: 7,
                            decoration: const BoxDecoration(
                              color: AppColors.accent,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                        ],
                        Text(chatWhen(conversation.lastActivity),
                            style: TextStyle(
                                fontSize: 11,
                                color: unread ? c.textPrimary : c.textMuted,
                                fontWeight: unread
                                    ? FontWeight.w600
                                    : FontWeight.w400)),
                      ],
                    ),
                    if ((conversation.lastMessagePreview ?? '').isNotEmpty)
                      Text(
                        conversation.lastMessagePreview!,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 12, color: c.textTertiary),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
