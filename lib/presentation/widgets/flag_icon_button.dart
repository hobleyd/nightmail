import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// A flag icon that shows a due-date context menu on right-click (secondary
/// tap) and calls [onTap] on a plain left-click.
///
/// [onSchedule] is called with the chosen [DateTime] when the user picks an
/// option from the context menu (Today / This Week / Next Week / Custom).
class FlagIconButton extends StatelessWidget {
  const FlagIconButton({
    super.key,
    required this.onTap,
    required this.onSchedule,
    this.color,
    this.size = 15,
  });

  final VoidCallback onTap;
  final void Function(DateTime dueDate) onSchedule;
  final Color? color;
  final double size;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onSecondaryTapUp: (details) =>
          _showMenu(context, details.globalPosition),
      child: IconButton(
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
      _DueDateOption.thisWeek => _thisFriday(now),
      _DueDateOption.nextWeek => _nextMonday(now),
      _DueDateOption.custom => DateTime(now.year, now.month, now.day),
    };
  }

  static DateTime _thisFriday(DateTime from) {
    final daysUntilFriday = (DateTime.friday - from.weekday + 7) % 7;
    // If today is already Friday, push to next Friday.
    final days = daysUntilFriday == 0 ? 7 : daysUntilFriday;
    final d = from.add(Duration(days: days));
    return DateTime(d.year, d.month, d.day);
  }

  static DateTime _nextMonday(DateTime from) {
    final daysUntilMonday = (DateTime.monday - from.weekday + 7) % 7;
    final days = daysUntilMonday == 0 ? 7 : daysUntilMonday;
    final d = from.add(Duration(days: days));
    return DateTime(d.year, d.month, d.day);
  }
}

enum _DueDateOption { today, thisWeek, nextWeek, custom }

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
