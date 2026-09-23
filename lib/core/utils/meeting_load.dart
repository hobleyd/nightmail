import '../../domain/entities/calendar_event.dart';

/// The share of a working day (9am–5pm, local time, by default) that is
/// committed to meetings, as a fraction in `0.0..1.0`. Drawn as the progress
/// bar on each day of the calendar's month view.
///
/// Three rules keep the number honest:
///
///  * **Only meetings that occupy time count.** All-day entries are not
///    meetings, and neither is anything [CalendarEvent.blocksTime] rules out
///    (marked free, a working-location marker). A meeting the user declined is
///    off their plate and is excluded too — a tentative or unanswered one is
///    still a commitment until it is answered, so it stays in.
///  * **Overlaps are counted once.** Two meetings over the same hour are one
///    committed hour, not two, so the bar can never read past full.
///  * **Everything is clipped to the window.** A meeting running 8–10 counts
///    one hour; one that spans midnight counts only its share of this day.
///
/// [day] identifies the calendar date in local time; its time-of-day is
/// ignored. Event instants are converted to local time before comparison.
double workingDayMeetingLoad(
  Iterable<CalendarEvent> events,
  DateTime day, {
  int startHour = 9,
  int endHour = 17,
}) {
  final windowStart = DateTime(day.year, day.month, day.day, startHour);
  final windowEnd = DateTime(day.year, day.month, day.day, endHour);
  final windowMinutes = windowEnd.difference(windowStart).inMinutes;
  if (windowMinutes <= 0) return 0;

  final spans = <(DateTime, DateTime)>[];
  for (final e in events) {
    if (e.isAllDay || !e.blocksTime) continue;
    if (e.participation == MeetingParticipation.declined) continue;
    final start = e.start.toLocal();
    final end = e.end.toLocal();
    final from = start.isAfter(windowStart) ? start : windowStart;
    final to = end.isBefore(windowEnd) ? end : windowEnd;
    if (!to.isAfter(from)) continue;
    spans.add((from, to));
  }
  if (spans.isEmpty) return 0;

  spans.sort((a, b) => a.$1.compareTo(b.$1));
  var committed = 0;
  var curStart = spans.first.$1;
  var curEnd = spans.first.$2;
  for (final (from, to) in spans.skip(1)) {
    if (from.isAfter(curEnd)) {
      committed += curEnd.difference(curStart).inMinutes;
      curStart = from;
      curEnd = to;
    } else if (to.isAfter(curEnd)) {
      curEnd = to;
    }
  }
  committed += curEnd.difference(curStart).inMinutes;

  return (committed / windowMinutes).clamp(0.0, 1.0);
}
