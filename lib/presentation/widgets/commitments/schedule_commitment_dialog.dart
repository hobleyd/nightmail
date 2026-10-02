import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../../core/theme/app_colors.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../domain/entities/commitment.dart';
import '../../../domain/entities/time_block_suggestion.dart';
import '../../../domain/usecases/commitments/suggest_time_block.dart';

/// Blocks time for a commitment.
///
/// Opens on the suggestion `SuggestTimeBlock` made — the lightest working
/// day in the commitment's horizon and the first free run on it — and lets
/// the user move it before confirming. Two layouts share one state:
///
/// * **Compact** (the side pane, phones): the candidate days as a list with
///   load bars, a start-time dropdown of the day's slots with the busy ones
///   marked, and length chips.
/// * **Wide** (the detached window, from [kWideMinWidth]): the same days as
///   a week grid with the meetings drawn to scale and the proposed block in
///   accent — click anywhere in a day column to put the block there — beside
///   a details column with the reason, the chosen time, length chips and
///   the conflict warning.
///
/// [onSchedule] does the booking and answers whether the calendar accepted
/// it; the dialog closes with `true` on success and stays open with the
/// failure otherwise.
class ScheduleCommitmentDialog extends StatefulWidget {
  const ScheduleCommitmentDialog({
    super.key,
    required this.commitment,
    required this.suggestion,
    required this.suggester,
    required this.onSchedule,
    this.wide = false,
    this.now,
  });

  final Commitment commitment;
  final TimeBlockSuggestion suggestion;
  final SuggestTimeBlock suggester;
  final Future<bool> Function(DateTime start, DateTime end) onSchedule;
  final bool wide;

  /// Clock override for tests; defaults to `DateTime.now`.
  final DateTime Function()? now;

  /// Window width from which the week-grid layout is used.
  static const double kWideMinWidth = 1100;

  static const List<Duration> durations = [
    Duration(minutes: 30),
    Duration(minutes: 60),
    Duration(minutes: 90),
    Duration(minutes: 120),
  ];

  /// Shows the dialog in the layout the window's width allows. Resolves to
  /// `true` when a block was scheduled.
  static Future<bool> show(
    BuildContext context, {
    required Commitment commitment,
    required TimeBlockSuggestion suggestion,
    required SuggestTimeBlock suggester,
    required Future<bool> Function(DateTime start, DateTime end) onSchedule,
  }) async {
    final wide = MediaQuery.sizeOf(context).width >= kWideMinWidth;
    final result = await showDialog<bool>(
      context: context,
      builder: (_) => ScheduleCommitmentDialog(
        commitment: commitment,
        suggestion: suggestion,
        suggester: suggester,
        onSchedule: onSchedule,
        wide: wide,
      ),
    );
    return result ?? false;
  }

  @override
  State<ScheduleCommitmentDialog> createState() =>
      _ScheduleCommitmentDialogState();
}

class _ScheduleCommitmentDialogState extends State<ScheduleCommitmentDialog> {
  late DateTime _start;
  late Duration _duration;
  bool _saving = false;
  String? _error;

  DateTime get _clock => (widget.now ?? DateTime.now)();
  DateTime get _end => _start.add(_duration);
  DateTime get _day => DateTime(_start.year, _start.month, _start.day);
  List<CalendarEvent> get _events => widget.suggestion.events;
  bool get _conflict => widget.suggester.conflicts(_start, _end, _events);

  DayLoad? get _dayLoad {
    for (final d in widget.suggestion.days) {
      if (d.day == _day) return d;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _start = widget.suggestion.start;
    _duration = widget.suggestion.duration;
  }

  void _pickDay(DateTime day) {
    setState(() {
      _start = widget.suggester.slotFor(
        day: day,
        events: _events,
        now: _clock,
        duration: _duration,
      );
    });
  }

  void _pickStart(DateTime start) => setState(() => _start = start);

  void _pickDuration(Duration d) => setState(() => _duration = d);

  Future<void> _confirm() async {
    setState(() {
      _saving = true;
      _error = null;
    });
    final ok = await widget.onSchedule(_start, _end);
    if (!mounted) return;
    if (ok) {
      Navigator.of(context).pop(true);
    } else {
      setState(() {
        _saving = false;
        _error = 'The calendar did not accept the block. Try again.';
      });
    }
  }

  /// Start times on the slot grid inside the day's working window.
  List<DateTime> _slotsOn(DateTime day) {
    final s = widget.suggester;
    final first = DateTime(day.year, day.month, day.day, s.workingDayStartHour);
    final last = DateTime(day.year, day.month, day.day, s.workingDayEndHour);
    final out = <DateTime>[];
    var cursor = first;
    while (cursor.isBefore(last)) {
      out.add(cursor);
      cursor = cursor.add(Duration(minutes: s.slotMinutes));
    }
    return out;
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final title = widget.commitment.isScheduled ? 'Move the time block' : 'Schedule time';
    return Dialog(
      backgroundColor: c.surfacePanel,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: ConstrainedBox(
        constraints: widget.wide
            ? const BoxConstraints(maxWidth: 1080, maxHeight: 680)
            : const BoxConstraints(maxWidth: 480, maxHeight: 640),
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: widget.wide ? _buildWide(context, title) : _buildCompact(context, title),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Shared pieces
  // ---------------------------------------------------------------------------

  Widget _title(BuildContext context, String title) {
    final c = context.colors;
    final what = widget.commitment.subject.trim().isEmpty
        ? widget.commitment.snippet
        : widget.commitment.subject;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            color: c.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 2),
        Text(
          '$what · ${widget.commitment.counterpart.displayName}',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(color: c.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  Widget _reason(BuildContext context) {
    final c = context.colors;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.auto_awesome_rounded, size: 14, color: AppColors.accent),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            widget.suggestion.reason,
            style: TextStyle(color: c.textSecondary, fontSize: 12),
          ),
        ),
      ],
    );
  }

  Widget _durationChips(BuildContext context) {
    final c = context.colors;
    return Wrap(
      spacing: 6,
      children: [
        for (final d in ScheduleCommitmentDialog.durations)
          ChoiceChip(
            label: Text(_durationLabel(d)),
            selected: _duration == d,
            onSelected: (_) => _pickDuration(d),
            labelStyle: TextStyle(
              fontSize: 12,
              color: _duration == d ? AppColors.accent : c.textSecondary,
            ),
            selectedColor: AppColors.accent.withAlpha(28),
            backgroundColor: c.surfaceBase,
            side: BorderSide(
              color: _duration == d ? AppColors.accent : c.separatorStrong,
            ),
            showCheckmark: false,
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  Widget _summary(BuildContext context) {
    final c = context.colors;
    final conflict = _conflict;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '${DateFormat('EEEE d MMMM').format(_start)} · '
          '${DateFormat.jm().format(_start)} – ${DateFormat.jm().format(_end)}',
          style: TextStyle(
            color: c.textSecondary,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
        if (conflict) ...[
          const SizedBox(height: 4),
          Row(
            children: [
              Icon(Icons.warning_amber_rounded,
                  size: 14, color: AppColors.notification),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  'Overlaps a meeting on your calendar.',
                  style: TextStyle(color: AppColors.notification, fontSize: 12),
                ),
              ),
            ],
          ),
        ],
        if (_error != null) ...[
          const SizedBox(height: 4),
          Text(_error!, style: TextStyle(color: c.errorBannerText, fontSize: 12)),
        ],
      ],
    );
  }

  Widget _actions(BuildContext context) {
    final c = context.colors;
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.of(context).pop(false),
          style: TextButton.styleFrom(foregroundColor: c.textMuted),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 8),
        ElevatedButton.icon(
          onPressed: _saving ? null : _confirm,
          icon: _saving
              ? const SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Icon(Icons.event_available_rounded, size: 16),
          label: Text(widget.commitment.isScheduled ? 'Move block' : 'Schedule'),
          style: ElevatedButton.styleFrom(
            backgroundColor: AppColors.accent,
            foregroundColor: Colors.white,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Compact layout
  // ---------------------------------------------------------------------------

  Widget _buildCompact(BuildContext context, String title) {
    final c = context.colors;
    final slots = _slotsOn(_day);
    // The dropdown must contain its value: a start off the grid (never, in
    // practice) is appended so the control cannot assert.
    final values = slots.contains(_start) ? slots : [...slots, _start]
      ..sort();
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(context, title),
        const SizedBox(height: 12),
        _reason(context),
        const SizedBox(height: 12),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _Label('Day'),
                const SizedBox(height: 6),
                Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: c.separatorStrong),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Column(
                    children: [
                      for (var i = 0; i < widget.suggestion.days.length; i++) ...[
                        if (i > 0) Divider(height: 1, color: c.separator),
                        _DayRow(
                          load: widget.suggestion.days[i],
                          selected: widget.suggestion.days[i].day == _day,
                          now: _clock,
                          onTap: () => _pickDay(widget.suggestion.days[i].day),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(height: 12),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Label('Start'),
                          const SizedBox(height: 6),
                          Container(
                            height: 36,
                            padding: const EdgeInsets.symmetric(horizontal: 10),
                            decoration: BoxDecoration(
                              color: c.surfaceBase,
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(color: c.separatorStrong),
                            ),
                            child: DropdownButtonHideUnderline(
                              child: DropdownButton<DateTime>(
                                value: _start,
                                isDense: true,
                                isExpanded: true,
                                dropdownColor: c.surfacePanel,
                                style: TextStyle(
                                  color: c.textSecondary,
                                  fontSize: 13,
                                ),
                                items: [
                                  for (final s in values)
                                    DropdownMenuItem(
                                      value: s,
                                      child: Text(
                                        widget.suggester.conflicts(
                                          s,
                                          s.add(_duration),
                                          _events,
                                        )
                                            ? '${DateFormat.jm().format(s)} · busy'
                                            : DateFormat.jm().format(s),
                                      ),
                                    ),
                                ],
                                onChanged: (s) {
                                  if (s != null) _pickStart(s);
                                },
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Label('Length'),
                          const SizedBox(height: 6),
                          _durationChips(context),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 14),
                _summary(context),
              ],
            ),
          ),
        ),
        const SizedBox(height: 16),
        _actions(context),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Wide layout
  // ---------------------------------------------------------------------------

  Widget _buildWide(BuildContext context, String title) {
    final c = context.colors;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _title(context, title),
        const SizedBox(height: 14),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(
                child: _WeekGrid(
                  days: widget.suggestion.days,
                  events: _events,
                  suggester: widget.suggester,
                  blockStart: _start,
                  blockEnd: _end,
                  now: _clock,
                  onPick: _pickStart,
                ),
              ),
              const SizedBox(width: 20),
              SizedBox(
                width: 300,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _reason(context),
                    const SizedBox(height: 16),
                    _Label('Length'),
                    const SizedBox(height: 6),
                    _durationChips(context),
                    const SizedBox(height: 16),
                    _Label('Block'),
                    const SizedBox(height: 6),
                    _summary(context),
                    if (_dayLoad != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        '${_hoursLabel(_dayLoad!.committedMinutes)} of meetings '
                        'that day · ${_hoursLabel(_dayLoad!.freeMinutes)} free',
                        style: TextStyle(color: c.textMuted, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Text(
                      'Click anywhere in a day to move the block there.',
                      style: TextStyle(color: c.textMuted, fontSize: 11),
                    ),
                    const Spacer(),
                    _actions(context),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Compact: a day with its load bar
// ---------------------------------------------------------------------------

class _DayRow extends StatelessWidget {
  const _DayRow({
    required this.load,
    required this.selected,
    required this.now,
    required this.onTap,
  });

  final DayLoad load;
  final bool selected;
  final DateTime now;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return InkWell(
      onTap: onTap,
      child: Container(
        color: selected ? AppColors.accent.withAlpha(20) : null,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Row(
          children: [
            SizedBox(
              width: 84,
              child: Text(
                _dayLabel(load.day, now),
                style: TextStyle(
                  color: selected ? AppColors.accent : c.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            Expanded(child: _LoadBar(load: load.load)),
            const SizedBox(width: 10),
            SizedBox(
              width: 76,
              child: Text(
                load.committedMinutes == 0
                    ? 'clear'
                    : '${_hoursLabel(load.committedMinutes)} busy',
                textAlign: TextAlign.right,
                style: TextStyle(color: c.textMuted, fontSize: 11),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _LoadBar extends StatelessWidget {
  const _LoadBar({required this.load});

  final double load;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final color = load >= 0.75
        ? AppColors.notification
        : load >= 0.4
            ? const Color(0xFFF59E0B)
            : AppColors.accent;
    return Container(
      height: 8,
      decoration: BoxDecoration(
        color: c.surfaceBase,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.separator),
      ),
      clipBehavior: Clip.antiAlias,
      alignment: Alignment.centerLeft,
      child: FractionallySizedBox(
        widthFactor: load.clamp(0.0, 1.0),
        child: ColoredBox(color: color.withAlpha(170)),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Wide: the week grid
// ---------------------------------------------------------------------------

/// The candidate days as columns against an hour axis, with the day's
/// meetings drawn to scale and the proposed block in accent. A tap in a
/// column puts the block's start at that moment, snapped to the slot grid and
/// kept inside the working window.
class _WeekGrid extends StatelessWidget {
  const _WeekGrid({
    required this.days,
    required this.events,
    required this.suggester,
    required this.blockStart,
    required this.blockEnd,
    required this.now,
    required this.onPick,
  });

  final List<DayLoad> days;
  final List<CalendarEvent> events;
  final SuggestTimeBlock suggester;
  final DateTime blockStart;
  final DateTime blockEnd;
  final DateTime now;
  final ValueChanged<DateTime> onPick;

  static const double _axisWidth = 48;

  /// Two lines (day label, load bar + hours) plus padding.
  static const double _headerHeight = 56;

  int get _firstHour => (suggester.workingDayStartHour - 1).clamp(0, 23);
  int get _lastHour => (suggester.workingDayEndHour + 1).clamp(1, 24);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final hours = _lastHour - _firstHour;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: c.separatorStrong),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          // Day headers.
          SizedBox(
            height: _headerHeight,
            child: Row(
              children: [
                const SizedBox(width: _axisWidth),
                for (final d in days)
                  Expanded(
                    child: _DayHeader(
                      load: d,
                      now: now,
                      selected: _sameDay(d.day, blockStart),
                    ),
                  ),
              ],
            ),
          ),
          Divider(height: 1, color: c.separatorStrong),
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final pxPerMinute = constraints.maxHeight / (hours * 60);
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(
                      width: _axisWidth,
                      child: Stack(
                        children: [
                          for (var h = _firstHour; h < _lastHour; h++)
                            Positioned(
                              top: (h - _firstHour) * 60 * pxPerMinute - 7,
                              right: 6,
                              child: Text(
                                DateFormat.j().format(DateTime(2000, 1, 1, h)),
                                style: TextStyle(
                                  color: c.textMuted,
                                  fontSize: 10,
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                    for (final d in days)
                      Expanded(
                        child: _DayColumn(
                          key: ValueKey(
                            'schedule-day-${DateFormat('yyyy-MM-dd').format(d.day)}',
                          ),
                          day: d.day,
                          events: events,
                          suggester: suggester,
                          firstHour: _firstHour,
                          lastHour: _lastHour,
                          pxPerMinute: pxPerMinute,
                          blockStart: blockStart,
                          blockEnd: blockEnd,
                          now: now,
                          onPick: onPick,
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _DayHeader extends StatelessWidget {
  const _DayHeader({
    required this.load,
    required this.now,
    required this.selected,
  });

  final DayLoad load;
  final DateTime now;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Container(
      color: selected ? AppColors.accent.withAlpha(16) : null,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _dayLabel(load.day, now),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: selected ? AppColors.accent : c.textSecondary,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Row(
            children: [
              Expanded(child: _LoadBar(load: load.load)),
              const SizedBox(width: 6),
              Text(
                load.committedMinutes == 0
                    ? 'clear'
                    : _hoursLabel(load.committedMinutes),
                style: TextStyle(color: c.textMuted, fontSize: 10),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DayColumn extends StatelessWidget {
  const _DayColumn({
    super.key,
    required this.day,
    required this.events,
    required this.suggester,
    required this.firstHour,
    required this.lastHour,
    required this.pxPerMinute,
    required this.blockStart,
    required this.blockEnd,
    required this.now,
    required this.onPick,
  });

  final DateTime day;
  final List<CalendarEvent> events;
  final SuggestTimeBlock suggester;
  final int firstHour;
  final int lastHour;
  final double pxPerMinute;
  final DateTime blockStart;
  final DateTime blockEnd;
  final DateTime now;
  final ValueChanged<DateTime> onPick;

  DateTime get _gridStart => DateTime(day.year, day.month, day.day, firstHour);
  DateTime get _gridEnd => DateTime(day.year, day.month, day.day, lastHour);

  double _top(DateTime t) =>
      t.difference(_gridStart).inMinutes.clamp(0, (lastHour - firstHour) * 60) *
      pxPerMinute;

  void _tapped(Offset local) {
    final minutes = (local.dy / pxPerMinute).round();
    final slot = suggester.slotMinutes;
    final snapped = (minutes ~/ slot) * slot;
    var start = _gridStart.add(Duration(minutes: snapped));
    // Keep the block inside the working window.
    final workStart = DateTime(day.year, day.month, day.day, suggester.workingDayStartHour);
    final workEnd = DateTime(day.year, day.month, day.day, suggester.workingDayEndHour);
    final length = blockEnd.difference(blockStart);
    if (start.isBefore(workStart)) start = workStart;
    if (start.add(length).isAfter(workEnd)) start = workEnd.subtract(length);
    if (start.isBefore(workStart)) start = workStart;
    onPick(start);
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final isBlockDay = _sameDay(day, blockStart);
    final workTop = _top(DateTime(day.year, day.month, day.day, suggester.workingDayStartHour));
    final workBottom = _top(DateTime(day.year, day.month, day.day, suggester.workingDayEndHour));

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTapDown: (d) => _tapped(d.localPosition),
      child: Container(
        decoration: BoxDecoration(
          border: Border(left: BorderSide(color: c.separator)),
        ),
        child: Stack(
          children: [
            // The working window, lightly tinted.
            Positioned(
              top: workTop,
              left: 0,
              right: 0,
              height: workBottom - workTop,
              child: ColoredBox(color: c.surfaceBase.withAlpha(140)),
            ),
            // Hour lines.
            for (var h = firstHour + 1; h < lastHour; h++)
              Positioned(
                top: (h - firstHour) * 60 * pxPerMinute,
                left: 0,
                right: 0,
                child: Divider(height: 1, color: c.separator),
              ),
            // Meetings.
            for (final e in events)
              if (_sameDay(e.start.toLocal(), day) && !e.isAllDay)
                Positioned(
                  top: _top(e.start.toLocal()),
                  left: 3,
                  right: 3,
                  height: (_top(e.end.toLocal()) - _top(e.start.toLocal()))
                      .clamp(12.0, double.infinity),
                  child: _EventBlock(event: e),
                ),
            // The proposed block.
            if (isBlockDay)
              Positioned(
                top: _top(blockStart),
                left: 2,
                right: 2,
                height: (_top(blockEnd) - _top(blockStart))
                    .clamp(18.0, double.infinity),
                child: _ProposedBlock(start: blockStart, end: blockEnd),
              ),
            // Now line.
            if (_sameDay(day, now) && now.isAfter(_gridStart) && now.isBefore(_gridEnd))
              Positioned(
                top: _top(now),
                left: 0,
                right: 0,
                child: Container(height: 1.5, color: AppColors.notification),
              ),
          ],
        ),
      ),
    );
  }
}

class _EventBlock extends StatelessWidget {
  const _EventBlock({required this.event});

  final CalendarEvent event;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final tentative = event.status == CalendarEventStatus.tentative ||
        event.status == CalendarEventStatus.free;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: c.stateIcon.withAlpha(tentative ? 110 : 220),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: c.separatorStrong),
      ),
      child: Text(
        event.subject,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: c.textTertiary, fontSize: 10),
      ),
    );
  }
}

class _ProposedBlock extends StatelessWidget {
  const _ProposedBlock({required this.start, required this.end});

  final DateTime start;
  final DateTime end;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.accent.withAlpha(60),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: AppColors.accent, width: 1.5),
      ),
      child: Text(
        '${DateFormat.jm().format(start)} – ${DateFormat.jm().format(end)}',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(
          color: AppColors.accent,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _Label extends StatelessWidget {
  const _Label(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    return Text(
      text.toUpperCase(),
      style: TextStyle(
        color: c.textMuted,
        fontSize: 10,
        fontWeight: FontWeight.w600,
        letterSpacing: 0.6,
      ),
    );
  }
}

bool _sameDay(DateTime a, DateTime b) =>
    a.year == b.year && a.month == b.month && a.day == b.day;

String _dayLabel(DateTime day, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final diff = day.difference(today).inDays;
  final date = DateFormat('EEE d MMM').format(day);
  if (diff == 0) return 'Today · $date';
  if (diff == 1) return 'Tomorrow · $date';
  return date;
}

String _hoursLabel(int minutes) {
  if (minutes == 0) return '0 h';
  final h = minutes / 60;
  return h == h.roundToDouble() ? '${h.round()} h' : '${h.toStringAsFixed(1)} h';
}

String _durationLabel(Duration d) {
  if (d.inMinutes < 60) return '${d.inMinutes} min';
  final h = d.inMinutes / 60;
  return h == h.roundToDouble() ? '${h.round()} h' : '${h.toStringAsFixed(1)} h';
}
