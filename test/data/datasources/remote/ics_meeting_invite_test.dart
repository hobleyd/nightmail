import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/ics_meeting_invite.dart';
import 'package:nightmail/domain/entities/calendar_recurrence.dart';

String _request(String rruleLine) => '''
BEGIN:VCALENDAR
METHOD:REQUEST
BEGIN:VEVENT
$rruleLine
UID:evt-1
DTSTART:20261117T000000Z
DTEND:20261117T003000Z
END:VEVENT
END:VCALENDAR''';

void main() {
  group('buildMeetingInviteFromIcs recurrence', () {
    test("a series invitation carries the VEVENT's rule", () {
      final invite = buildMeetingInviteFromIcs(
          _request('RRULE:FREQ=WEEKLY;INTERVAL=2;BYDAY=TU;COUNT=10'));

      expect(invite.isRecurring, isTrue);
      expect(
        invite.recurrence,
        const CalendarRecurrence(
          frequency: RecurrenceFrequency.weekly,
          interval: 2,
          daysOfWeek: [2],
          count: 10,
        ),
      );
    });

    test('a rule this app cannot model still marks the invite recurring', () {
      final invite = buildMeetingInviteFromIcs(_request('RRULE:FREQ=HOURLY'));

      expect(invite.isRecurring, isTrue);
      expect(invite.recurrence, isNull);
    });

    test('a one-off invitation is not recurring', () {
      final invite = buildMeetingInviteFromIcs(_request(''));

      expect(invite.isRecurring, isFalse);
      expect(invite.recurrence, isNull);
    });
  });
}
