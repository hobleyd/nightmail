import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_event_attendee.dart';
import 'package:nightmail/domain/entities/calendar_recurrence.dart';

void main() {
  group('CalendarEventModel.fromJson', () {
    test('parses a standard timed Graph API event', () {
      final json = <String, dynamic>{
        'id': 'event-123',
        'subject': 'Team Meeting',
        'isAllDay': false,
        'showAs': 'busy',
        'isOrganizer': true,
        'bodyPreview': 'Weekly sync',
        'location': {'displayName': 'Conference Room A'},
        'start': {'dateTime': '2026-06-10T09:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T10:00:00.0000000', 'timeZone': 'UTC'},
        'attendees': <dynamic>[],
        'recurrence': null,
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.id, 'event-123');
      expect(event.subject, 'Team Meeting');
      expect(event.isAllDay, isFalse);
      expect(event.isOrganizer, isTrue);
      expect(event.status, CalendarEventStatus.busy);
      expect(event.location, 'Conference Room A');
      expect(event.bodyPreview, 'Weekly sync');
      expect(event.start, DateTime.utc(2026, 6, 10, 9, 0, 0));
      expect(event.end, DateTime.utc(2026, 6, 10, 10, 0, 0));
      expect(event.timezone, 'UTC');
      expect(event.attendees, isEmpty);
      expect(event.recurrence, isNull);
    });

    test('parses an all-day event', () {
      final json = <String, dynamic>{
        'id': 'allday-1',
        'subject': 'Company Holiday',
        'isAllDay': true,
        'showAs': 'oof',
        'isOrganizer': false,
        'start': {'dateTime': '2026-07-04T00:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-07-05T00:00:00.0000000', 'timeZone': 'UTC'},
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.isAllDay, isTrue);
      expect(event.status, CalendarEventStatus.outOfOffice);
      expect(event.start, DateTime.utc(2026, 7, 4));
    });

    test('defaults subject to (No title) when missing', () {
      final json = <String, dynamic>{
        'id': 'no-title',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T09:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T10:00:00.0000000', 'timeZone': 'UTC'},
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.subject, '(No title)');
    });

    test('parses attendees with response statuses', () {
      final json = <String, dynamic>{
        'id': 'with-attendees',
        'subject': 'Review',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T14:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T15:00:00.0000000', 'timeZone': 'UTC'},
        'attendees': [
          {
            'emailAddress': {'address': 'alice@example.com', 'name': 'Alice'},
            'status': {'response': 'accepted'},
          },
          {
            'emailAddress': {'address': 'bob@example.com', 'name': 'Bob'},
            'status': {'response': 'tentativelyAccepted'},
          },
          {
            'emailAddress': {'address': 'carol@example.com'},
            'status': {'response': 'declined'},
          },
        ],
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.attendees.length, 3);
      expect(event.attendees[0].email, 'alice@example.com');
      expect(event.attendees[0].displayName, 'Alice');
      expect(event.attendees[0].responseStatus, AttendeeResponseStatus.accepted);
      expect(event.attendees[1].responseStatus, AttendeeResponseStatus.tentative);
      expect(event.attendees[2].responseStatus, AttendeeResponseStatus.declined);
    });

    test('marks a resource attendee as a room, and required/optional as people',
        () {
      final json = <String, dynamic>{
        'id': 'with-a-room',
        'subject': 'Review',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T14:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T15:00:00.0000000', 'timeZone': 'UTC'},
        'attendees': [
          {
            'emailAddress': {'address': 'alice@example.com'},
            'type': 'required',
            'status': {'response': 'accepted'},
          },
          {
            'emailAddress': {'address': 'bob@example.com'},
            'type': 'optional',
            'status': {'response': 'none'},
          },
          {
            'emailAddress': {'address': 'boardroom@example.com', 'name': 'Boardroom'},
            'type': 'resource',
            'status': {'response': 'accepted'},
          },
        ],
      };

      final event = CalendarEventModel.fromJson(json);

      // Without this the event form puts a booked room in the Guests field and
      // re-invites it as a person on save, losing the room booking.
      expect(event.attendees[0].isResource, isFalse);
      expect(event.attendees[1].isResource, isFalse);
      expect(event.attendees[2].isResource, isTrue);
    });

    test('a Teams meeting keeps its room as the location and its link apart',
        () {
      final json = <String, dynamic>{
        'id': 'teams-1',
        'subject': 'Review',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T14:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T15:00:00.0000000', 'timeZone': 'UTC'},
        'location': {'displayName': 'Boardroom'},
        'onlineMeeting': {
          'joinUrl': 'https://teams.microsoft.com/l/meetup-join/19%3ax/0',
        },
      };

      final event = CalendarEventModel.fromJson(json);

      // Both, not one or the other: a meeting is held in a room *and* streamed.
      expect(event.location, 'Boardroom');
      expect(event.onlineMeetingUrl,
          'https://teams.microsoft.com/l/meetup-join/19%3ax/0');
      expect(event.hasOnlineMeeting, isTrue);
    });

    test('a join URL sitting in the location — how every event saved under the '
        'old single-field convention looks — is recovered as the link', () {
      final json = <String, dynamic>{
        'id': 'legacy-1',
        'subject': 'Review',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T14:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T15:00:00.0000000', 'timeZone': 'UTC'},
        'location': {
          'displayName': 'https://teams.microsoft.com/l/meetup-join/19%3ax/0',
        },
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.onlineMeetingUrl,
          'https://teams.microsoft.com/l/meetup-join/19%3ax/0');
      // Not also echoed back as a place, or it would land in the form's
      // location box and be saved as one all over again.
      expect(event.location, isNull);
    });

    test('an event with no online meeting has no link', () {
      final json = <String, dynamic>{
        'id': 'plain-1',
        'subject': 'Review',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T14:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T15:00:00.0000000', 'timeZone': 'UTC'},
        'location': {'displayName': 'Level 3 kitchen'},
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.location, 'Level 3 kitchen');
      expect(event.onlineMeetingUrl, isNull);
      expect(event.hasOnlineMeeting, isFalse);
    });

    test('an attendee with no type is a person — Graph omits it on older events',
        () {
      final json = <String, dynamic>{
        'id': 'untyped',
        'subject': 'Review',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T14:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T15:00:00.0000000', 'timeZone': 'UTC'},
        'attendees': [
          {'emailAddress': {'address': 'alice@example.com'}},
        ],
      };

      expect(CalendarEventModel.fromJson(json).attendees.single.isResource,
          isFalse);
    });

    test('filters out attendees with empty email', () {
      final json = <String, dynamic>{
        'id': 'empty-email',
        'subject': 'Test',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T09:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T10:00:00.0000000', 'timeZone': 'UTC'},
        'attendees': <Map<String, dynamic>>[
          <String, dynamic>{
            'emailAddress': <String, dynamic>{},
            'status': <String, dynamic>{'response': 'none'},
          },
          <String, dynamic>{
            'emailAddress': <String, dynamic>{'address': 'valid@example.com'},
            'status': <String, dynamic>{'response': 'accepted'},
          },
        ],
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.attendees.length, 1);
      expect(event.attendees[0].email, 'valid@example.com');
    });

    test('parses weekly recurrence', () {
      final json = <String, dynamic>{
        'id': 'recurring',
        'subject': 'Weekly Standup',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T09:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T09:30:00.0000000', 'timeZone': 'UTC'},
        'recurrence': {
          'pattern': {
            'type': 'weekly',
            'interval': 1,
            'daysOfWeek': ['monday', 'wednesday', 'friday'],
          },
          'range': {'type': 'noEnd', 'startDate': '2026-06-10'},
        },
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.recurrence, isNotNull);
      expect(event.recurrence!.frequency, RecurrenceFrequency.weekly);
      expect(event.recurrence!.interval, 1);
      expect(event.recurrence!.daysOfWeek, containsAll([1, 3, 5]));
      expect(event.recurrence!.endDate, isNull);
      expect(event.recurrence!.count, isNull);
    });

    test('parses daily recurrence with end date', () {
      final json = <String, dynamic>{
        'id': 'daily-rec',
        'subject': 'Daily Check',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T08:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T08:15:00.0000000', 'timeZone': 'UTC'},
        'recurrence': {
          'pattern': {'type': 'daily', 'interval': 2},
          'range': {
            'type': 'endDate',
            'startDate': '2026-06-10',
            'endDate': '2026-12-31',
          },
        },
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.recurrence!.frequency, RecurrenceFrequency.daily);
      expect(event.recurrence!.interval, 2);
      expect(event.recurrence!.endDate, DateTime(2026, 12, 31));
    });

    test('parses numbered recurrence', () {
      final json = <String, dynamic>{
        'id': 'numbered-rec',
        'subject': 'Sprint Review',
        'isAllDay': false,
        'start': {'dateTime': '2026-06-10T14:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T15:00:00.0000000', 'timeZone': 'UTC'},
        'recurrence': {
          'pattern': {'type': 'absoluteMonthly', 'interval': 1},
          'range': {
            'type': 'numbered',
            'startDate': '2026-06-10',
            'numberOfOccurrences': 10,
          },
        },
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.recurrence!.frequency, RecurrenceFrequency.monthly);
      expect(event.recurrence!.count, 10);
    });

    test('maps showAs values to CalendarEventStatus correctly', () {
      final cases = {
        'free': CalendarEventStatus.free,
        'tentative': CalendarEventStatus.tentative,
        'busy': CalendarEventStatus.busy,
        'oof': CalendarEventStatus.outOfOffice,
        'workingElsewhere': CalendarEventStatus.workingElsewhere,
        null: CalendarEventStatus.busy,
        'unknown': CalendarEventStatus.busy,
      };

      for (final entry in cases.entries) {
        final json = <String, dynamic>{
          'id': 'status-test',
          'subject': 'Test',
          'isAllDay': false,
          'showAs': entry.key,
          'start': {'dateTime': '2026-06-10T09:00:00.0000000', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-06-10T10:00:00.0000000', 'timeZone': 'UTC'},
        };
        final event = CalendarEventModel.fromJson(json);
        expect(event.status, entry.value, reason: 'showAs=${entry.key}');
      }
    });

    test('maps isOrganizer + responseStatus to MeetingParticipation', () {
      // isOrganizer wins regardless of response.
      MeetingParticipation participationFor({
        required bool isOrganizer,
        String? response,
      }) {
        final json = <String, dynamic>{
          'id': 'participation-test',
          'subject': 'Test',
          'isAllDay': false,
          'isOrganizer': isOrganizer,
          if (response != null) 'responseStatus': {'response': response},
          'start': {'dateTime': '2026-06-10T09:00:00.0000000', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-06-10T10:00:00.0000000', 'timeZone': 'UTC'},
        };
        return CalendarEventModel.fromJson(json).participation;
      }

      expect(participationFor(isOrganizer: true, response: 'accepted'),
          MeetingParticipation.organizer);
      expect(participationFor(isOrganizer: false, response: 'organizer'),
          MeetingParticipation.organizer);
      expect(participationFor(isOrganizer: false, response: 'accepted'),
          MeetingParticipation.accepted);
      expect(participationFor(isOrganizer: false, response: 'tentativelyAccepted'),
          MeetingParticipation.tentative);
      expect(participationFor(isOrganizer: false, response: 'notResponded'),
          MeetingParticipation.needsAction);
      expect(participationFor(isOrganizer: false, response: 'declined'),
          MeetingParticipation.declined);
      expect(participationFor(isOrganizer: false, response: 'none'),
          MeetingParticipation.none);
      expect(participationFor(isOrganizer: false, response: null),
          MeetingParticipation.none);
    });

    test('parses location as null when displayName is empty', () {
      final json = <String, dynamic>{
        'id': 'no-location',
        'subject': 'Test',
        'isAllDay': false,
        'location': {'displayName': ''},
        'start': {'dateTime': '2026-06-10T09:00:00.0000000', 'timeZone': 'UTC'},
        'end': {'dateTime': '2026-06-10T10:00:00.0000000', 'timeZone': 'UTC'},
      };

      final event = CalendarEventModel.fromJson(json);

      expect(event.location, isNull);
    });

    group('datetime parsing', () {
      test('handles 7 decimal places (Graph API ticks format)', () {
        final json = <String, dynamic>{
          'id': 'dt-test',
          'subject': 'Test',
          'isAllDay': false,
          'start': {'dateTime': '2026-06-10T09:30:00.0000000', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-06-10T10:45:00.0000000', 'timeZone': 'UTC'},
        };

        final event = CalendarEventModel.fromJson(json);

        expect(event.start, DateTime.utc(2026, 6, 10, 9, 30, 0));
        expect(event.end, DateTime.utc(2026, 6, 10, 10, 45, 0));
      });

      test('handles UTC datetime without Z suffix', () {
        final json = <String, dynamic>{
          'id': 'dt-no-z',
          'subject': 'Test',
          'isAllDay': false,
          'start': {'dateTime': '2026-06-10T09:00:00', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-06-10T10:00:00', 'timeZone': 'UTC'},
        };

        final event = CalendarEventModel.fromJson(json);

        expect(event.start, DateTime.utc(2026, 6, 10, 9, 0, 0));
      });

      test('appends Z when timeZone is UTC and datetime lacks it', () {
        final json = <String, dynamic>{
          'id': 'dt-utc-no-z',
          'subject': 'Test',
          'isAllDay': false,
          'start': {'dateTime': '2026-01-15T13:00:00.0000000', 'timeZone': 'UTC'},
          'end': {'dateTime': '2026-01-15T14:00:00.0000000', 'timeZone': 'UTC'},
        };

        final event = CalendarEventModel.fromJson(json);

        expect(event.start.isUtc, isTrue);
        expect(event.start.hour, 13);
      });
    });
  });
}
