import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../domain/entities/calendar_event.dart';
import '../blocs/calendar/calendar_bloc.dart';
import '../blocs/calendar/calendar_event.dart';
import '../blocs/calendar/calendar_state.dart';

class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return ColoredBox(
      color: c.surfaceBase,
      child: BlocBuilder<CalendarBloc, CalendarState>(
        builder: (context, state) {
          return Column(
            children: [
              _WeekNavBar(state: state),
              Divider(height: 1, color: c.separatorStrong),
              Expanded(
                child: switch (state) {
                  CalendarLoading() => Center(
                      child: CircularProgressIndicator(
                        color: AppColors.accent,
                        strokeWidth: 2,
                      ),
                    ),
                  CalendarLoaded(:final events, :final weekStart) =>
                    _WeekView(weekStart: weekStart, events: events),
                  CalendarError(:final message, :final weekStart) =>
                    _WeekView(weekStart: weekStart, events: const [], errorMessage: message),
                  CalendarInitial() => const SizedBox.shrink(),
                },
              ),
            ],
          );
        },
      ),
    );
  }
}

class _WeekNavBar extends StatelessWidget {
  const _WeekNavBar({required this.state});
  final CalendarState state;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final weekStart = state.weekStart;
    final weekEnd = weekStart.add(const Duration(days: 6));
    final isCurrentWeek = _isCurrentWeek(weekStart);

    final rangeLabel = _buildRangeLabel(weekStart, weekEnd);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          Text(
            rangeLabel,
            style: TextStyle(
              color: c.textPrimary,
              fontSize: 15,
              fontWeight: FontWeight.w600,
              letterSpacing: -0.3,
            ),
          ),
          const SizedBox(width: 12),
          if (!isCurrentWeek)
            _NavChip(
              label: 'Today',
              onTap: () => _goToToday(context),
            ),
          const Spacer(),
          _IconNavButton(
            icon: Icons.chevron_left_rounded,
            tooltip: 'Previous week',
            onTap: () => _navigate(context, -7),
          ),
          const SizedBox(width: 4),
          _IconNavButton(
            icon: Icons.chevron_right_rounded,
            tooltip: 'Next week',
            onTap: () => _navigate(context, 7),
          ),
        ],
      ),
    );
  }

  String _buildRangeLabel(DateTime start, DateTime end) {
    if (start.month == end.month) {
      return '${DateFormat('MMMM d').format(start)} – ${DateFormat('d, yyyy').format(end)}';
    } else if (start.year == end.year) {
      return '${DateFormat('MMM d').format(start)} – ${DateFormat('MMM d, yyyy').format(end)}';
    }
    return '${DateFormat('MMM d, yyyy').format(start)} – ${DateFormat('MMM d, yyyy').format(end)}';
  }

  bool _isCurrentWeek(DateTime weekStart) {
    final today = DateTime.now();
    final currentMonday = _mondayOfWeek(today);
    return weekStart.year == currentMonday.year &&
        weekStart.month == currentMonday.month &&
        weekStart.day == currentMonday.day;
  }

  DateTime _mondayOfWeek(DateTime date) {
    final daysFromMonday = (date.weekday - 1) % 7;
    return DateTime(date.year, date.month, date.day - daysFromMonday);
  }

  void _goToToday(BuildContext context) {
    final today = DateTime.now();
    final monday = _mondayOfWeek(today);
    context.read<CalendarBloc>().add(CalendarWeekNavigated(weekStart: monday));
  }

  void _navigate(BuildContext context, int days) {
    final newWeekStart = state.weekStart.add(Duration(days: days));
    context.read<CalendarBloc>().add(CalendarWeekNavigated(weekStart: newWeekStart));
  }
}

class _NavChip extends StatelessWidget {
  const _NavChip({required this.label, required this.onTap});
  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: AppColors.accent.withAlpha(30),
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: AppColors.accent.withAlpha(80)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: AppColors.accent,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}

class _IconNavButton extends StatelessWidget {
  const _IconNavButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 20, color: c.textMuted),
        ),
      ),
    );
  }
}

// ─── Week view ───────────────────────────────────────────────────────────────

class _WeekView extends StatefulWidget {
  const _WeekView({
    required this.weekStart,
    required this.events,
    this.errorMessage,
  });

  final DateTime weekStart;
  final List<CalendarEvent> events;
  final String? errorMessage;

  @override
  State<_WeekView> createState() => _WeekViewState();
}

class _WeekViewState extends State<_WeekView> {
  static const double _hourHeight = 64.0;
  static const double _timeColumnWidth = 56.0;
  static const int _totalHours = 24;

  late final ScrollController _scrollController;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(
      initialScrollOffset: 7 * _hourHeight, // start scrolled to 7am
    );
  }

  @override
  void dispose() {
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final allDayEvents = widget.events.where((e) => e.isAllDay).toList();
    final timedEvents = widget.events.where((e) => !e.isAllDay).toList();

    return Column(
      children: [
        _DayHeader(weekStart: widget.weekStart, timeColumnWidth: _timeColumnWidth),
        if (allDayEvents.isNotEmpty)
          _AllDayStrip(
            weekStart: widget.weekStart,
            events: allDayEvents,
            timeColumnWidth: _timeColumnWidth,
          ),
        Divider(height: 1, color: c.separatorStrong),
        if (widget.errorMessage != null)
          _ErrorBanner(message: widget.errorMessage!),
        Expanded(
          child: SingleChildScrollView(
            controller: _scrollController,
            child: SizedBox(
              height: _hourHeight * _totalHours,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _TimeColumn(hourHeight: _hourHeight, totalHours: _totalHours, width: _timeColumnWidth),
                  VerticalDivider(width: 1, color: c.separatorStrong),
                  Expanded(
                    child: _DayColumns(
                      weekStart: widget.weekStart,
                      events: timedEvents,
                      hourHeight: _hourHeight,
                      totalHours: _totalHours,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.weekStart,
    required this.timeColumnWidth,
  });

  final DateTime weekStart;
  final double timeColumnWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final today = DateTime.now();

    return Container(
      color: c.surfacePanel,
      child: Row(
        children: [
          SizedBox(width: timeColumnWidth + 1), // +1 for divider
          ...List.generate(7, (i) {
            final day = weekStart.add(Duration(days: i));
            final isToday = _isSameDay(day, today);
            return Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(color: c.separator, width: 0.5),
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      DateFormat('EEE').format(day).toUpperCase(),
                      style: TextStyle(
                        color: isToday ? AppColors.accent : c.textMuted,
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                        letterSpacing: 0.5,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Container(
                      width: 28,
                      height: 28,
                      decoration: isToday
                          ? const BoxDecoration(
                              color: AppColors.accent,
                              shape: BoxShape.circle,
                            )
                          : null,
                      child: Center(
                        child: Text(
                          '${day.day}',
                          style: TextStyle(
                            color: isToday ? Colors.white : c.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;
}

class _AllDayStrip extends StatelessWidget {
  const _AllDayStrip({
    required this.weekStart,
    required this.events,
    required this.timeColumnWidth,
  });

  final DateTime weekStart;
  final List<CalendarEvent> events;
  final double timeColumnWidth;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: c.surfacePanel,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: timeColumnWidth,
            child: Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'All day',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: c.textMuted,
                  fontSize: 9,
                  letterSpacing: 0.3,
                ),
              ),
            ),
          ),
          Container(width: 1, color: c.separatorStrong),
          Expanded(
            child: Row(
              children: List.generate(7, (i) {
                final day = weekStart.add(Duration(days: i));
                final dayEvents = events.where((e) => _isSameDay(e.start, day)).toList();
                return Expanded(
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                    decoration: BoxDecoration(
                      border: Border(
                        left: BorderSide(color: c.separator, width: 0.5),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: dayEvents
                          .map((e) => _AllDayEventChip(event: e))
                          .toList(),
                    ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) {
    final localA = a.toLocal();
    final localB = b.toLocal();
    return localA.year == localB.year &&
        localA.month == localB.month &&
        localA.day == localB.day;
  }
}

class _AllDayEventChip extends StatelessWidget {
  const _AllDayEventChip({required this.event});
  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 1),
      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(40),
        borderRadius: BorderRadius.circular(3),
        border: Border(left: BorderSide(color: AppColors.accent, width: 2)),
      ),
      child: Text(
        event.subject,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 11,
          fontWeight: FontWeight.w500,
        ),
        overflow: TextOverflow.ellipsis,
      ),
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner({required this.message});
  final String message;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: c.errorBannerBg,
      child: Text(
        'Could not load events: $message',
        style: TextStyle(color: c.errorBannerText, fontSize: 12),
      ),
    );
  }
}

class _TimeColumn extends StatelessWidget {
  const _TimeColumn({
    required this.hourHeight,
    required this.totalHours,
    required this.width,
  });

  final double hourHeight;
  final int totalHours;
  final double width;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      width: width,
      child: Stack(
        children: List.generate(totalHours, (hour) {
          return Positioned(
            top: hour * hourHeight - 7,
            left: 0,
            right: 0,
            child: hour == 0
                ? const SizedBox.shrink()
                : Text(
                    DateFormat('h a').format(DateTime(2000, 1, 1, hour)),
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      color: c.textMuted,
                      fontSize: 10,
                      letterSpacing: 0.2,
                    ),
                  ),
          );
        }),
      ),
    );
  }
}

class _DayColumns extends StatelessWidget {
  const _DayColumns({
    required this.weekStart,
    required this.events,
    required this.hourHeight,
    required this.totalHours,
  });

  final DateTime weekStart;
  final List<CalendarEvent> events;
  final double hourHeight;
  final int totalHours;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final today = DateTime.now();

    return Row(
      children: List.generate(7, (i) {
        final day = weekStart.add(Duration(days: i));
        final isToday = _isSameDay(day, today);
        final dayEvents = _eventsForDay(day);

        return Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: isToday ? AppColors.accent.withAlpha(6) : null,
              border: Border(
                left: BorderSide(color: c.separator, width: 0.5),
              ),
            ),
            child: Stack(
              children: [
                // Hour grid lines
                ...List.generate(totalHours, (h) => Positioned(
                  top: h * hourHeight,
                  left: 0,
                  right: 0,
                  child: Divider(
                    height: 0.5,
                    color: h == 0 ? Colors.transparent : c.separator,
                  ),
                )),
                // Events
                ...dayEvents.map((e) => _PositionedEvent(
                  event: e,
                  dayStart: DateTime(day.year, day.month, day.day),
                  hourHeight: hourHeight,
                )),
              ],
            ),
          ),
        );
      }),
    );
  }

  bool _isSameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  List<CalendarEvent> _eventsForDay(DateTime day) {
    return events.where((e) {
      final local = e.start.toLocal();
      return local.year == day.year &&
          local.month == day.month &&
          local.day == day.day;
    }).toList();
  }
}

class _PositionedEvent extends StatelessWidget {
  const _PositionedEvent({
    required this.event,
    required this.dayStart,
    required this.hourHeight,
  });

  final CalendarEvent event;
  final DateTime dayStart;
  final double hourHeight;

  @override
  Widget build(BuildContext context) {
    final start = event.start.toLocal();
    final end = event.end.toLocal();
    final minutesPerPixel = hourHeight / 60;

    final startMinutes = start.hour * 60 + start.minute;
    final durationMinutes = end.difference(start).inMinutes.clamp(15, 24 * 60).toDouble();

    final top = startMinutes * minutesPerPixel;
    final height = durationMinutes * minutesPerPixel;

    return Positioned(
      top: top,
      left: 2,
      right: 2,
      height: height,
      child: _EventTile(event: event, compact: height < 36),
    );
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({required this.event, required this.compact});

  final CalendarEvent event;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final color = _colorForStatus(event.status);

    return Container(
      padding: EdgeInsets.symmetric(
        horizontal: 4,
        vertical: compact ? 1 : 3,
      ),
      decoration: BoxDecoration(
        color: color.withAlpha(40),
        borderRadius: BorderRadius.circular(3),
        border: Border(left: BorderSide(color: color, width: 2.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            event.subject,
            style: TextStyle(
              color: color,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              height: 1.2,
            ),
            maxLines: compact ? 1 : 2,
            overflow: TextOverflow.ellipsis,
          ),
          if (!compact && event.location != null) ...[
            const SizedBox(height: 1),
            Text(
              event.location!,
              style: TextStyle(
                color: color.withAlpha(180),
                fontSize: 10,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ],
      ),
    );
  }

  Color _colorForStatus(CalendarEventStatus status) {
    return switch (status) {
      CalendarEventStatus.free => const Color(0xFF34A853),
      CalendarEventStatus.tentative => const Color(0xFFFBBC04),
      CalendarEventStatus.outOfOffice => const Color(0xFFEA4335),
      CalendarEventStatus.workingElsewhere => const Color(0xFF9E9E9E),
      CalendarEventStatus.busy => AppColors.accent,
    };
  }
}
