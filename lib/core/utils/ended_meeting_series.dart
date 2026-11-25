import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_recurrence.dart';
import 'meeting_conflicts.dart';

/// Whether a series invitation is to a meeting that has already ended, judged
/// from the calendar rather than from the invitation.
///
/// Google's "cancel the rest of this series" is not a `METHOD:CANCEL`: the
/// organizer moves the series' end date back, and every guest is sent
/// "Updated invitation …" as a `METHOD:REQUEST`. Classifying by `METHOD`, the
/// banner offered Accept/Decline on a meeting with nothing left to attend.
///
/// The ICS cannot say so itself. Incident, 25 Nov 2026: "OneVal Release 2 (CBV)
/// - Stand-Up" had been edited "this and following" twice, splitting it into
/// three series (`<uid>`, `<uid>_R20261102T000000`, `<uid>_R20261105T000000`).
/// The update Google mailed carried the *first* segment's
/// `RRULE …;UNTIL=20261101T135959Z` while the series really ran to 23 Nov, so
/// an end date read off the invitation is wrong by three weeks. The calendar
/// holds every segment under the same UID stem, which [isSameMeetingUid]
/// already treats as one meeting.

/// The longest look ahead worth taking for the next occurrence. Beyond this the
/// listing grows past what one page of `events.list` reliably holds, and its
/// ascending sort means a truncated page drops the *future* — exactly the
/// occurrences whose absence would be read as "ended".
const _maxLookahead = Duration(days: 29);

/// How far back an occurrence counts as evidence the series was on this
/// calendar at all. Without one, an empty look-ahead says nothing — a forwarded
/// or hidden invitation is equally absent from the calendar.
const endedSeriesLookback = Duration(days: 21);

/// How far ahead to look for the series' next occurrence, or null when that
/// cannot be settled from a short window: no readable rule, a monthly or yearly
/// series, or one repeating less often than fortnightly.
///
/// Two periods, plus a day, so one occurrence cancelled on its own does not
/// make the series look over.
Duration? endedSeriesLookahead(CalendarRecurrence? recurrence) {
  if (recurrence == null || recurrence.interval <= 0) return null;
  final periodDays = switch (recurrence.frequency) {
    RecurrenceFrequency.daily => recurrence.interval,
    RecurrenceFrequency.weekly => 7 * recurrence.interval,
    RecurrenceFrequency.monthly || RecurrenceFrequency.yearly => null,
  };
  if (periodDays == null) return null;
  final lookahead = Duration(days: 2 * periodDays + 1);
  return lookahead > _maxLookahead ? null : lookahead;
}

/// What the calendar says about a series with nothing coming up.
class SeriesEndCheck {
  const SeriesEndCheck({required this.lastOccurrence, required this.confirmed});

  /// Start of the most recent occurrence of the meeting.
  final DateTime lastOccurrence;

  /// The segment that occurrence belongs to has an `UNTIL` already past, so
  /// the series is over by its own rule. False when the calendar is merely
  /// empty ahead, which a holiday break of a few cancelled weeks also looks
  /// like: occurrences cancelled one at a time are not listed at all.
  final bool confirmed;
}

/// What the calendar says about a series invitation with nothing coming up,
/// or null when something is coming up — or when that cannot be told.
///
/// [upcoming] is the calendar from [now] forward, [recent] the calendar from
/// [endedSeriesLookback] before [now]. Null if any of [upcoming] is this
/// meeting still to come (an occurrence in progress counts), or none of
/// [recent] is an occurrence of it that has started.
///
/// Confirmation reads the rule of the *latest* occurrence's own segment, which
/// is what a split series needs: Google keeps each segment's master on the
/// attendee's calendar (`<uid>_R<split start>`, here with `UNTIL` 23 Nov)
/// even though the mailed ICS names only the first.
SeriesEndCheck? checkSeriesEnd({
  required String? inviteUid,
  required List<CalendarEvent> upcoming,
  required List<CalendarEvent> recent,
  required DateTime now,
}) {
  if (inviteUid == null) return null;
  bool mine(CalendarEvent e) => isSameMeetingUid(e.iCalUid, inviteUid);

  if (upcoming.any((e) => mine(e) && e.end.isAfter(now))) return null;

  CalendarEvent? last;
  for (final e in recent) {
    if (!mine(e) || e.start.isAfter(now)) continue;
    if (last == null || e.start.isAfter(last.start)) last = e;
  }
  if (last == null) return null;
  // `parseRRule` keeps UNTIL as the series' last *day* (a local date), so the
  // series is over by its rule only once that whole day is behind us.
  final lastDay = last.recurrence?.endDate;
  final ruleOver = lastDay != null &&
      !DateTime(lastDay.year, lastDay.month, lastDay.day + 1).isAfter(now);
  return SeriesEndCheck(lastOccurrence: last.start, confirmed: ruleOver);
}
