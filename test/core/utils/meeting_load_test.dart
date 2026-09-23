import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/meeting_load.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';

final _day = DateTime(2026, 9, 23); // a Wednesday

CalendarEvent _meeting(
  int startHour,
  int endHour, {
  int startMinute = 0,
  int endMinute = 0,
  bool isAllDay = false,
  CalendarEventStatus status = CalendarEventStatus.busy,
  MeetingParticipation participation = MeetingParticipation.accepted,
  DateTime? day,
}) {
  final d = day ?? _day;
  return CalendarEvent(
    id: '$startHour-$endHour-$startMinute-$endMinute-$status-$participation',
    subject: 'Meeting',
    start: DateTime(d.year, d.month, d.day, startHour, startMinute),
    end: DateTime(d.year, d.month, d.day, endHour, endMinute),
    isAllDay: isAllDay,
    status: status,
    participation: participation,
  );
}

void main() {
  group('workingDayMeetingLoad', () {
    test('an empty day is 0', () {
      expect(workingDayMeetingLoad(const [], _day), 0);
    });

    test('a one-hour meeting inside 9–5 is an eighth of the day', () {
      expect(workingDayMeetingLoad([_meeting(10, 11)], _day), closeTo(0.125, 1e-9));
    });

    test('half-hour meetings are counted in minutes, not hours', () {
      expect(
        workingDayMeetingLoad([_meeting(10, 10, endMinute: 30)], _day),
        closeTo(30 / 480, 1e-9),
      );
    });

    test('a meeting straddling 9am counts only the part after it', () {
      expect(workingDayMeetingLoad([_meeting(8, 10)], _day), closeTo(0.125, 1e-9));
    });

    test('a meeting straddling 5pm counts only the part before it', () {
      expect(workingDayMeetingLoad([_meeting(16, 19)], _day), closeTo(0.125, 1e-9));
    });

    test('a meeting entirely outside the window counts for nothing', () {
      expect(workingDayMeetingLoad([_meeting(18, 20), _meeting(6, 8)], _day), 0);
    });

    test('overlapping meetings are counted once', () {
      // 10–12 and 11–13 together cover 10–13: three hours, not four.
      expect(
        workingDayMeetingLoad([_meeting(10, 12), _meeting(11, 13)], _day),
        closeTo(3 / 8, 1e-9),
      );
    });

    test('a meeting nested inside another adds nothing', () {
      expect(
        workingDayMeetingLoad([_meeting(9, 13), _meeting(10, 11)], _day),
        closeTo(0.5, 1e-9),
      );
    });

    test('back-to-back meetings sum without a gap', () {
      expect(
        workingDayMeetingLoad([_meeting(9, 10), _meeting(10, 11)], _day),
        closeTo(0.25, 1e-9),
      );
    });

    test('a day booked solid is exactly 1, never more', () {
      expect(
        workingDayMeetingLoad([_meeting(7, 12), _meeting(12, 20), _meeting(9, 17)], _day),
        1.0,
      );
    });

    test('all-day entries are not meetings', () {
      expect(workingDayMeetingLoad([_meeting(0, 0, isAllDay: true)], _day), 0);
    });

    test('free and working-elsewhere entries do not commit time', () {
      expect(
        workingDayMeetingLoad([
          _meeting(9, 17, status: CalendarEventStatus.free),
          _meeting(9, 17, status: CalendarEventStatus.workingElsewhere),
        ], _day),
        0,
      );
    });

    test('a declined meeting is off the plate', () {
      expect(
        workingDayMeetingLoad(
            [_meeting(9, 17, participation: MeetingParticipation.declined)], _day),
        0,
      );
    });

    test('tentative and unanswered meetings still count', () {
      expect(
        workingDayMeetingLoad([
          _meeting(9, 10, participation: MeetingParticipation.tentative),
          _meeting(10, 11, participation: MeetingParticipation.needsAction),
        ], _day),
        closeTo(0.25, 1e-9),
      );
    });

    test('meetings on other days are ignored', () {
      final tomorrow = _day.add(const Duration(days: 1));
      expect(workingDayMeetingLoad([_meeting(9, 17, day: tomorrow)], _day), 0);
    });

    test('a UTC instant is placed on its local day', () {
      final utc = _meeting(10, 11);
      final asUtc = CalendarEvent(
        id: 'utc',
        subject: 'Meeting',
        start: utc.start.toUtc(),
        end: utc.end.toUtc(),
        isAllDay: false,
      );
      expect(workingDayMeetingLoad([asUtc], _day), closeTo(0.125, 1e-9));
    });

    test('the window is configurable', () {
      expect(
        workingDayMeetingLoad([_meeting(8, 9)], _day, startHour: 8, endHour: 12),
        closeTo(0.25, 1e-9),
      );
    });
  });
}
