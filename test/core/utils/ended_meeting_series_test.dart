import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/ended_meeting_series.dart';
import 'package:nightmail/core/utils/rrule.dart';
import 'package:nightmail/data/datasources/remote/ics_meeting_invite.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_recurrence.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';

/// The 25 Nov 2026 incident: a weekday stand-up cut short at Mon 23 Nov by
/// moving its end date, mailed as "Updated invitation" with an ICS whose UNTIL
/// (1 Nov) belongs to the first of three split segments.
const _uid = 'gacrfrmvm41s2kp486g69kiehb@google.com';
final _now = DateTime.utc(2026, 11, 25, 7);

/// The rule Google holds for the segment the 2–23 Nov occurrences belong to,
/// `gacrfrmvm41s2kp486g69kiehb_R20261105T000000`, read off the real calendar.
final _endedSegment = parseRRule('RRULE:FREQ=WEEKLY;WKST=SU;'
    'UNTIL=20261123T135959Z;BYDAY=MO,TU,WE,TH,FR')!;

CalendarEvent _occurrence(
  DateTime start, {
  String iCalUid = _uid,
  CalendarRecurrence? recurrence,
}) =>
    CalendarEvent(
      id: start.toIso8601String(),
      subject: 'OneVal Release 2 (CBV) - Stand-Up',
      start: start,
      end: start.add(const Duration(minutes: 15)),
      isAllDay: false,
      iCalUid: iCalUid,
      recurrence: recurrence,
    );

SeriesEndCheck? _check({
  List<CalendarEvent> upcoming = const [],
  List<CalendarEvent> recent = const [],
  String? uid = _uid,
}) =>
    checkSeriesEnd(
      inviteUid: uid,
      upcoming: upcoming,
      recent: recent,
      now: _now,
    );

void main() {
  group('checkSeriesEnd', () {
    test('the incident: the split segment\'s own UNTIL has passed', () {
      // Stored iCalUID of those occurrences, from the cache database.
      const segmentUid = 'gacrfrmvm41s2kp486g69kiehb_R20261105T000000'
          '@google.com';
      final last = DateTime.utc(2026, 11, 23);
      final check = _check(recent: [
        _occurrence(DateTime.utc(2026, 11, 19),
            iCalUid: segmentUid, recurrence: _endedSegment),
        _occurrence(last, iCalUid: segmentUid, recurrence: _endedSegment),
        _occurrence(DateTime.utc(2026, 11, 20),
            iCalUid: segmentUid, recurrence: _endedSegment),
      ]);
      expect(check?.lastOccurrence, last);
      expect(check?.confirmed, isTrue);
    });

    test('a break in an open-ended series is not confirmed as an end', () {
      // Weeks cancelled over Christmas are simply not listed; the rule says
      // the meeting goes on.
      final check = _check(recent: [
        _occurrence(DateTime.utc(2026, 11, 23),
            recurrence: const CalendarRecurrence(
                frequency: RecurrenceFrequency.weekly)),
      ]);
      expect(check?.lastOccurrence, DateTime.utc(2026, 11, 23));
      expect(check?.confirmed, isFalse);
    });

    test('a rule ending after today is not confirmed as an end', () {
      final check = _check(recent: [
        _occurrence(DateTime.utc(2026, 11, 23),
            recurrence: CalendarRecurrence(
                frequency: RecurrenceFrequency.weekly,
                endDate: DateTime.utc(2027, 2, 1))),
      ]);
      expect(check?.confirmed, isFalse);
    });

    test('a rule whose last day is today is not confirmed yet', () {
      final today = _now.toLocal();
      final check = _check(recent: [
        _occurrence(_now.subtract(const Duration(hours: 1)),
            recurrence: CalendarRecurrence(
                frequency: RecurrenceFrequency.weekly,
                endDate: DateTime(today.year, today.month, today.day))),
      ]);
      expect(check?.confirmed, isFalse);
    });

    test('an unknown rule is not confirmed as an end', () {
      expect(
        _check(recent: [_occurrence(DateTime.utc(2026, 11, 23))])?.confirmed,
        isFalse,
      );
    });

    test('an occurrence still to come means nothing to report', () {
      expect(
        _check(
          upcoming: [_occurrence(DateTime.utc(2026, 11, 26))],
          recent: [
            _occurrence(DateTime.utc(2026, 11, 24), recurrence: _endedSegment),
          ],
        ),
        isNull,
      );
    });

    test('an occurrence in progress means nothing to report', () {
      final inProgress = _occurrence(_now.subtract(const Duration(minutes: 5)));
      expect(_check(upcoming: [inProgress], recent: [inProgress]), isNull);
    });

    test('nothing on the calendar either side settles nothing', () {
      // A forwarded or hidden invitation is just as absent as an ended one.
      expect(_check(), isNull);
    });

    test('other meetings are not evidence', () {
      expect(
        _check(recent: [
          _occurrence(DateTime.utc(2026, 11, 23),
              iCalUid: 'other@google.com', recurrence: _endedSegment),
        ]),
        isNull,
      );
    });

    test('an invitation with no UID settles nothing', () {
      expect(
        _check(uid: null, recent: [_occurrence(DateTime.utc(2026, 11, 23))]),
        isNull,
      );
    });
  });

  test('the incident\'s ICS yields a rule the check will judge', () {
    // Trimmed from the real "Updated invitation with note" message: the
    // banner returns early, silently, if this ever stops parsing.
    const ics = 'BEGIN:VCALENDAR\r\n'
        'METHOD:REQUEST\r\n'
        'BEGIN:VEVENT\r\n'
        'DTSTART;TZID=Australia/Brisbane:20261030T100000\r\n'
        'DTEND;TZID=Australia/Brisbane:20261030T101500\r\n'
        'RRULE:FREQ=WEEKLY;WKST=SU;UNTIL=20261101T135959Z;'
        'BYDAY=MO,TU,WE,TH,FR\r\n'
        'UID:gacrfrmvm41s2kp486g69kiehb@google.com\r\n'
        'SEQUENCE:1\r\n'
        'STATUS:CONFIRMED\r\n'
        'SUMMARY:OneVal Release 2 (CBV) - Stand-Up\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR\r\n';
    final invite = buildMeetingInviteFromIcs(ics);
    expect(invite.type, MeetingEmailType.invitation);
    expect(invite.uid, _uid);
    expect(endedSeriesLookahead(invite.recurrence), const Duration(days: 15));
    // UNTIL is kept as the series' last day, not an instant.
    expect(_endedSegment.endDate, DateTime(2026, 11, 23));
  });

  group('endedSeriesLookahead', () {
    test('weekly looks two weeks and a day ahead', () {
      expect(
        endedSeriesLookahead(const CalendarRecurrence(
          frequency: RecurrenceFrequency.weekly,
          daysOfWeek: [1, 2, 3, 4, 5],
        )),
        const Duration(days: 15),
      );
    });

    test('daily looks two days and a day ahead', () {
      expect(
        endedSeriesLookahead(
            const CalendarRecurrence(frequency: RecurrenceFrequency.daily)),
        const Duration(days: 3),
      );
    });

    test('fortnightly is the longest it will judge', () {
      expect(
        endedSeriesLookahead(const CalendarRecurrence(
            frequency: RecurrenceFrequency.weekly, interval: 2)),
        const Duration(days: 29),
      );
      expect(
        endedSeriesLookahead(const CalendarRecurrence(
            frequency: RecurrenceFrequency.weekly, interval: 3)),
        isNull,
      );
    });

    test('monthly, yearly and unreadable rules are not judged', () {
      expect(
        endedSeriesLookahead(
            const CalendarRecurrence(frequency: RecurrenceFrequency.monthly)),
        isNull,
      );
      expect(
        endedSeriesLookahead(
            const CalendarRecurrence(frequency: RecurrenceFrequency.yearly)),
        isNull,
      );
      expect(endedSeriesLookahead(null), isNull);
    });
  });
}
