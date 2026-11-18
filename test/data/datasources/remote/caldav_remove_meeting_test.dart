import 'package:caldav/caldav.dart' as caldav;
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/datasources/remote/caldav_calendar_datasource_impl.dart';

void main() {
  caldav.CalendarEvent event({String? rrule, String? recurrenceId}) =>
      caldav.CalendarEvent(
        uid: 'meeting-1@example.com',
        calendarId: 'cal',
        start: DateTime.utc(2026, 11, 18, 4),
        summary: 'Weekly 1:1',
        rrule: rrule,
        recurrenceId: recurrenceId,
      );

  group('CalDavCalendarDatasourceImpl.removesOnlyCancelledMeeting', () {
    test('never deletes a recurring series for one cancelled occurrence', () {
      // Regression: the resource holds the whole series, so deleting it for a
      // RECURRENCE-ID cancellation took every other occurrence with it.
      expect(
        CalDavCalendarDatasourceImpl.removesOnlyCancelledMeeting(
            event(rrule: 'FREQ=WEEKLY;BYDAY=WE'),
            cancelsOccurrence: true),
        isFalse,
      );
    });

    test('never deletes a resource holding an overridden occurrence', () {
      expect(
        CalDavCalendarDatasourceImpl.removesOnlyCancelledMeeting(
            event(recurrenceId: '20261118T040000Z'), cancelsOccurrence: true),
        isFalse,
      );
    });

    test('deletes a series the cancellation cancels as a whole', () {
      expect(
        CalDavCalendarDatasourceImpl.removesOnlyCancelledMeeting(
            event(rrule: 'FREQ=WEEKLY;BYDAY=WE'),
            cancelsOccurrence: false),
        isTrue,
      );
    });

    test('deletes a single meeting', () {
      expect(
        CalDavCalendarDatasourceImpl.removesOnlyCancelledMeeting(event(),
            cancelsOccurrence: false),
        isTrue,
      );
    });
  });
}
