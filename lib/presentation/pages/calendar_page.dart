import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/timezone_utils.dart';
import '../../domain/entities/calendar_event.dart';
import '../../infrastructure/accounts/account.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/calendar/calendar_bloc.dart';
import '../blocs/calendar/calendar_event.dart';
import '../blocs/calendar/calendar_state.dart';
import '../widgets/event_edit_dialog.dart';

class CalendarPage extends StatelessWidget {
  const CalendarPage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: ColoredBox(
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
          if (state case final CalendarLoaded loaded when loaded.selectedEventIds.isNotEmpty) ...[
            Tooltip(
              message: 'Remove selected event${loaded.selectedEventIds.length > 1 ? 's' : ''}',
              child: InkWell(
                onTap: () => _confirmAndDeleteSelected(context, loaded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(Icons.delete_outline_rounded, size: 18, color: Colors.red.shade400),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
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
          const SizedBox(width: 8),
          _NewEventButton(calendarBloc: context.read<CalendarBloc>()),
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

String? _accountId(BuildContext context) {
  final state = context.read<AccountCubit>().state;
  if (state is AccountsLoaded) return state.activeAccount.id;
  return null;
}

bool _isO365Account(BuildContext context) {
  final state = context.read<AccountCubit>().state;
  if (state is AccountsLoaded) return state.activeAccount is MicrosoftAccount;
  return false;
}

class _NewEventButton extends StatelessWidget {
  const _NewEventButton({required this.calendarBloc});
  final CalendarBloc calendarBloc;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: 'New event',
      child: InkWell(
        onTap: () => EventEditDialog.show(
          context,
          accountId: _accountId(context),
          isO365Account: _isO365Account(context),
        ),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: const [
              Icon(Icons.add_rounded, size: 14, color: Colors.white),
              SizedBox(width: 4),
              Text(
                'New Event',
                style: TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w500),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ─── Day panel (today only, shown inline in the main window) ─────────────────

class CalendarDayPanel extends StatefulWidget {
  const CalendarDayPanel({super.key, required this.onClose});
  final VoidCallback onClose;

  @override
  State<CalendarDayPanel> createState() => _CalendarDayPanelState();
}

class _CalendarDayPanelState extends State<CalendarDayPanel> {
  static const double _hourHeight = 64.0;
  static const double _timeColumnWidth = 48.0;
  static const int _totalHours = 24;
  late final ScrollController _scrollController;
  Offset? _tapPosition;
  late DateTime _selectedDay;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _scrollController = ScrollController(initialScrollOffset: 7 * _hourHeight);
    final now = DateTime.now();
    _selectedDay = DateTime(now.year, now.month, now.day);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  bool _isSameDay(DateTime a, DateTime b) {
    final la = a.toLocal();
    final lb = b.toLocal();
    return la.year == lb.year && la.month == lb.month && la.day == lb.day;
  }

  DateTime _mondayOfWeek(DateTime date) {
    final daysFromMonday = (date.weekday - 1) % 7;
    return DateTime(date.year, date.month, date.day - daysFromMonday);
  }

  void _navigateDay(BuildContext context, int delta) {
    final newDay = _selectedDay.add(Duration(days: delta));
    setState(() => _selectedDay = newDay);
    final state = context.read<CalendarBloc>().state;
    final weekStart = state.weekStart;
    final weekEnd = weekStart.add(const Duration(days: 6));
    final inRange = !newDay.isBefore(weekStart) && !newDay.isAfter(weekEnd);
    if (!inRange) {
      context.read<CalendarBloc>().add(
            CalendarWeekNavigated(weekStart: _mondayOfWeek(newDay)),
          );
    }
  }

  void _goToToday(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    setState(() => _selectedDay = today);
    final state = context.read<CalendarBloc>().state;
    final weekStart = state.weekStart;
    final weekEnd = weekStart.add(const Duration(days: 6));
    final inRange = !today.isBefore(weekStart) && !today.isAfter(weekEnd);
    if (!inRange) {
      context.read<CalendarBloc>().add(
            CalendarWeekNavigated(weekStart: _mondayOfWeek(today)),
          );
    }
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final now = DateTime.now();
    final isToday = _isSameDay(_selectedDay, now);

    return MediaQuery(
      data: MediaQuery.of(context).copyWith(textScaler: TextScaler.noScaling),
      child: BlocBuilder<CalendarBloc, CalendarState>(
      builder: (context, state) {
        final isLoading = state is CalendarLoading;
        final allDayEvents = switch (state) {
          CalendarLoaded(:final events) =>
            events.where((e) => e.isAllDay && _isSameDay(e.start, _selectedDay)).toList(),
          _ => <CalendarEvent>[],
        };
        final timedEvents = switch (state) {
          CalendarLoaded(:final events) =>
            events.where((e) => !e.isAllDay && _isSameDay(e.start, _selectedDay)).toList(),
          _ => <CalendarEvent>[],
        };

        return ColoredBox(
          color: c.surfaceBase,
          child: Column(
            children: [
              _DayPanelHeader(
                selectedDay: _selectedDay,
                isToday: isToday,
                onPrev: () => _navigateDay(context, -1),
                onNext: () => _navigateDay(context, 1),
                onToday: () => _goToToday(context),
                onClose: widget.onClose,
              ),
              Divider(height: 1, color: c.separatorStrong),
              if (allDayEvents.isNotEmpty) ...[
                _DayPanelAllDayStrip(events: allDayEvents),
                Divider(height: 1, color: c.separatorStrong),
              ],
              if (isLoading)
                const Expanded(
                  child: Center(
                    child: CircularProgressIndicator(
                      color: AppColors.accent, strokeWidth: 2),
                  ),
                )
              else
                Expanded(
                  child: SingleChildScrollView(
                    controller: _scrollController,
                    child: SizedBox(
                      height: _hourHeight * _totalHours,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _TimeColumn(
                            hourHeight: _hourHeight,
                            totalHours: _totalHours,
                            width: _timeColumnWidth,
                          ),
                          VerticalDivider(width: 1, color: c.separatorStrong),
                          Expanded(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => context.read<CalendarBloc>().add(const CalendarSelectionCleared()),
                              onDoubleTapDown: (d) =>
                                  _tapPosition = d.localPosition,
                              onDoubleTap: () {
                                final pos = _tapPosition;
                                if (pos == null) return;
                                final totalMinutes =
                                    (pos.dy / _hourHeight * 60).round();
                                final roundedMinutes =
                                    (totalMinutes / 30).floor() * 30;
                                final hour =
                                    (roundedMinutes ~/ 60).clamp(0, 23);
                                final minute = roundedMinutes % 60;
                                final start = DateTime(_selectedDay.year,
                                    _selectedDay.month, _selectedDay.day, hour, minute);
                                EventEditDialog.show(
                                  context,
                                  initialStart: start,
                                  accountId: _accountId(context),
                                  isO365Account: _isO365Account(context),
                                );
                              },
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final layout = _computeOverlapLayout(timedEvents);
                                  return Stack(
                                    children: [
                                      ...List.generate(
                                        _totalHours,
                                        (h) => Positioned(
                                          top: h * _hourHeight,
                                          left: 0,
                                          right: 0,
                                          child: Divider(
                                            height: 0.5,
                                            color: h == 0
                                                ? Colors.transparent
                                                : c.separator,
                                          ),
                                        ),
                                      ),
                                      ...timedEvents.map((e) {
                                        final span = layout[e.id] ??
                                            const _ColumnSpan(index: 0, total: 1);
                                        final colW =
                                            (constraints.maxWidth - 4) / span.total;
                                        return _PositionedEvent(
                                          event: e,
                                          dayStart: DateTime(_selectedDay.year,
                                              _selectedDay.month, _selectedDay.day),
                                          hourHeight: _hourHeight,
                                          left: 2.0 + span.index * colW,
                                          width: colW -
                                              (span.total > 1 ? 1.0 : 0.0),
                                        );
                                      }),
                                      if (isToday)
                                        _CurrentTimeLine(
                                          now: DateTime.now(),
                                          hourHeight: _hourHeight,
                                        ),
                                    ],
                                  );
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
            ],
          ),
        );
      },
      ),
    );
  }
}

class _DayPanelHeader extends StatelessWidget {
  const _DayPanelHeader({
    required this.selectedDay,
    required this.isToday,
    required this.onPrev,
    required this.onNext,
    required this.onToday,
    required this.onClose,
  });
  final DateTime selectedDay;
  final bool isToday;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onToday;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return SizedBox(
      height: 48,
      child: Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
      child: Row(
        children: [
          Container(
            width: 28,
            height: 28,
            decoration: BoxDecoration(
              color: isToday ? AppColors.accent : c.surfacePanel,
              shape: BoxShape.circle,
              border: isToday ? null : Border.all(color: c.separator),
            ),
            child: Center(
              child: Text(
                '${selectedDay.day}',
                style: TextStyle(
                  color: isToday ? Colors.white : c.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                DateFormat('EEEE').format(selectedDay),
                style: TextStyle(
                  color: c.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  letterSpacing: -0.2,
                ),
              ),
              Text(
                DateFormat('MMMM y').format(selectedDay),
                style: TextStyle(color: c.textMuted, fontSize: 10),
              ),
            ],
          ),
          const Spacer(),
          _IconNavButton(
            icon: Icons.chevron_left_rounded,
            tooltip: 'Previous day',
            onTap: onPrev,
          ),
          const SizedBox(width: 2),
          Tooltip(
            message: 'Go to today',
            child: InkWell(
              onTap: isToday ? null : onToday,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                child: Text(
                  'Today',
                  style: TextStyle(
                    color: isToday ? c.textMuted : AppColors.accent,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 2),
          _IconNavButton(
            icon: Icons.chevron_right_rounded,
            tooltip: 'Next day',
            onTap: onNext,
          ),
          const SizedBox(width: 4),
          BlocBuilder<CalendarBloc, CalendarState>(
            buildWhen: (prev, next) {
              final prevIds = prev is CalendarLoaded ? prev.selectedEventIds : const <String>{};
              final nextIds = next is CalendarLoaded ? next.selectedEventIds : const <String>{};
              return prevIds.isEmpty != nextIds.isEmpty || prevIds.length != nextIds.length;
            },
            builder: (context, state) {
              if (state is! CalendarLoaded || state.selectedEventIds.isEmpty) {
                return const SizedBox.shrink();
              }
              return Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Tooltip(
                    message: 'Remove selected event${state.selectedEventIds.length > 1 ? 's' : ''}',
                    child: InkWell(
                      onTap: () => _confirmAndDeleteSelected(context, state),
                      borderRadius: BorderRadius.circular(6),
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(Icons.delete_outline_rounded, size: 16, color: Colors.red.shade400),
                      ),
                    ),
                  ),
                  const SizedBox(width: 2),
                ],
              );
            },
          ),
          InkWell(
            onTap: onClose,
            borderRadius: BorderRadius.circular(6),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Icon(Icons.close_rounded, size: 16, color: c.textMuted),
            ),
          ),
        ],
      ),
      ),
    );
  }
}

class _DayPanelAllDayStrip extends StatelessWidget {
  const _DayPanelAllDayStrip({required this.events});
  final List<CalendarEvent> events;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.colors.surfacePanel,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: events.map((e) => _AllDayEventChip(event: e)).toList(),
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
    final blocState = context.watch<CalendarBloc>().state;
    final isSelected = blocState is CalendarLoaded &&
        blocState.selectedEventIds.contains(event.id);

    return GestureDetector(
      onTap: () {
        final multiSelect = HardwareKeyboard.instance.isMetaPressed ||
            HardwareKeyboard.instance.isShiftPressed;
        context.read<CalendarBloc>().add(CalendarEventSelectionToggled(
              eventId: event.id,
              addToSelection: multiSelect,
            ));
      },
      onDoubleTap: () => _openEdit(context),
      onSecondaryTapUp: (details) =>
          _showEventContextMenu(context, event, details.globalPosition),
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 1),
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        decoration: BoxDecoration(
          color: AppColors.accent.withAlpha(isSelected ? 80 : 40),
          borderRadius: BorderRadius.circular(3),
          border: isSelected
              ? Border.all(color: AppColors.accent, width: 1.5)
              : Border(left: BorderSide(color: AppColors.accent, width: 2)),
          boxShadow: isSelected
              ? [BoxShadow(color: AppColors.accent.withAlpha(50), blurRadius: 4, offset: Offset.zero)]
              : null,
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
      ),
    );
  }

  void _openEdit(BuildContext context) {
    EventEditDialog.show(
      context,
      event: event,
      accountId: _accountId(context),
      isO365Account: _isO365Account(context),
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
    final today = DateTime.now();

    return Row(
      children: List.generate(7, (i) {
        final day = weekStart.add(Duration(days: i));
        final isToday = _isSameDay(day, today);
        final dayEvents = _eventsForDay(day);

        return _DayColumnCell(
          day: day,
          hourHeight: hourHeight,
          totalHours: totalHours,
          isToday: isToday,
          dayEvents: dayEvents,
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

class _DayColumnCell extends StatefulWidget {
  const _DayColumnCell({
    required this.day,
    required this.hourHeight,
    required this.totalHours,
    required this.isToday,
    required this.dayEvents,
  });

  final DateTime day;
  final double hourHeight;
  final int totalHours;
  final bool isToday;
  final List<CalendarEvent> dayEvents;

  @override
  State<_DayColumnCell> createState() => _DayColumnCellState();
}

class _DayColumnCellState extends State<_DayColumnCell> {
  Offset? _tapPosition;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    if (widget.isToday) {
      _timer = Timer.periodic(const Duration(minutes: 1), (_) {
        if (mounted) setState(() {});
      });
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _onDoubleTapDown(TapDownDetails details) {
    _tapPosition = details.localPosition;
  }

  void _onDoubleTap() {
    final pos = _tapPosition;
    if (pos == null) return;

    final totalMinutes = (pos.dy / widget.hourHeight * 60).round();
    final roundedMinutes = (totalMinutes / 30).floor() * 30;
    final hour = (roundedMinutes ~/ 60).clamp(0, 23);
    final minute = roundedMinutes % 60;
    final start = DateTime(
        widget.day.year, widget.day.month, widget.day.day, hour, minute);

    EventEditDialog.show(
      context,
      initialStart: start,
      accountId: _accountId(context),
      isO365Account: _isO365Account(context),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Expanded(
      child: GestureDetector(
        onTap: () => context.read<CalendarBloc>().add(const CalendarSelectionCleared()),
        onDoubleTapDown: _onDoubleTapDown,
        onDoubleTap: _onDoubleTap,
        child: Container(
          decoration: BoxDecoration(
            color: widget.isToday ? AppColors.accent.withAlpha(6) : null,
            border: Border(
              left: BorderSide(color: c.separator, width: 0.5),
            ),
          ),
          child: LayoutBuilder(
            builder: (context, constraints) {
              final layout = _computeOverlapLayout(widget.dayEvents);
              return Stack(
                children: [
                  ...List.generate(
                      widget.totalHours,
                      (h) => Positioned(
                            top: h * widget.hourHeight,
                            left: 0,
                            right: 0,
                            child: Divider(
                              height: 0.5,
                              color: h == 0
                                  ? Colors.transparent
                                  : c.separator,
                            ),
                          )),
                  ...widget.dayEvents.map((e) {
                    final span = layout[e.id] ??
                        const _ColumnSpan(index: 0, total: 1);
                    final colW =
                        (constraints.maxWidth - 4) / span.total;
                    return _PositionedEvent(
                      event: e,
                      dayStart: DateTime(widget.day.year,
                          widget.day.month, widget.day.day),
                      hourHeight: widget.hourHeight,
                      left: 2.0 + span.index * colW,
                      width: colW - (span.total > 1 ? 1.0 : 0.0),
                    );
                  }),
                  if (widget.isToday)
                    _CurrentTimeLine(
                      now: DateTime.now(),
                      hourHeight: widget.hourHeight,
                    ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Current time indicator
// ---------------------------------------------------------------------------

class _CurrentTimeLine extends StatelessWidget {
  const _CurrentTimeLine({required this.now, required this.hourHeight});

  final DateTime now;
  final double hourHeight;

  @override
  Widget build(BuildContext context) {
    final top = (now.hour + now.minute / 60.0) * hourHeight;
    return Positioned(
      top: top - 4,
      left: 0,
      right: 0,
      child: Row(
        children: [
          Container(
            width: 8,
            height: 8,
            decoration: const BoxDecoration(
              color: AppColors.accent,
              shape: BoxShape.circle,
            ),
          ),
          Expanded(
            child: Container(height: 1.5, color: AppColors.accent),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Overlap layout helpers
// ---------------------------------------------------------------------------

class _ColumnSpan {
  const _ColumnSpan({required this.index, required this.total});
  final int index;
  final int total;
}

/// Groups [events] into overlap clusters and assigns each a column slot so
/// that simultaneously-occurring events tile side-by-side instead of stacking.
Map<String, _ColumnSpan> _computeOverlapLayout(List<CalendarEvent> events) {
  if (events.isEmpty) return {};

  final sorted = List.of(events)..sort((a, b) => a.start.compareTo(b.start));

  bool overlaps(CalendarEvent a, CalendarEvent b) =>
      a.start.isBefore(b.end) && b.start.isBefore(a.end);

  // Build connected-component clusters.
  final clusters = <List<CalendarEvent>>[];
  for (final e in sorted) {
    final overlapping =
        clusters.where((c) => c.any((ce) => overlaps(ce, e))).toList();
    if (overlapping.isEmpty) {
      clusters.add([e]);
    } else {
      final merged = overlapping.expand((c) => c).toList()..add(e);
      for (final c in overlapping) clusters.remove(c);
      clusters.add(merged);
    }
  }

  final result = <String, _ColumnSpan>{};
  for (final cluster in clusters) {
    final cs = List.of(cluster)..sort((a, b) => a.start.compareTo(b.start));

    // Greedy column assignment: each event goes in the first column whose last
    // event has already ended.
    final colEnds = <int>[]; // end-minute of last event in each column
    final assignments = <String, int>{};

    for (final e in cs) {
      final startMin =
          e.start.toLocal().hour * 60 + e.start.toLocal().minute;
      int col = colEnds.indexWhere((end) => startMin >= end);
      if (col == -1) {
        col = colEnds.length;
        colEnds.add(0);
      }
      final endLocal = e.end.toLocal();
      colEnds[col] = endLocal.hour * 60 + endLocal.minute;
      assignments[e.id] = col;
    }

    final total = colEnds.length;
    for (final e in cluster) {
      result[e.id] = _ColumnSpan(index: assignments[e.id]!, total: total);
    }
  }

  return result;
}

// ---------------------------------------------------------------------------

class _PositionedEvent extends StatefulWidget {
  const _PositionedEvent({
    required this.event,
    required this.dayStart,
    required this.hourHeight,
    required this.left,
    required this.width,
  });

  final CalendarEvent event;
  final DateTime dayStart;
  final double hourHeight;
  final double left;
  final double width;

  @override
  State<_PositionedEvent> createState() => _PositionedEventState();
}

class _PositionedEventState extends State<_PositionedEvent> {
  double _dragDy = 0;
  bool _isDragging = false;

  double get _minutesPerPixel => widget.hourHeight / 60;

  double get _originalTop {
    final start = widget.event.start.toLocal();
    return (start.hour * 60 + start.minute) * _minutesPerPixel;
  }

  double get _originalHeight {
    final start = widget.event.start.toLocal();
    final end = widget.event.end.toLocal();
    final durationMinutes =
        end.difference(start).inMinutes.clamp(15, 24 * 60).toDouble();
    return durationMinutes * _minutesPerPixel;
  }

  int get _snappedMinutesDelta {
    final rawMinutes = _dragDy / _minutesPerPixel;
    return ((rawMinutes / 15).round() * 15).toInt();
  }

  DateTime get _newStart =>
      widget.event.start.add(Duration(minutes: _snappedMinutesDelta));

  DateTime get _newEnd =>
      widget.event.end.add(Duration(minutes: _snappedMinutesDelta));

  void _onPanStart(DragStartDetails _) {
    setState(() {
      _isDragging = true;
      _dragDy = 0;
    });
  }

  void _onPanUpdate(DragUpdateDetails details) {
    setState(() => _dragDy += details.delta.dy);
  }

  Future<void> _onPanEnd(DragEndDetails _) async {
    final newStart = _newStart;
    final newEnd = _newEnd;
    setState(() {
      _isDragging = false;
      _dragDy = 0;
    });

    if (newStart == widget.event.start) return;

    if (widget.event.isOrganizer) {
      context.read<CalendarBloc>().add(CalendarEventRescheduleRequested(
        event: widget.event,
        newStart: newStart,
        newEnd: newEnd,
      ));
    } else {
      final result = await _DragProposeConfirmDialog.show(
        context,
        event: widget.event,
        newStart: newStart,
        newEnd: newEnd,
      );
      if (result == null || !mounted) return;
      context.read<CalendarBloc>().add(CalendarEventNewTimeProposed(
        eventId: widget.event.id,
        newStart: newStart,
        newEnd: newEnd,
        timezone: localIanaTimezone(),
        message: result.isEmpty ? null : result,
      ));
    }
  }

  void _onPanCancel() {
    setState(() {
      _isDragging = false;
      _dragDy = 0;
    });
  }

  @override
  Widget build(BuildContext context) {
    final height = _originalHeight;
    final snappedDeltaPx = _snappedMinutesDelta * _minutesPerPixel;
    final top = _originalTop + (_isDragging ? snappedDeltaPx : 0);

    final blocState = context.watch<CalendarBloc>().state;
    final isSelected = blocState is CalendarLoaded &&
        blocState.selectedEventIds.contains(widget.event.id);

    return Positioned(
      top: top,
      left: widget.left,
      width: widget.width,
      height: height,
      child: GestureDetector(
        onTap: _isDragging
            ? null
            : () {
                final multiSelect = HardwareKeyboard.instance.isMetaPressed ||
                    HardwareKeyboard.instance.isShiftPressed;
                context.read<CalendarBloc>().add(CalendarEventSelectionToggled(
                      eventId: widget.event.id,
                      addToSelection: multiSelect,
                    ));
              },
        onDoubleTap: _isDragging ? null : () => _openEdit(context),
        onSecondaryTapUp: _isDragging
            ? null
            : (details) => _showContextMenu(context, details.globalPosition),
        onPanStart: _onPanStart,
        onPanUpdate: _onPanUpdate,
        onPanEnd: _onPanEnd,
        onPanCancel: _onPanCancel,
        child: _EventTile(
          event: widget.event,
          compact: height < 36,
          isDragging: _isDragging,
          isSelected: isSelected,
        ),
      ),
    );
  }

  void _openEdit(BuildContext context) {
    EventEditDialog.show(
      context,
      event: widget.event,
      accountId: _accountId(context),
      isO365Account: _isO365Account(context),
    );
  }

  void _showContextMenu(BuildContext context, Offset position) {
    _showEventContextMenu(context, widget.event, position);
  }
}

class _EventTile extends StatelessWidget {
  const _EventTile({
    required this.event,
    required this.compact,
    this.isDragging = false,
    this.isSelected = false,
  });

  final CalendarEvent event;
  final bool compact;
  final bool isDragging;
  final bool isSelected;

  @override
  Widget build(BuildContext context) {
    final color = _colorForStatus(event.status);

    return Opacity(
      opacity: isDragging ? 0.75 : 1.0,
      child: Container(
        padding: EdgeInsets.symmetric(
          horizontal: 4,
          vertical: compact ? 1 : 3,
        ),
        decoration: BoxDecoration(
          color: color.withAlpha(isDragging ? 70 : isSelected ? 70 : 40),
          borderRadius: BorderRadius.circular(3),
          border: isSelected
              ? Border.all(color: color, width: 1.5)
              : Border(left: BorderSide(color: color, width: 2.5)),
          boxShadow: isDragging
              ? [BoxShadow(color: color.withAlpha(60), blurRadius: 6, offset: const Offset(0, 2))]
              : isSelected
                  ? [BoxShadow(color: color.withAlpha(50), blurRadius: 4, offset: Offset.zero)]
                  : null,
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

// ─── Delete selected events ───────────────────────────────────────────────────

Future<void> _confirmAndDeleteSelected(
  BuildContext context,
  CalendarLoaded state,
) async {
  final selected =
      state.events.where((e) => state.selectedEventIds.contains(e.id)).toList();
  if (selected.isEmpty) return;

  final count = selected.length;
  final hasOrganized = selected.any((e) => e.isOrganizer);
  final hasAttending = selected.any((e) => !e.isOrganizer);

  final String content;
  final String actionLabel;
  if (hasOrganized && hasAttending) {
    content =
        'Remove $count event${count > 1 ? 's' : ''}? Meetings you organized will be cancelled; others will be declined.';
    actionLabel = 'Remove';
  } else if (hasOrganized) {
    content = count == 1
        ? 'Cancel "${selected.first.subject}" and send cancellation notices to all attendees?'
        : 'Cancel $count meetings and send cancellation notices to all attendees?';
    actionLabel = count == 1 ? 'Cancel Meeting' : 'Cancel Meetings';
  } else {
    content = count == 1
        ? 'Decline "${selected.first.subject}"?'
        : 'Decline $count meetings?';
    actionLabel = count == 1 ? 'Decline' : 'Decline All';
  }

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(count == 1 ? 'Remove Event' : 'Remove $count Events'),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Keep'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(actionLabel, style: const TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );

  if (confirmed != true || !context.mounted) return;
  context
      .read<CalendarBloc>()
      .add(const CalendarSelectedEventsDeleteRequested());
}

// ─── Context menu ─────────────────────────────────────────────────────────────

void _showEventContextMenu(
  BuildContext context,
  CalendarEvent event,
  Offset position,
) {
  final rect = RelativeRect.fromLTRB(
    position.dx,
    position.dy,
    position.dx,
    position.dy,
  );

  if (event.isOrganizer) {
    showMenu<_EventMenuAction>(
      context: context,
      position: rect,
      items: const [
        PopupMenuItem(
          value: _EventMenuAction.cancel,
          height: 36,
          child: Text('Cancel Meeting', style: TextStyle(fontSize: 13)),
        ),
      ],
    ).then((action) async {
      if (action == null || !context.mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Cancel Meeting'),
          content: Text(
            'Cancel "${event.subject}" and send cancellation notices to all attendees?',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('Keep'),
            ),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('Cancel Meeting',
                  style: TextStyle(color: Colors.white)),
            ),
          ],
        ),
      );
      if (confirmed != true || !context.mounted) return;
      context
          .read<CalendarBloc>()
          .add(CalendarEventCancelRequested(eventId: event.id));
    });
    return;
  }

  showMenu<_EventMenuAction>(
    context: context,
    position: rect,
    items: const [
      PopupMenuItem(
        value: _EventMenuAction.decline,
        height: 36,
        child: Text('Decline', style: TextStyle(fontSize: 13)),
      ),
      PopupMenuItem(
        value: _EventMenuAction.proposeNewTime,
        height: 36,
        child: Text('Propose New Time…', style: TextStyle(fontSize: 13)),
      ),
    ],
  ).then((action) async {
    if (action == null || !context.mounted) return;
    switch (action) {
      case _EventMenuAction.cancel:
        break;
      case _EventMenuAction.decline:
        context
            .read<CalendarBloc>()
            .add(CalendarEventDeclineRequested(eventId: event.id));
      case _EventMenuAction.proposeNewTime:
        final proposed = await _ProposeNewTimeDialog.show(context, event);
        if (proposed == null || !context.mounted) return;
        context.read<CalendarBloc>().add(CalendarEventNewTimeProposed(
              eventId: event.id,
              newStart: proposed.newStart,
              newEnd: proposed.newEnd,
              timezone: localIanaTimezone(),
            ));
    }
  });
}

enum _EventMenuAction { cancel, decline, proposeNewTime }

// ─── Propose New Time dialog ──────────────────────────────────────────────────

typedef _ProposedTime = ({DateTime newStart, DateTime newEnd});

class _ProposeNewTimeDialog extends StatefulWidget {
  const _ProposeNewTimeDialog({required this.event});

  final CalendarEvent event;

  static Future<_ProposedTime?> show(
    BuildContext context,
    CalendarEvent event,
  ) {
    return showDialog<_ProposedTime>(
      context: context,
      builder: (_) => _ProposeNewTimeDialog(event: event),
    );
  }

  @override
  State<_ProposeNewTimeDialog> createState() => _ProposeNewTimeDialogState();
}

class _ProposeNewTimeDialogState extends State<_ProposeNewTimeDialog> {
  late DateTime _date;
  late TimeOfDay _startTime;
  late TimeOfDay _endTime;

  @override
  void initState() {
    super.initState();
    final localStart = widget.event.start.toLocal();
    final localEnd = widget.event.end.toLocal();
    _date = DateTime(localStart.year, localStart.month, localStart.day);
    _startTime = TimeOfDay.fromDateTime(localStart);
    _endTime = TimeOfDay.fromDateTime(localEnd);
  }

  DateTime _combine(DateTime date, TimeOfDay time) =>
      DateTime(date.year, date.month, date.day, time.hour, time.minute);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final fmt = DateFormat('EEE, d MMM yyyy');

    return AlertDialog(
      backgroundColor: c.surfacePanel,
      title: Text(
        'Propose New Time',
        style: TextStyle(color: c.textPrimary, fontSize: 15, fontWeight: FontWeight.w600),
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.event.subject,
              style: TextStyle(color: c.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            _PickerRow(
              label: 'Date',
              value: fmt.format(_date),
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: _date,
                  firstDate: DateTime.now().subtract(const Duration(days: 365)),
                  lastDate: DateTime.now().add(const Duration(days: 365 * 2)),
                );
                if (picked != null) setState(() => _date = picked);
              },
            ),
            const SizedBox(height: 8),
            _PickerRow(
              label: 'Start',
              value: _startTime.format(context),
              onTap: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _startTime,
                );
                if (picked != null) setState(() => _startTime = picked);
              },
            ),
            const SizedBox(height: 8),
            _PickerRow(
              label: 'End',
              value: _endTime.format(context),
              onTap: () async {
                final picked = await showTimePicker(
                  context: context,
                  initialTime: _endTime,
                );
                if (picked != null) setState(() => _endTime = picked);
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: c.textMuted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          onPressed: () {
            Navigator.of(context).pop<_ProposedTime>((
              newStart: _combine(_date, _startTime),
              newEnd: _combine(_date, _endTime),
            ));
          },
          child: const Text('Propose', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

// ─── Drag-to-propose confirm dialog ──────────────────────────────────────────

class _DragProposeConfirmDialog extends StatefulWidget {
  const _DragProposeConfirmDialog({
    required this.event,
    required this.newStart,
    required this.newEnd,
  });

  final CalendarEvent event;
  final DateTime newStart;
  final DateTime newEnd;

  /// Returns the message string if the user confirms, or null if cancelled.
  static Future<String?> show(
    BuildContext context, {
    required CalendarEvent event,
    required DateTime newStart,
    required DateTime newEnd,
  }) {
    return showDialog<String>(
      context: context,
      builder: (_) => _DragProposeConfirmDialog(
        event: event,
        newStart: newStart,
        newEnd: newEnd,
      ),
    );
  }

  @override
  State<_DragProposeConfirmDialog> createState() =>
      _DragProposeConfirmDialogState();
}

class _DragProposeConfirmDialogState extends State<_DragProposeConfirmDialog> {
  final _messageController = TextEditingController();

  @override
  void dispose() {
    _messageController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final localStart = widget.newStart.toLocal();
    final localEnd = widget.newEnd.toLocal();
    final dateFmt = DateFormat('EEE, d MMM yyyy');
    final timeFmt = DateFormat('h:mm a');
    final timeLabel =
        '${dateFmt.format(localStart)} · ${timeFmt.format(localStart)} – ${timeFmt.format(localEnd)}';

    return AlertDialog(
      backgroundColor: c.surfacePanel,
      title: Text(
        'Propose New Time',
        style: TextStyle(
          color: c.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 56,
              child: _EventTile(event: widget.event, compact: false),
            ),
            const SizedBox(height: 14),
            Row(
              children: [
                Icon(Icons.schedule_outlined, size: 14, color: c.textTertiary),
                const SizedBox(width: 6),
                Text(
                  timeLabel,
                  style: TextStyle(color: c.textTertiary, fontSize: 12),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _messageController,
              maxLines: 3,
              autofocus: true,
              style: TextStyle(color: c.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Message to organizer (optional)',
                hintStyle: TextStyle(color: c.textMuted, fontSize: 13),
                filled: true,
                fillColor: c.surfaceBase,
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: c.separator),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: c.separator),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(6),
                  borderSide: BorderSide(color: AppColors.accent, width: 1.5),
                ),
                contentPadding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text('Cancel', style: TextStyle(color: c.textMuted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: AppColors.accent),
          onPressed: () =>
              Navigator.of(context).pop(_messageController.text),
          child: const Text('Send', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class _PickerRow extends StatelessWidget {
  const _PickerRow({required this.label, required this.value, required this.onTap});

  final String label;
  final String value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Row(
      children: [
        SizedBox(
          width: 48,
          child: Text(
            label,
            style: TextStyle(color: c.textMuted, fontSize: 12),
          ),
        ),
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              border: Border.all(color: c.separator),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              value,
              style: TextStyle(color: c.textPrimary, fontSize: 13),
            ),
          ),
        ),
      ],
    );
  }
}
