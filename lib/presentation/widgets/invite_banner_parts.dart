import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/meeting_invite.dart';

/// The pieces every meeting banner in the reading pane is built from.
///
/// Split out of `reading_pane.dart` so a banner can live in its own file and be
/// pumped on its own in a test — the reading pane itself needs an
/// `AccountManager`, a webview and four blocs before it will build.

/// The meeting's date and times in the reader's own zone, for a banner header.
String formatMeetingTime(MeetingInvite invite) {
  final start = invite.meetingStart;
  final end = invite.meetingEnd;
  if (start == null) return '';
  final local = start.toLocal();
  final datePart = DateFormat('EEE d MMM yyyy').format(local);
  if (invite.isAllDay) return datePart;
  final startTime = DateFormat('h:mm a').format(local);
  if (end != null) {
    final endTime = DateFormat('h:mm a').format(end.toLocal());
    return '$datePart  $startTime – $endTime';
  }
  return '$datePart  $startTime';
}

/// The small tinted action button a banner offers — Accept, Decline, Add to
/// calendar, Retry.
class InviteResponseButton extends StatefulWidget {
  const InviteResponseButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback onPressed;

  @override
  State<InviteResponseButton> createState() => _InviteResponseButtonState();
}

class _InviteResponseButtonState extends State<InviteResponseButton> {
  bool _isPressed = false;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return GestureDetector(
      onTap: widget.onPressed,
      onTapDown: (_) => setState(() => _isPressed = true),
      onTapUp: (_) => setState(() => _isPressed = false),
      onTapCancel: () => setState(() => _isPressed = false),
      child: AnimatedScale(
        scale: _isPressed ? 0.93 : 1.0,
        duration: const Duration(milliseconds: 70),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: _isPressed
                ? AppColors.accent.withAlpha(70)
                : AppColors.accent.withAlpha(30),
            borderRadius: BorderRadius.circular(5),
            border: Border.all(
                color: AppColors.accent.withAlpha(80), width: 0.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 11, color: c.textTertiary),
              const SizedBox(width: 4),
              Text(
                widget.label,
                style: TextStyle(color: c.textTertiary, fontSize: 11),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
