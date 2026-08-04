import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/theme/app_colors.dart';
import '../../core/utils/timezone_utils.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/usecases/get_calendar_event.dart';
import '../../infrastructure/accounts/account.dart';
import '../../injection_container.dart';
import '../blocs/account/account_cubit.dart';
import '../blocs/calendar/calendar_bloc.dart';
import '../blocs/calendar/calendar_event.dart';
import '../blocs/calendar/calendar_state.dart';
import '../widgets/calendar_overlap_layout.dart';
import '../widgets/event_edit_dialog.dart';

class CalendarPage extends StatefulWidget {
  const CalendarPage({super.key});

  @override
  State<CalendarPage> createState() => _CalendarPageState();
}

class _CalendarPageState extends State<CalendarPage> {
  /// The window opens on the working week (Mon–Fri); the nav bar toggles it.
  bool _workWeek = true;

  int get _dayCount => _workWeek ? 5 : 7;

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
              _WeekNavBar(
                state: state,
                workWeek: _workWeek,
                onToggleWorkWeek: () => setState(() => _workWeek = !_workWeek),
              ),
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
                    _WeekView(
                        weekStart: weekStart,
                        events: events,
                        dayCount: _dayCount),
                  CalendarError(:final message, :final weekStart) =>
                    _WeekView(
                        weekStart: weekStart,
                        events: const [],
                        dayCount: _dayCount,
                        errorMessage: message),
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

class _WeekNavBar extends StatefulWidget {
  const _WeekNavBar({
    required this.state,
    required this.workWeek,
    required this.onToggleWorkWeek,
  });
  final CalendarState state;
  final bool workWeek;
  final VoidCallback onToggleWorkWeek;

  @override
  State<_WeekNavBar> createState() => _WeekNavBarState();
}

class _WeekNavBarState extends State<_WeekNavBar> {
  Timer? _midnightTimer;

  @override
  void initState() {
    super.initState();
    _scheduleMidnightRollover();
  }

  @override
  void dispose() {
    _midnightTimer?.cancel();
    super.dispose();
  }

  void _scheduleMidnightRollover() {
    final now = DateTime.now();
    final nextMidnight = DateTime(now.year, now.month, now.day + 1);
    _midnightTimer = Timer(nextMidnight.difference(now), () {
      if (!mounted) return;
      // Auto-advance only if the user was viewing the week that just ended.
      final now2 = DateTime.now();
      final yesterday = now2.subtract(const Duration(days: 1));
      final previousWeekMonday = _mondayOfWeek(yesterday);
      final currentState = context.read<CalendarBloc>().state;
      if (currentState.weekStart == previousWeekMonday) {
        _goToToday(context);
      }
      _scheduleMidnightRollover();
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final weekStart = widget.state.weekStart;
    final weekEnd = weekStart.add(Duration(days: widget.workWeek ? 4 : 6));
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
          if (widget.state case final CalendarLoaded loaded when loaded.selectedEventIds.isNotEmpty) ...[
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
          _WeekSpanToggle(
            workWeek: widget.workWeek,
            onTap: widget.onToggleWorkWeek,
          ),
          const SizedBox(width: 8),
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
    final newWeekStart = widget.state.weekStart.add(Duration(days: days));
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

/// Switches the week view between Mon–Fri and the full seven days. Shows the
/// span it will switch *to*, so the label doubles as the action.
class _WeekSpanToggle extends StatelessWidget {
  const _WeekSpanToggle({required this.workWeek, required this.onTap});
  final bool workWeek;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final label = workWeek ? 'Full Week' : 'Working Week';
    return Tooltip(
      message: 'Show $label',
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: c.separatorStrong),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                workWeek
                    ? Icons.calendar_view_week_rounded
                    : Icons.calendar_view_month_rounded,
                size: 14,
                color: c.textMuted,
              ),
              const SizedBox(width: 4),
              Text(
                label,
                style: TextStyle(
                  color: c.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
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

bool _isGmailAccount(BuildContext context) {
  final state = context.read<AccountCubit>().state;
  if (state is AccountsLoaded) return state.activeAccount is GmailAccount;
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
          isGmailAccount: _isGmailAccount(context),
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
      if (!mounted) return;
      final now = DateTime.now();
      final today = DateTime(now.year, now.month, now.day);
      final yesterday = today.subtract(const Duration(days: 1));
      if (_isSameDay(_selectedDay, yesterday)) {
        _goToToday(context);
      } else {
        setState(() {});
      }
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
        final errorMessage = switch (state) {
          CalendarError(:final message) => message,
          _ => null,
        };
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
              if (errorMessage != null) _ErrorBanner(message: errorMessage),
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
                                  isGmailAccount: _isGmailAccount(context),
                                );
                              },
                              child: LayoutBuilder(
                                builder: (context, constraints) {
                                  final layout = computeOverlapLayout(timedEvents);
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
                                      ...List.generate(timedEvents.length, (i) {
                                        final e = timedEvents[i];
                                        final span = layout[i];
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
    required this.dayCount,
    this.errorMessage,
  });

  final DateTime weekStart;
  final List<CalendarEvent> events;

  /// Days rendered from [weekStart]: 5 for the working week, 7 for the full one.
  final int dayCount;
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
    // Hidden days shouldn't leave an empty all-day strip behind, so drop
    // anything outside the rendered span before splitting.
    final visible =
        widget.events.where((e) => _isVisibleDay(e.start)).toList();
    final allDayEvents = visible.where((e) => e.isAllDay).toList();
    final timedEvents = visible.where((e) => !e.isAllDay).toList();

    return Column(
      children: [
        _DayHeader(
          weekStart: widget.weekStart,
          dayCount: widget.dayCount,
          timeColumnWidth: _timeColumnWidth,
        ),
        if (allDayEvents.isNotEmpty)
          _AllDayStrip(
            weekStart: widget.weekStart,
            dayCount: widget.dayCount,
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
                      dayCount: widget.dayCount,
                      events: timedEvents,
                      hourHeight: _hourHeight,
                      totalHours: _totalHours,
                    ),
                  ),
                  // Mirrored gutter, so the hour a tile sits at is readable
                  // without tracking all the way back to the left edge.
                  VerticalDivider(width: 1, color: c.separatorStrong),
                  _TimeColumn(hourHeight: _hourHeight, totalHours: _totalHours, width: _timeColumnWidth),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  bool _isVisibleDay(DateTime instant) {
    final local = instant.toLocal();
    final day = DateTime(local.year, local.month, local.day);
    final firstDay = DateTime(
        widget.weekStart.year, widget.weekStart.month, widget.weekStart.day);
    final lastDay = firstDay.add(Duration(days: widget.dayCount - 1));
    return !day.isBefore(firstDay) && !day.isAfter(lastDay);
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.weekStart,
    required this.dayCount,
    required this.timeColumnWidth,
  });

  final DateTime weekStart;
  final int dayCount;
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
          ...List.generate(dayCount, (i) {
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
          // Matches the right-hand hour gutter (+1 for its divider).
          SizedBox(width: timeColumnWidth + 1),
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
    required this.dayCount,
    required this.events,
    required this.timeColumnWidth,
  });

  final DateTime weekStart;
  final int dayCount;
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
              children: List.generate(dayCount, (i) {
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
          // Matches the right-hand hour gutter.
          Container(width: 1, color: c.separatorStrong),
          SizedBox(width: timeColumnWidth),
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
    unawaited(_openInstanceEditor(context, event));
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
    required this.dayCount,
    required this.events,
    required this.hourHeight,
    required this.totalHours,
  });

  final DateTime weekStart;
  final int dayCount;
  final List<CalendarEvent> events;
  final double hourHeight;
  final int totalHours;

  @override
  Widget build(BuildContext context) {
    final today = DateTime.now();

    return Row(
      children: List.generate(dayCount, (i) {
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
      isGmailAccount: _isGmailAccount(context),
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
              final layout = computeOverlapLayout(widget.dayEvents);
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
                  ...List.generate(widget.dayEvents.length, (i) {
                    final e = widget.dayEvents[i];
                    final span = layout[i];
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
      isGmailAccount: _isGmailAccount(context),
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
    final color = _colorForEvent(event);
    final joinable = _isJoinable(event, DateTime.now());

    return Opacity(
      opacity: isDragging ? 0.75 : 1.0,
      child: Container(
        clipBehavior: Clip.hardEdge,
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
        child: Stack(
          children: [
            Column(
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
                    _displayLocation(event.location!),
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
            if (joinable)
              Positioned(
                right: 0,
                bottom: 0,
                child: _JoinButton(url: event.location!, color: color),
              ),
          ],
        ),
      ),
    );
  }

  /// Tile colour, driven by the user's [MeetingParticipation] so Gmail and
  /// O365 meetings are coloured consistently (they expose different underlying
  /// fields but map onto the same participation enum). Out-of-office and
  /// working-elsewhere are free/busy states with no participation equivalent,
  /// so they override as red/grey — these come from O365's `showAs` only.
  Color _colorForEvent(CalendarEvent event) {
    const green = Color(0xFF34A853);
    const yellow = Color(0xFFFBBC04);
    const red = Color(0xFFEA4335);
    const grey = Color(0xFF9E9E9E);

    if (event.status == CalendarEventStatus.outOfOffice) return red;
    if (event.status == CalendarEventStatus.workingElsewhere) return grey;

    return switch (event.participation) {
      MeetingParticipation.organizer => green, // you organised it
      MeetingParticipation.accepted => AppColors.accent, // blue — you accepted
      MeetingParticipation.tentative => yellow, // tentatively accepted
      MeetingParticipation.needsAction => yellow, // invited, not yet responded
      MeetingParticipation.declined => grey, // declined
      MeetingParticipation.none => AppColors.accent, // blue — on your calendar
    };
  }
}

/// A meeting is "joinable" from 3 minutes before it starts until it ends,
/// provided it carries an online-meeting link (an `https://` [location], the
/// same signal the context menu uses for "Join Meeting").
bool _isJoinable(CalendarEvent event, DateTime now) {
  final url = event.location;
  if (url == null || !url.startsWith('https://')) return false;
  final start = event.start.toLocal();
  final end = event.end.toLocal();
  return !now.isBefore(start.subtract(const Duration(minutes: 3))) &&
      now.isBefore(end);
}

/// Small inline "Join" pill shown on an imminent meeting's tile, so joining
/// doesn't require the right-click context menu. Its own tap handler swallows
/// the gesture, keeping the tile's select/edit/drag handlers from firing.
class _JoinButton extends StatelessWidget {
  const _JoinButton({required this.url, required this.color});

  final String url;
  final Color color;

  @override
  Widget build(BuildContext context) {
    // Pick a black/white foreground that stays legible on any tile colour
    // (e.g. white-on-yellow is too weak) using the pill background's luminance.
    final fg = color.computeLuminance() > 0.5 ? Colors.black : Colors.white;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () => unawaited(
        launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication),
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: color,
          borderRadius: BorderRadius.circular(3),
        ),
        child: Text(
          'Join',
          style: TextStyle(
            color: fg,
            fontSize: 9,
            fontWeight: FontWeight.w700,
            height: 1.2,
          ),
        ),
      ),
    );
  }
}

// ─── Recurring-aware edit / cancel helpers ──────────────────────────────────────

/// Opens the edit window for a single event/occurrence as-is — used by
/// double-click and the "Edit" / "Edit Instance" menu items. A recurring
/// occurrence opens with its recurrence shown read-only (see [EventEditForm]).
Future<void> _openInstanceEditor(
    BuildContext context, CalendarEvent event) async {
  await EventEditDialog.show(
    context,
    event: event,
    accountId: _accountId(context),
    isO365Account: _isO365Account(context),
    isGmailAccount: _isGmailAccount(context),
  );
}

/// Opens the edit window for the whole series behind a recurring occurrence —
/// the "Edit Series" menu item. Loads the series master (its real anchor time
/// and editable recurrence) so the form edits, and the save targets, the
/// series rather than one instance.
Future<void> _openSeriesEditor(
    BuildContext context, CalendarEvent event) async {
  final accountId = _accountId(context);
  final isO365 = _isO365Account(context);
  final isGmail = _isGmailAccount(context);
  final master =
      await _fetchSeriesMaster(context, event.seriesMasterId ?? event.id);
  if (master == null || !context.mounted) return;
  await EventEditDialog.show(
    context,
    event: master,
    accountId: accountId,
    isO365Account: isO365,
    isGmailAccount: isGmail,
  );
}

/// Loads a series master by id, surfacing a snackbar (and returning null) on
/// failure.
Future<CalendarEvent?> _fetchSeriesMaster(
  BuildContext context,
  String masterId,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final result =
      await sl<GetCalendarEvent>()(GetCalendarEventParams(id: masterId));
  return result.fold(
    (f) {
      messenger.showSnackBar(SnackBar(
        content: Text("Couldn't load the series: ${f.message}"),
        backgroundColor: Colors.red.shade700,
      ));
      return null;
    },
    (event) => event,
  );
}

/// Confirms and cancels a meeting the user organizes. [series] chosen up front
/// via the "Cancel Series" vs "Cancel Instance"/"Cancel Meeting" menu items;
/// returns without acting if the user declines the confirmation.
Future<void> _confirmAndCancel(
  BuildContext context,
  CalendarEvent event, {
  required bool series,
}) async {
  final title = series
      ? 'Cancel Series'
      : (event.isRecurringOccurrence ? 'Cancel Instance' : 'Cancel Meeting');
  final content = series
      ? 'Cancel all occurrences of "${event.subject}"? '
          'Cancellation notices will be sent to all attendees.'
      : event.isRecurringOccurrence
          ? 'Cancel this occurrence of "${event.subject}"? '
              'A cancellation notice will be sent to all attendees.'
          : 'Cancel "${event.subject}" and send cancellation notices to all attendees?';

  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(title),
      content: Text(content),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Keep'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red),
          onPressed: () => Navigator.of(ctx).pop(true),
          child: Text(title, style: const TextStyle(color: Colors.white)),
        ),
      ],
    ),
  );
  if (confirmed != true || !context.mounted) return;

  if (series) {
    context.read<CalendarBloc>().add(CalendarEventCancelSeriesRequested(
          eventId: event.id,
          seriesMasterId: event.seriesMasterId,
          occurrenceStart: event.start,
        ));
  } else {
    context
        .read<CalendarBloc>()
        .add(CalendarEventCancelRequested(eventId: event.id));
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

/// Teams meetup-join URLs carry a long opaque meeting-id/context token that's
/// meaningless to display; show a clean stand-in while the real URL (used for
/// "Join Meeting" and editing) stays in [CalendarEvent.location].
String _displayLocation(String location) {
  if (location.startsWith('https://teams.microsoft.com')) {
    return 'https://teams.microsoft.com/join-meeting';
  }
  return location;
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

  final meetingUrl = event.location;
  final hasMeetingLink =
      meetingUrl != null && meetingUrl.startsWith('https://');

  final isRecurring = event.isRecurringOccurrence;

  if (event.isOrganizer) {
    showMenu<_EventMenuAction>(
      context: context,
      position: rect,
      items: [
        if (hasMeetingLink) ...[
          const PopupMenuItem(
            value: _EventMenuAction.joinMeeting,
            height: 36,
            child: Text('Join Meeting', style: TextStyle(fontSize: 13)),
          ),
          const PopupMenuDivider(height: 1),
        ],
        if (isRecurring) ...[
          const PopupMenuItem(
            value: _EventMenuAction.editInstance,
            height: 36,
            child: Text('Edit Instance', style: TextStyle(fontSize: 13)),
          ),
          const PopupMenuItem(
            value: _EventMenuAction.editSeries,
            height: 36,
            child: Text('Edit Series', style: TextStyle(fontSize: 13)),
          ),
        ] else
          const PopupMenuItem(
            value: _EventMenuAction.edit,
            height: 36,
            child: Text('Edit', style: TextStyle(fontSize: 13)),
          ),
        const PopupMenuDivider(height: 1),
        if (isRecurring) ...[
          const PopupMenuItem(
            value: _EventMenuAction.cancel,
            height: 36,
            child: Text('Cancel Instance', style: TextStyle(fontSize: 13)),
          ),
          const PopupMenuItem(
            value: _EventMenuAction.cancelSeries,
            height: 36,
            child: Text('Cancel Series', style: TextStyle(fontSize: 13)),
          ),
        ] else
          const PopupMenuItem(
            value: _EventMenuAction.cancel,
            height: 36,
            child: Text('Cancel Meeting', style: TextStyle(fontSize: 13)),
          ),
      ],
    ).then((action) async {
      if (action == null || !context.mounted) return;
      switch (action) {
        case _EventMenuAction.joinMeeting:
          unawaited(launchUrl(Uri.parse(meetingUrl!),
              mode: LaunchMode.externalApplication));
        case _EventMenuAction.edit:
        case _EventMenuAction.editInstance:
          await _openInstanceEditor(context, event);
        case _EventMenuAction.editSeries:
          await _openSeriesEditor(context, event);
        case _EventMenuAction.cancel:
          await _confirmAndCancel(context, event, series: false);
        case _EventMenuAction.cancelSeries:
          await _confirmAndCancel(context, event, series: true);
        case _EventMenuAction.decline:
        case _EventMenuAction.proposeNewTime:
          break;
      }
    });
    return;
  }

  showMenu<_EventMenuAction>(
    context: context,
    position: rect,
    items: [
      if (hasMeetingLink) ...[
        const PopupMenuItem(
          value: _EventMenuAction.joinMeeting,
          height: 36,
          child: Text('Join Meeting', style: TextStyle(fontSize: 13)),
        ),
        const PopupMenuDivider(height: 1),
      ],
      const PopupMenuItem(
        value: _EventMenuAction.decline,
        height: 36,
        child: Text('Decline Meeting', style: TextStyle(fontSize: 13)),
      ),
      const PopupMenuItem(
        value: _EventMenuAction.proposeNewTime,
        height: 36,
        child: Text('Propose New Time…', style: TextStyle(fontSize: 13)),
      ),
    ],
  ).then((action) async {
    if (action == null || !context.mounted) return;
    switch (action) {
      case _EventMenuAction.cancel:
      case _EventMenuAction.cancelSeries:
      case _EventMenuAction.edit:
      case _EventMenuAction.editInstance:
      case _EventMenuAction.editSeries:
        break;
      case _EventMenuAction.joinMeeting:
        unawaited(launchUrl(Uri.parse(meetingUrl!),
            mode: LaunchMode.externalApplication));
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

enum _EventMenuAction {
  edit,
  editInstance,
  editSeries,
  cancel,
  cancelSeries,
  joinMeeting,
  decline,
  proposeNewTime,
}

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
                  initialEntryMode: TimePickerEntryMode.input,
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
                  initialEntryMode: TimePickerEntryMode.input,
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
