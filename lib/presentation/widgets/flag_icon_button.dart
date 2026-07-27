import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/business_days.dart';

/// A flag icon that shows a due-date context menu on right-click (secondary
/// tap) and calls [onTap] on a plain left-click.
///
/// [onSchedule] is called with the chosen [DateTime] when the user picks an
/// option from the context menu (Today / Tomorrow / 3 Days / This Week /
/// Next Week / Custom).
class FlagIconButton extends StatelessWidget {
  const FlagIconButton({
    super.key,
    required this.onTap,
    required this.onSchedule,
    this.color,
    this.size = 15,
    this.focusNode,
  });

  final VoidCallback onTap;
  final void Function(DateTime dueDate) onSchedule;
  final Color? color;
  final double size;
  final FocusNode? focusNode;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showMenu(context, details.globalPosition),
      child: IconButton(
        focusNode: focusNode,
        icon: Icon(
          Icons.flag_outlined,
          size: size,
          color: color ?? AppColors.accent.withValues(alpha: 0.7),
        ),
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
        onPressed: onTap,
      ),
    );
  }

  void _showMenu(BuildContext context, Offset globalPosition) async {
    final rect = Rect.fromLTWH(
      globalPosition.dx,
      globalPosition.dy,
      0,
      0,
    );

    final chosen = await showMenu<_DueDateOption>(
      context: context,
      position: RelativeRect.fromRect(
        rect,
        Offset.zero & MediaQuery.sizeOf(context),
      ),
      items: [
        PopupMenuItem(
          value: _DueDateOption.today,
          child: _MenuRow(icon: Icons.today_outlined, label: 'Today'),
        ),
        PopupMenuItem(
          value: _DueDateOption.tomorrow,
          child: _MenuRow(icon: Icons.event_outlined, label: 'Tomorrow'),
        ),
        PopupMenuItem(
          value: _DueDateOption.threeDays,
          child: _MenuRow(icon: Icons.more_time_outlined, label: '3 Days'),
        ),
        PopupMenuItem(
          value: _DueDateOption.thisWeek,
          child: _MenuRow(icon: Icons.view_week_outlined, label: 'This Week'),
        ),
        PopupMenuItem(
          value: _DueDateOption.nextWeek,
          child: _MenuRow(icon: Icons.date_range_outlined, label: 'Next Week'),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: _DueDateOption.custom,
          child: _MenuRow(icon: Icons.calendar_month_outlined, label: 'Custom…'),
        ),
      ],
    );

    if (chosen == null || !context.mounted) return;

    if (chosen == _DueDateOption.custom) {
      final picked = await showDatePicker(
        context: context,
        initialDate: DateTime.now(),
        firstDate: DateTime.now(),
        lastDate: DateTime.now().add(const Duration(days: 365 * 5)),
      );
      if (picked != null) onSchedule(picked);
      return;
    }

    onSchedule(_resolveDate(chosen));
  }

  static DateTime _resolveDate(_DueDateOption option) {
    final now = DateTime.now();
    return switch (option) {
      _DueDateOption.today => DateTime(now.year, now.month, now.day),
      _DueDateOption.tomorrow => addBusinessDays(now, 1),
      _DueDateOption.threeDays => addBusinessDays(now, 3),
      _DueDateOption.thisWeek => _thisWeekFriday(now),
      _DueDateOption.nextWeek => _nextWeekFriday(now),
      _DueDateOption.custom => DateTime(now.year, now.month, now.day),
    };
  }

  /// Friday morning of the current week, or of the following week if this
  /// week's Friday morning has already passed (Friday afternoon onwards, and
  /// the weekend).
  static DateTime _thisWeekFriday(DateTime from) {
    final friday = _fridayMorningOfWeek(from);
    return from.isBefore(friday) ? friday : _plusWeek(friday);
  }

  /// Friday morning of the week after the current one.
  static DateTime _nextWeekFriday(DateTime from) =>
      _plusWeek(_fridayMorningOfWeek(from));

  /// Friday morning of the Mon–Sun week containing [from]. May be in the past
  /// when [from] falls on the weekend.
  static DateTime _fridayMorningOfWeek(DateTime from) {
    final offset = DateTime.friday - from.weekday;
    return DateTime(from.year, from.month, from.day + offset, followUpMorningHour);
  }

  // Rebuild rather than add a Duration so the wall-clock hour survives a
  // daylight-saving transition.
  static DateTime _plusWeek(DateTime d) =>
      DateTime(d.year, d.month, d.day + 7, d.hour, d.minute);
}

enum _DueDateOption { today, tomorrow, threeDays, thisWeek, nextWeek, custom }

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        Icon(icon, size: 16, color: c.textMuted),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(fontSize: 13, color: c.textPrimary)),
      ],
    );
  }
}
