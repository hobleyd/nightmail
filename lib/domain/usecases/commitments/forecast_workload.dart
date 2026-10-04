import '../../entities/calendar_event.dart';
import '../../entities/commitment.dart';
import '../../entities/workload_forecast.dart';
import 'suggest_time_block.dart';

/// "Future Me": reads the week ahead and says where it is going to hurt.
///
/// Pure — calendar events, the open ledger and task due dates in, a
/// [WorkloadForecast] out — so the pane recomputes it on every refresh and a
/// test can pin each rule:
///
/// * **Horizon**: today (while it is a working day) and the following working
///   days, [horizonWorkingDays] in all.
/// * **Capacity** is the working window minus meetings, where the user's own
///   commitment blocks are *not* meetings — they are demand already placed.
/// * **Demand** is blocked time plus an estimate for everything else landing
///   on the day: [minutesPerCommitment] per unscheduled commitment,
///   [minutesPerTask] per task due. A commitment lands on the day of its
///   block if it has one; otherwise today when due today or overdue, the
///   week's last working day when due this week, nowhere when open-ended.
/// * A day is **overloaded** when demand exceeds capacity. For each such
///   day a [RebalancePlan] proposes moving its least urgent movable items —
///   blocks first, then unscheduled commitments — to the freest other day
///   their deadline allows, each into a real free slot, until the day fits
///   or nothing movable is left. Items due *today* on today cannot move.
/// * **Open slots** are gaps in the rest of today of at least [minOpenSlot],
///   each paired with the most pressing unscheduled commitment that fits.
///   A slot is *freed* when a meeting overlapped it at the previous look
///   ([previousEvents]) and is gone now — the cancelled-meeting moment.
class ForecastWorkload {
  const ForecastWorkload({
    this.suggester = const SuggestTimeBlock(),
    this.horizonWorkingDays = 5,
    this.minutesPerCommitment = 60,
    this.minutesPerTask = 30,
    this.minOpenSlot = const Duration(minutes: 45),
    this.maxOpenSlots = 3,
  });

  final SuggestTimeBlock suggester;
  final int horizonWorkingDays;
  final int minutesPerCommitment;
  final int minutesPerTask;
  final Duration minOpenSlot;
  final int maxOpenSlots;

  WorkloadForecast call({
    required List<Commitment> commitments,
    required List<CalendarEvent> events,
    required List<DateTime> taskDueDates,
    required DateTime now,
    List<CalendarEvent>? previousEvents,
  }) {
    final open = [for (final c in commitments) if (c.isOpen) c];
    final blockIds = {
      for (final c in open)
        if (c.scheduledEventId != null) c.scheduledEventId!,
    };
    final meetings = [for (final e in events) if (!blockIds.contains(e.id)) e];

    final days = horizon(now);
    final forecasts = [
      for (final day in days)
        _forecastDay(day, days, open, meetings, taskDueDates, now),
    ];

    final plans = <RebalancePlan>[];
    for (final day in forecasts) {
      if (day.isOverloaded) {
        plans.add(_rebalance(day, forecasts, events, now));
      }
    }

    return WorkloadForecast(
      days: forecasts,
      plans: plans,
      openSlots: _openSlots(open, events, previousEvents, now),
      computedAt: now,
    );
  }

  // ---------------------------------------------------------------------------
  // Horizon and landing
  // ---------------------------------------------------------------------------

  /// Today (when a working day) and the working days after it.
  List<DateTime> horizon(DateTime now) {
    final out = <DateTime>[];
    var d = DateTime(now.year, now.month, now.day);
    while (out.length < horizonWorkingDays) {
      if (_isWorkingDay(d)) out.add(d);
      d = d.add(const Duration(days: 1));
    }
    return out;
  }

  /// The day an open commitment lands on, or null for an open-ended one.
  DateTime? landingDay(Commitment c, DateTime now, List<DateTime> days) {
    final start = c.scheduledStart;
    if (start != null) return DateTime(start.year, start.month, start.day);
    final today = DateTime(now.year, now.month, now.day);
    if (c.isOverdueAt(now)) return today;
    switch (c.due) {
      case CommitmentDue.today:
        return today;
      case CommitmentDue.thisWeek:
        // The last working day of this week that is still ahead.
        DateTime? last;
        for (final d in days) {
          if (d.weekday > DateTime.friday) continue;
          if (_weekOf(d) != _weekOf(today)) break;
          last = d;
        }
        return last ?? today;
      case CommitmentDue.later:
      case CommitmentDue.none:
        return null;
    }
  }

  DayForecast _forecastDay(
    DateTime day,
    List<DateTime> days,
    List<Commitment> open,
    List<CalendarEvent> meetings,
    List<DateTime> taskDueDates,
    DateTime now,
  ) {
    final load = suggester.loadFor(day, meetings);

    var blocked = 0;
    final landing = <Commitment>[];
    for (final c in open) {
      if (landingDay(c, now, days) != day) continue;
      landing.add(c);
      final s = c.scheduledStart;
      final e = c.scheduledEnd;
      if (s != null && e != null) blocked += e.difference(s).inMinutes;
    }

    return DayForecast(
      day: day,
      workingMinutes: load.workingMinutes,
      meetingMinutes: load.committedMinutes,
      blockedMinutes: blocked,
      landing: landing,
      tasksDue: taskDueDates.where((t) => _sameDay(t, day)).length,
      minutesPerCommitment: minutesPerCommitment,
      minutesPerTask: minutesPerTask,
    );
  }

  // ---------------------------------------------------------------------------
  // Rebalancing
  // ---------------------------------------------------------------------------

  RebalancePlan _rebalance(
    DayForecast day,
    List<DayForecast> all,
    List<CalendarEvent> events,
    DateTime now,
  ) {
    final today = DateTime(now.year, now.month, now.day);
    var excess = day.demandMinutes - day.capacityMinutes;
    final moves = <ScheduleMove>[];
    var relieved = 0;

    // Everything on the day that could go elsewhere, least urgent first:
    // scheduled blocks, then unscheduled commitments. A commitment due today
    // that lands on today has nowhere to go.
    final movable = [
      for (final c in day.landing)
        if (!(day.day == today &&
            !c.isScheduled &&
            (c.due == CommitmentDue.today || c.isOverdueAt(now))))
          c,
    ]..sort((a, b) {
        final byScheduled = (b.isScheduled ? 1 : 0) - (a.isScheduled ? 1 : 0);
        if (byScheduled != 0) return byScheduled;
        return a.urgency.compareTo(b.urgency);
      });

    // Free time per other day, reduced as moves land there; plus the moves
    // themselves as pseudo-events so two moves never take the same slot.
    final free = {for (final d in all) d.day: d.freeMinutes};
    final planned = <CalendarEvent>[];

    for (final c in movable) {
      if (excess <= 0) break;
      final length = c.isScheduled
          ? c.scheduledEnd!.difference(c.scheduledStart!)
          : c.estimateOr(Duration(minutes: minutesPerCommitment));
      final deadline = _deadlineDay(c, now, all.map((d) => d.day).toList());

      // Freest day first; on a tie the earlier day, so the choice is stable
      // and a deadline is met with room to spare.
      final targets = [
        for (final d in all)
          if (d.day != day.day &&
              (deadline == null || !d.day.isAfter(deadline)) &&
              !(d.day == today && !now.isBefore(_workingEnd(today))))
            d,
      ]..sort((a, b) {
          final byFree = free[b.day]!.compareTo(free[a.day]!);
          return byFree != 0 ? byFree : a.day.compareTo(b.day);
        });

      for (final target in targets) {
        if (free[target.day]! < length.inMinutes) break;
        final slot = suggester.firstFreeSlot(
          day: target.day,
          events: [...events, ...planned],
          now: now,
          duration: length,
        );
        if (slot == null) continue;
        moves.add(ScheduleMove(
          commitment: c,
          from: c.scheduledStart,
          toStart: slot,
          toEnd: slot.add(length),
        ));
        planned.add(CalendarEvent(
          id: 'planned:${c.id}',
          subject: c.subject,
          start: slot,
          end: slot.add(length),
          isAllDay: false,
        ));
        free[target.day] = free[target.day]! - length.inMinutes;
        relieved += length.inMinutes;
        excess -= length.inMinutes;
        break;
      }
    }

    return RebalancePlan(day: day, moves: moves, relievedMinutes: relieved);
  }

  /// The last day a commitment may be moved to, or null when open-ended.
  DateTime? _deadlineDay(Commitment c, DateTime now, List<DateTime> days) {
    final today = DateTime(now.year, now.month, now.day);
    if (c.isOverdueAt(now)) return today;
    switch (c.due) {
      case CommitmentDue.today:
        return today;
      case CommitmentDue.thisWeek:
        DateTime? last;
        for (final d in days) {
          if (_weekOf(d) != _weekOf(today)) break;
          last = d;
        }
        return last ?? today;
      case CommitmentDue.later:
      case CommitmentDue.none:
        return null;
    }
  }

  // ---------------------------------------------------------------------------
  // Open slots
  // ---------------------------------------------------------------------------

  List<OpenSlot> _openSlots(
    List<Commitment> open,
    List<CalendarEvent> events,
    List<CalendarEvent>? previous,
    DateTime now,
  ) {
    final today = DateTime(now.year, now.month, now.day);
    if (!_isWorkingDay(today)) return const [];
    final windowEnd = _workingEnd(today);
    var cursor = _max(_workingStart(today), _roundUp(now));
    if (!cursor.isBefore(windowEnd)) return const [];

    // Busy spans today (including the user's own blocks), merged and sorted.
    final spans = <({DateTime start, DateTime end})>[];
    for (final e in events) {
      if (e.isAllDay || e.status == CalendarEventStatus.free) continue;
      final s = _max(e.start.toLocal(), cursor);
      final en = _min(e.end.toLocal(), windowEnd);
      if (en.isAfter(s)) spans.add((start: s, end: en));
    }
    spans.sort((a, b) => a.start.compareTo(b.start));

    final gaps = <({DateTime start, DateTime end})>[];
    for (final span in spans) {
      if (span.start.difference(cursor) >= minOpenSlot) {
        gaps.add((start: cursor, end: span.start));
      }
      if (span.end.isAfter(cursor)) cursor = span.end;
    }
    if (windowEnd.difference(cursor) >= minOpenSlot) {
      gaps.add((start: cursor, end: windowEnd));
    }

    // Most pressing unscheduled commitments first.
    final candidates = [
      for (final c in open)
        if (!c.isScheduled) c,
    ]..sort((a, b) {
        final byOverdue =
            (b.isOverdueAt(now) ? 1 : 0) - (a.isOverdueAt(now) ? 1 : 0);
        if (byOverdue != 0) return byOverdue;
        final byUrgency = b.urgency.compareTo(a.urgency);
        if (byUrgency != 0) return byUrgency;
        final byDue = a.due.index.compareTo(b.due.index);
        if (byDue != 0) return byDue;
        return a.emailDate.compareTo(b.emailDate);
      });
    final used = <String>{};

    final out = <OpenSlot>[];
    for (final gap in gaps.take(maxOpenSlots)) {
      Commitment? pick;
      for (final c in candidates) {
        if (used.contains(c.id)) continue;
        pick = c;
        break;
      }
      if (pick != null) used.add(pick.id);

      final freed = previous != null &&
          previous.any((p) =>
              !p.isAllDay &&
              !events.any((e) => e.id == p.id) &&
              p.start.toLocal().isBefore(gap.end) &&
              p.end.toLocal().isAfter(gap.start));

      out.add(OpenSlot(
        start: gap.start,
        end: gap.end,
        suggestion: pick,
        freed: freed,
      ));
    }
    return out;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static bool _isWorkingDay(DateTime d) =>
      d.weekday != DateTime.saturday && d.weekday != DateTime.sunday;

  static bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  /// Monday of the week [d] is in, as a comparable day.
  static DateTime _weekOf(DateTime d) {
    final day = DateTime(d.year, d.month, d.day);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  DateTime _workingStart(DateTime day) =>
      DateTime(day.year, day.month, day.day, suggester.workingDayStartHour);

  DateTime _workingEnd(DateTime day) =>
      DateTime(day.year, day.month, day.day, suggester.workingDayEndHour);

  DateTime _roundUp(DateTime now) {
    final slot = suggester.slotMinutes;
    final minutes = now.hour * 60 + now.minute;
    final rounded = ((minutes + slot - 1) ~/ slot) * slot;
    return DateTime(now.year, now.month, now.day).add(Duration(minutes: rounded));
  }

  static DateTime _max(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
  static DateTime _min(DateTime a, DateTime b) => a.isBefore(b) ? a : b;
}
