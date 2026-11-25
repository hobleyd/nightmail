import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/ended_meeting_series.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_recurrence.dart';

/// The 25 Nov 2026 incident: a weekday stand-up cut short at Mon 23 Nov by
/// moving its end date, mailed as "Updated invitation" with an ICS whose UNTIL
/// (1 Nov) belongs to the first of three split segments.
const _uid = 'gacrfrmvm41s2kp486g69kiehb@google.com';
final _now = DateTime.utc(2026, 11, 25, 7);

CalendarEvent _occurrence(DateTime start, {String iCalUid = _uid}) =>
    CalendarEvent(
      id: start.toIso8601String(),
      subject: 'OneVal Release 2 (CBV) - Stand-Up',
      start: start,
      end: start.add(const Duration(minutes: 15)),
      isAllDay: false,
      iCalUid: iCalUid,
    );

DateTime? _ended({
  List<CalendarEvent> upcoming = const [],
  List<CalendarEvent> recent = const [],
  String? uid = _uid,
}) =>
    lastOccurrenceOfEndedSeries(
      inviteUid: uid,
      upcoming: upcoming,
      recent: recent,
      now: _now,
    );

void main() {
  group('lastOccurrenceOfEndedSeries', () {
    test('a series with recent occurrences and none ahead has ended', () {
      final last = DateTime.utc(2026, 11, 23);
      expect(
        _ended(recent: [
          _occurrence(DateTime.utc(2026, 11, 19)),
          _occurrence(last),
          _occurrence(DateTime.utc(2026, 11, 20)),
        ]),
        last,
      );
    });

    test('occurrences of a split segment count as the same meeting', () {
      // Google files the segments after a "this and following" edit under
      // `<uid>_R<split start>`; the instances add their own start on top.
      final last = DateTime.utc(2026, 11, 23);
      expect(
        _ended(recent: [
          _occurrence(last,
              iCalUid: 'gacrfrmvm41s2kp486g69kiehb_R20261105T000000'
                  '@google.com'),
        ]),
        last,
      );
    });

    test('an occurrence still to come means the series has not ended', () {
      expect(
        _ended(
          upcoming: [_occurrence(DateTime.utc(2026, 11, 26))],
          recent: [_occurrence(DateTime.utc(2026, 11, 24))],
        ),
        isNull,
      );
    });

    test('an occurrence in progress means the series has not ended', () {
      final inProgress = _occurrence(_now.subtract(const Duration(minutes: 5)));
      expect(_ended(upcoming: [inProgress], recent: [inProgress]), isNull);
    });

    test('nothing on the calendar either side settles nothing', () {
      // A forwarded or hidden invitation is just as absent as an ended one.
      expect(_ended(), isNull);
    });

    test('other meetings are not evidence', () {
      expect(
        _ended(recent: [
          _occurrence(DateTime.utc(2026, 11, 23), iCalUid: 'other@google.com'),
        ]),
        isNull,
      );
    });

    test('an invitation with no UID settles nothing', () {
      expect(
        _ended(uid: null, recent: [_occurrence(DateTime.utc(2026, 11, 23))]),
        isNull,
      );
    });
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
