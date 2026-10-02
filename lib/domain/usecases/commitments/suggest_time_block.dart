import '../../entities/calendar_event.dart';
import '../../entities/commitment.dart';
import '../../entities/time_block_suggestion.dart';

/// Picks a time block for a commitment from a quick look at the coming days:
/// the working day with the least committed time, and the first free slot of
/// the requested length on it.
///
/// Pure — calendar events in, a [TimeBlockSuggestion] out — so the pane and
/// the detached window can both call it and a test can pin every rule:
///
/// * **Horizon follows the due reading.** *Today* looks at today only; *this
///   week* through the end of the working week (at least two days); *later*
///   and *no deadline* at the next five working days. Weekends are skipped;
///   a day whose working window has already passed is skipped too.
/// * **Load is busy minutes inside the working window** (default 9–17),
///   with overlapping meetings merged so a double-booked hour counts once.
///   `free`/tentative-free time is not load; all-day events are not load
///   either, since they describe the day rather than occupy it.
/// * **Least load wins, earliest day breaks ties.** On that day the block
///   is the first run of [duration] inside the window, after now, that no
///   busy meeting overlaps. If the lightest day has no such run the next
///   lightest is tried; if none has one, the block opens the lightest day
///   and is flagged [TimeBlockSuggestion.hasConflict].
///
/// [slotFor] answers the follow-up question when the user picks another day
/// by hand: the first free run on *that* day, or its working start if none.
class SuggestTimeBlock {
  const SuggestTimeBlock({
    this.workingDayStartHour = 9,
    this.workingDayEndHour = 17,
    this.slotMinutes = 30,
  });

  /// Working window, local hours. The window must be at least one slot.
  final int workingDayStartHour;
  final int workingDayEndHour;

  /// Granularity a block may start on.
  final int slotMinutes;

  static const Duration defaultDuration = Duration(minutes: 60);

  TimeBlockSuggestion call({
    required Commitment commitment,
    required List<CalendarEvent> events,
    required DateTime now,
    Duration duration = defaultDuration,
  }) {
    final days = candidateDays(commitment: commitment, now: now);
    final loads = [for (final d in days) loadFor(d, events)];

    // Order candidates by load, then by date.
    final ranked = List<DayLoad>.of(loads)
      ..sort((a, b) {
        final byLoad = a.committedMinutes.compareTo(b.committedMinutes);
        return byLoad != 0 ? byLoad : a.day.compareTo(b.day);
      });

    for (final candidate in ranked) {
      final slot = firstFreeSlot(
        day: candidate.day,
        events: events,
        now: now,
        duration: duration,
      );
      if (slot != null) {
        return TimeBlockSuggestion(
          start: slot,
          end: slot.add(duration),
          days: loads,
          events: _eventsOn(days, events),
          hasConflict: false,
          reason: _reasonFor(candidate, loads, now),
        );
      }
    }

    // Nothing fits anywhere: open the lightest day and say so.
    final lightest = ranked.isEmpty ? loads.first : ranked.first;
    final start = _max(_workingStart(lightest.day), _roundUp(now));
    return TimeBlockSuggestion(
      start: start,
      end: start.add(duration),
      days: loads,
      events: _eventsOn(days, events),
      hasConflict: true,
      reason: 'No free ${_hours(duration)} anywhere in the week; '
          '${_dayName(lightest.day, now)} is the lightest day.',
    );
  }

  /// The block to propose when the user picks [day] themselves: the first
  /// free run of [duration] on it, else its working start.
  DateTime slotFor({
    required DateTime day,
    required List<CalendarEvent> events,
    required DateTime now,
    required Duration duration,
  }) {
    return firstFreeSlot(
      day: day,
      events: events,
      now: now,
      duration: duration,
    ) ??
        _max(_workingStart(day), _roundUp(now));
  }

  /// Whether a block [start]–[end] overlaps a busy meeting.
  bool conflicts(DateTime start, DateTime end, List<CalendarEvent> events) {
    for (final e in events) {
      if (!_isBusy(e)) continue;
      if (e.start.toLocal().isBefore(end) && e.end.toLocal().isAfter(start)) {
        return true;
      }
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // Horizon
  // ---------------------------------------------------------------------------

  /// The working days the commitment could be scheduled on, earliest first.
  List<DateTime> candidateDays({
    required Commitment commitment,
    required DateTime now,
  }) {
    final today = DateTime(now.year, now.month, now.day);
    final todayUsable = now.isBefore(_workingEnd(today).subtract(
      Duration(minutes: slotMinutes),
    ));

    switch (commitment.due) {
      case CommitmentDue.today:
        // Today if any of it is left, else the next working day.
        if (todayUsable && _isWorkingDay(today)) return [today];
        return [_nextWorkingDay(today.add(const Duration(days: 1)))];
      case CommitmentDue.thisWeek:
        final days = <DateTime>[];
        var d = today;
        // Through Friday of this week…
        while (d.weekday <= DateTime.friday) {
          if (_isWorkingDay(d) && (d != today || todayUsable)) days.add(d);
          d = d.add(const Duration(days: 1));
        }
        // …but never fewer than two working days, so a Friday-afternoon
        // "this week" (or a weekend) still has somewhere to go.
        d = _nextWorkingDay(d);
        while (days.length < 2) {
          days.add(d);
          d = _nextWorkingDay(d.add(const Duration(days: 1)));
        }
        return days;
      case CommitmentDue.later:
      case CommitmentDue.none:
        final days = <DateTime>[];
        var d = today;
        while (days.length < 5) {
          if (_isWorkingDay(d) && (d != today || todayUsable)) days.add(d);
          d = d.add(const Duration(days: 1));
        }
        return days;
    }
  }

  // ---------------------------------------------------------------------------
  // Load and free slots
  // ---------------------------------------------------------------------------

  /// Busy minutes inside [day]'s working window, overlaps merged.
  DayLoad loadFor(DateTime day, List<CalendarEvent> events) {
    final windowStart = _workingStart(day);
    final windowEnd = _workingEnd(day);
    final workingMinutes = windowEnd.difference(windowStart).inMinutes;

    final spans = <({DateTime start, DateTime end})>[];
    for (final e in events) {
      if (!_isBusy(e)) continue;
      final s = _max(e.start.toLocal(), windowStart);
      final en = _min(e.end.toLocal(), windowEnd);
      if (en.isAfter(s)) spans.add((start: s, end: en));
    }
    spans.sort((a, b) => a.start.compareTo(b.start));

    var committed = 0;
    DateTime? curStart;
    DateTime? curEnd;
    for (final span in spans) {
      if (curEnd == null || span.start.isAfter(curEnd)) {
        if (curStart != null) committed += curEnd!.difference(curStart).inMinutes;
        curStart = span.start;
        curEnd = span.end;
      } else if (span.end.isAfter(curEnd)) {
        curEnd = span.end;
      }
    }
    if (curStart != null) committed += curEnd!.difference(curStart).inMinutes;

    return DayLoad(
      day: day,
      committedMinutes: committed,
      workingMinutes: workingMinutes,
    );
  }

  /// The first start on [day], on the slot grid, after [now], from which
  /// [duration] fits inside the working window with no busy overlap.
  DateTime? firstFreeSlot({
    required DateTime day,
    required List<CalendarEvent> events,
    required DateTime now,
    required Duration duration,
  }) {
    final windowEnd = _workingEnd(day);
    var cursor = _max(_workingStart(day), _roundUp(now));
    while (!cursor.add(duration).isAfter(windowEnd)) {
      final end = cursor.add(duration);
      if (!conflicts(cursor, end, events)) return cursor;
      cursor = cursor.add(Duration(minutes: slotMinutes));
    }
    return null;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  static bool _isBusy(CalendarEvent e) =>
      !e.isAllDay && e.status != CalendarEventStatus.free;

  static bool _isWorkingDay(DateTime d) =>
      d.weekday != DateTime.saturday && d.weekday != DateTime.sunday;

  static DateTime _nextWorkingDay(DateTime from) {
    var d = DateTime(from.year, from.month, from.day);
    while (!_isWorkingDay(d)) {
      d = d.add(const Duration(days: 1));
    }
    return d;
  }

  DateTime _workingStart(DateTime day) =>
      DateTime(day.year, day.month, day.day, workingDayStartHour);

  DateTime _workingEnd(DateTime day) =>
      DateTime(day.year, day.month, day.day, workingDayEndHour);

  /// [now] rounded up to the next slot boundary.
  DateTime _roundUp(DateTime now) {
    final minutes = now.hour * 60 + now.minute;
    final rounded = ((minutes + slotMinutes - 1) ~/ slotMinutes) * slotMinutes;
    final base = DateTime(now.year, now.month, now.day);
    return base.add(Duration(minutes: rounded));
  }

  static DateTime _max(DateTime a, DateTime b) => a.isAfter(b) ? a : b;
  static DateTime _min(DateTime a, DateTime b) => a.isBefore(b) ? a : b;

  static List<CalendarEvent> _eventsOn(
    List<DateTime> days,
    List<CalendarEvent> events,
  ) {
    if (days.isEmpty) return const [];
    final first = days.first;
    final last = days.last.add(const Duration(days: 1));
    return [
      for (final e in events)
        if (e.start.toLocal().isBefore(last) && e.end.toLocal().isAfter(first))
          e,
    ];
  }

  static String _reasonFor(DayLoad chosen, List<DayLoad> all, DateTime now) {
    final name = _dayName(chosen.day, now);
    final hours = _hours(Duration(minutes: chosen.committedMinutes));
    if (all.length == 1) {
      return chosen.committedMinutes == 0
          ? '$name is clear.'
          : '$name has $hours of meetings.';
    }
    final lighter = all.where(
      (d) => d.committedMinutes < chosen.committedMinutes,
    );
    if (lighter.isEmpty) {
      return chosen.committedMinutes == 0
          ? '$name is clear — the lightest day in the week.'
          : '$name is the lightest day in the week, with $hours of meetings.';
    }
    return '$name has $hours of meetings.';
  }

  static String _dayName(DateTime day, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final diff = day.difference(today).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Tomorrow';
    const names = [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ];
    return names[day.weekday - 1];
  }

  static String _hours(Duration d) {
    final h = d.inMinutes / 60;
    if (d.inMinutes == 0) return 'no time';
    if (h == h.roundToDouble()) return '${h.round()} h';
    return '${h.toStringAsFixed(1)} h';
  }
}
