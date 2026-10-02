import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/workload_forecast.dart';

/// "Future Me" on screen: the week ahead as one strip, with a warning and a
/// Rebalance action for every overloaded day, and the first gap in today
/// worth filling.
///
/// Two layouts over the same [WorkloadForecast]:
///
/// * **Compact** (the side pane): one narrow cell per day with a pressure
///   bar, then the warnings and the open slot as rows beneath.
/// * **Wide** (the detached window): one card per day with a stacked bar —
///   meetings, blocked, estimated — against the working day, the numbers
///   spelled out, and the open slot as its own callout at the end.
class WorkloadStrip extends StatelessWidget {
  const WorkloadStrip({
    super.key,
    required this.forecast,
    required this.wide,
    required this.onRebalance,
    required this.onFillSlot,
  });

  final WorkloadForecast forecast;
  final bool wide;
  final ValueChanged<RebalancePlan> onRebalance;
  final ValueChanged<OpenSlot> onFillSlot;

  @override
  Widget build(BuildContext context) {
    return wide ? _WideStrip(this) : _CompactStrip(this);
  }
}

// ---------------------------------------------------------------------------
// Compact
// ---------------------------------------------------------------------------

class _CompactStrip extends StatelessWidget {
  const _CompactStrip(this.strip);

  final WorkloadStrip strip;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final f = strip.forecast;
    final slot = f.fillableSlot;
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'WEEK AHEAD',
              style: TextStyle(
                color: c.textMuted,
                fontSize: 11,
                fontWeight: FontWeight.w600,
                letterSpacing: 0.6,
              ),
            ),
          ),
          Container(
            decoration: BoxDecoration(
              border: Border.all(color: c.separatorStrong),
              borderRadius: BorderRadius.circular(8),
            ),
            clipBehavior: Clip.antiAlias,
            child: Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 10, 8, 8),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      for (final d in f.days)
                        Expanded(child: _DayCell(day: d)),
                    ],
                  ),
                ),
                for (final plan in f.plans) ...[
                  Divider(height: 1, color: c.separator),
                  _WarningRow(plan: plan, onRebalance: strip.onRebalance),
                ],
                if (slot != null) ...[
                  Divider(height: 1, color: c.separator),
                  _OpenSlotRow(slot: slot, onFill: strip.onFillSlot),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// A day as a label and a pressure bar: how much of the day's remaining
/// capacity its demand takes, coloured by state.
class _DayCell extends StatelessWidget {
  const _DayCell({required this.day});

  final DayForecast day;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _stateColor(day, c);
    final fill = day.pressure.clamp(0.0, 1.0);
    return Tooltip(
      message: _dayTooltip(day),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 30,
            child: Align(
              alignment: Alignment.bottomCenter,
              child: Container(
                width: 18,
                height: (30 * fill).clamp(day.demandMinutes > 0 ? 3.0 : 0.0, 30.0),
                decoration: BoxDecoration(
                  color: color.withAlpha(day.isOverloaded ? 220 : 150),
                  borderRadius: BorderRadius.circular(3),
                ),
              ),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            DateFormat('EEE').format(day.day).substring(0, 2),
            style: TextStyle(
              color: day.isOverloaded ? AppColors.notification : c.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.w600,
            ),
          ),
          Text(
            '${day.day.day}',
            style: TextStyle(color: c.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }
}

class _WarningRow extends StatelessWidget {
  const _WarningRow({required this.plan, required this.onRebalance});

  final RebalancePlan plan;
  final ValueChanged<RebalancePlan> onRebalance;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final d = plan.day;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded,
              size: 14, color: AppColors.notification),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              '${_dayName(d.day)} is overloaded: ${_hours(d.demandMinutes)} '
              'to do against ${_hours(d.capacityMinutes)} free.',
              style: TextStyle(color: c.textSecondary, fontSize: 12),
            ),
          ),
          if (plan.moves.isNotEmpty)
            TextButton(
              onPressed: () => onRebalance(plan),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.accent,
                visualDensity: VisualDensity.compact,
              ),
              child: const Text('Rebalance', style: TextStyle(fontSize: 12)),
            )
          else
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Text(
                'nothing can move',
                style: TextStyle(color: c.textMuted, fontSize: 11),
              ),
            ),
        ],
      ),
    );
  }
}

class _OpenSlotRow extends StatelessWidget {
  const _OpenSlotRow({required this.slot, required this.onFill});

  final OpenSlot slot;
  final ValueChanged<OpenSlot> onFill;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = slot.suggestion!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 6, 4, 6),
      child: Row(
        children: [
          Icon(Icons.bolt_rounded,
              size: 14, color: slot.freed ? AppColors.accent : c.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '${_minutes(slot.length)} free at '
                  '${DateFormat.jm().format(slot.start)}'
                  '${slot.freed ? ' — a meeting just dropped out' : ''}',
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 12,
                    fontWeight: slot.freed ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
                Text(
                  'Use it for ${_what(s.subject, s.counterpart.displayName)}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                ),
              ],
            ),
          ),
          TextButton(
            onPressed: () => onFill(slot),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.accent,
              visualDensity: VisualDensity.compact,
            ),
            child: const Text('Schedule', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Wide
// ---------------------------------------------------------------------------

class _WideStrip extends StatelessWidget {
  const _WideStrip(this.strip);

  final WorkloadStrip strip;

  @override
  Widget build(BuildContext context) {
    final f = strip.forecast;
    final slot = f.fillableSlot;
    final planByDay = {for (final p in f.plans) p.day.day: p};
    // Sized by the tallest card, so every card shares one height without a
    // fixed number that a longer day would overflow.
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < f.days.length; i++) ...[
            if (i > 0) const SizedBox(width: 10),
            Expanded(
              child: _DayCard(
                day: f.days[i],
                plan: planByDay[f.days[i].day],
                onRebalance: strip.onRebalance,
              ),
            ),
          ],
          if (slot != null) ...[
            const SizedBox(width: 10),
            SizedBox(
              width: 260,
              child: _OpenSlotCard(slot: slot, onFill: strip.onFillSlot),
            ),
          ],
        ],
      ),
    );
  }
}

/// One day of the week ahead: a stacked bar of meetings / blocked /
/// estimated against the working day, the numbers under it, and the
/// Rebalance action when the day is overloaded.
class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.day,
    required this.plan,
    required this.onRebalance,
  });

  final DayForecast day;
  final RebalancePlan? plan;
  final ValueChanged<RebalancePlan> onRebalance;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = _stateColor(day, c);
    final estimated = day.unscheduledLanding.length * day.minutesPerCommitment +
        day.tasksDue * day.minutesPerTask;
    final free = day.freeMinutes < 0 ? 0 : day.freeMinutes;
    final parts = <String>[
      if (day.meetingMinutes > 0) '${_hours(day.meetingMinutes)} meetings',
      if (day.blockedMinutes > 0) '${_hours(day.blockedMinutes)} blocked',
      if (day.unscheduledLanding.isNotEmpty)
        '${day.unscheduledLanding.length} '
            '${day.unscheduledLanding.length == 1 ? 'commitment' : 'commitments'}',
      if (day.tasksDue > 0) '${day.tasksDue} ${day.tasksDue == 1 ? 'task' : 'tasks'}',
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        border: Border.all(
          color: day.isOverloaded ? AppColors.notification.withAlpha(140) : c.separatorStrong,
        ),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _dayName(day.day),
                  style: TextStyle(
                    color: c.textSecondary,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              if (day.isOverloaded)
                _Badge('Overloaded', AppColors.notification)
              else if (day.isTight)
                _Badge('Tight', const Color(0xFFF59E0B))
              else
                Text(
                  '${_hours(free)} free',
                  style: TextStyle(color: c.textMuted, fontSize: 11),
                ),
            ],
          ),
          const SizedBox(height: 8),
          _StackedBar(
            meeting: day.meetingMinutes,
            blocked: day.blockedMinutes,
            estimated: estimated,
            total: day.workingMinutes,
            overloaded: day.isOverloaded,
            accent: color,
          ),
          const SizedBox(height: 6),
          Text(
            parts.isEmpty ? 'Clear.' : parts.join(' · '),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
          if (plan != null) ...[
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Text(
                    'Over by ${_hours(day.demandMinutes - day.capacityMinutes)}',
                    style: const TextStyle(
                      color: AppColors.notification,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (plan!.moves.isNotEmpty)
                  TextButton(
                    onPressed: () => onRebalance(plan!),
                    style: TextButton.styleFrom(
                      foregroundColor: AppColors.accent,
                      visualDensity: VisualDensity.compact,
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      minimumSize: const Size(0, 26),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: const Text('Rebalance', style: TextStyle(fontSize: 12)),
                  )
                else
                  Text(
                    'nothing can move',
                    style: TextStyle(color: c.textMuted, fontSize: 11),
                  ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

/// Meetings, blocked and estimated time as segments of the working day; when
/// the three exceed it the bar fills and the free segment vanishes.
class _StackedBar extends StatelessWidget {
  const _StackedBar({
    required this.meeting,
    required this.blocked,
    required this.estimated,
    required this.total,
    required this.overloaded,
    required this.accent,
  });

  final int meeting;
  final int blocked;
  final int estimated;
  final int total;
  final bool overloaded;
  final Color accent;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final used = meeting + blocked + estimated;
    final free = used >= total ? 0 : total - used;
    Widget seg(int flex, Color color) =>
        flex <= 0 ? const SizedBox.shrink() : Expanded(flex: flex, child: ColoredBox(color: color));
    return Container(
      height: 10,
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: overloaded ? AppColors.notification : c.separator),
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        children: [
          seg(meeting, c.stateIcon),
          seg(blocked, AppColors.accent.withAlpha(190)),
          seg(estimated, const Color(0xFFF59E0B).withAlpha(170)),
          seg(free, Colors.transparent),
        ],
      ),
    );
  }
}

class _OpenSlotCard extends StatelessWidget {
  const _OpenSlotCard({required this.slot, required this.onFill});

  final OpenSlot slot;
  final ValueChanged<OpenSlot> onFill;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final s = slot.suggestion!;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(slot.freed ? 24 : 12),
        border: Border.all(color: AppColors.accent.withAlpha(slot.freed ? 160 : 80)),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.bolt_rounded, size: 14, color: AppColors.accent),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  slot.freed ? 'Just freed up' : 'Open today',
                  style: const TextStyle(
                    color: AppColors.accent,
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            '${_minutes(slot.length)} at ${DateFormat.jm().format(slot.start)}',
            style: TextStyle(
              color: c.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            _what(s.subject, s.counterpart.displayName),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: c.textMuted, fontSize: 11),
          ),
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: () => onFill(slot),
              style: TextButton.styleFrom(
                foregroundColor: AppColors.accent,
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: const Size(0, 26),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              icon: const Icon(Icons.event_available_rounded, size: 14),
              label: const Text('Schedule', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label, this.color);

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withAlpha(28),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(
        label,
        style: TextStyle(color: color, fontSize: 10, fontWeight: FontWeight.w700),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Color _stateColor(DayForecast d, AppColors c) {
  if (d.isOverloaded) return AppColors.notification;
  if (d.isTight) return const Color(0xFFF59E0B);
  return AppColors.accent;
}

String _dayName(DateTime day) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Tomorrow';
  return DateFormat('EEEE d').format(day);
}

String _dayTooltip(DayForecast d) {
  final lines = <String>[
    DateFormat('EEEE d MMMM').format(d.day),
    '${_hours(d.meetingMinutes)} of meetings',
    if (d.blockedMinutes > 0) '${_hours(d.blockedMinutes)} blocked',
    if (d.unscheduledLanding.isNotEmpty)
      '${d.unscheduledLanding.length} commitments landing',
    if (d.tasksDue > 0) '${d.tasksDue} tasks due',
    d.isOverloaded
        ? 'Over by ${_hours(d.demandMinutes - d.capacityMinutes)}'
        : '${_hours(d.freeMinutes)} free',
  ];
  return lines.join('\n');
}

String _hours(int minutes) {
  if (minutes <= 0) return '0 h';
  final h = minutes / 60;
  return h == h.roundToDouble() ? '${h.round()} h' : '${h.toStringAsFixed(1)} h';
}

String _minutes(Duration d) =>
    d.inMinutes < 60 ? '${d.inMinutes} min' : _hours(d.inMinutes);

String _what(String subject, String who) =>
    subject.trim().isEmpty ? who : '$subject · $who';
