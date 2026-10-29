import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../infrastructure/notifications/meeting_reminder_board.dart';

/// The body of the meeting-reminders dialog — one row per meeting, each at the
/// latest alert of its countdown — shared by the desktop window and the
/// in-app dialog on iOS and Android.
///
/// Laid out at its natural height, nothing fixed: the caller puts it in a
/// scroll view, and the desktop window measures it and sizes itself to fit.
class MeetingReminderList extends StatelessWidget {
  const MeetingReminderList({
    super.key,
    required this.rows,
    required this.onDismiss,
    required this.onDismissAll,
  });

  final List<MeetingReminderRow> rows;
  final ValueChanged<MeetingReminderRow> onDismiss;
  final VoidCallback onDismissAll;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 28),
            child: Row(
              children: [
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: AppColors.accent.withAlpha(30),
                    borderRadius: BorderRadius.circular(7),
                  ),
                  child: const Icon(
                    Icons.event_rounded,
                    color: AppColors.accent,
                    size: 16,
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    rows.length == 1
                        ? 'Meeting Reminder'
                        : '${rows.length} Meeting Reminders',
                    style: TextStyle(
                      color: c.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          for (var i = 0; i < rows.length; i++) ...[
            if (i > 0) Divider(height: 1, color: c.separator),
            _MeetingReminderTile(
              row: rows[i],
              onDismiss: () => onDismiss(rows[i]),
            ),
          ],
          const SizedBox(height: 8),
          FilledButton(
            onPressed: onDismissAll,
            style: FilledButton.styleFrom(
              backgroundColor: AppColors.accent,
              padding: const EdgeInsets.symmetric(vertical: 10),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              rows.length == 1 ? 'Dismiss' : 'Dismiss All',
              style: const TextStyle(fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }
}

class _MeetingReminderTile extends StatelessWidget {
  const _MeetingReminderTile({required this.row, required this.onDismiss});

  final MeetingReminderRow row;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final start = row.start.toLocal();
    final location = row.location;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  row.title.isEmpty ? '(No Title)' : row.title,
                  style: TextStyle(
                    color: c.textPrimary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  [
                    DateFormat('h:mm a').format(start),
                    if (location != null && location.isNotEmpty) location,
                  ].join(' · '),
                  style: TextStyle(color: c.textMuted, fontSize: 12),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                Text(
                  row.label,
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Dismiss',
            icon: Icon(Icons.close_rounded, size: 16, color: c.textMuted),
            onPressed: onDismiss,
          ),
        ],
      ),
    );
  }
}
