import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/google_calendar_datasource_impl.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/infrastructure/http/google_calendar_http_client.dart';

import 'google_calendar_status_test.mocks.dart';

final _tStart = DateTime.utc(2026, 7, 27);
final _tEnd = DateTime.utc(2026, 7, 28);

/// Builds a minimal timed Google `events.list` item. `attendees` and
/// `organizer` mirror the shapes the real API returns.
Map<String, dynamic> _event({
  required String id,
  Map<String, dynamic>? organizer,
  List<Map<String, dynamic>>? attendees,
  String status = 'confirmed',
  String? transparency,
  String? eventType,
  String? iCalUID,
}) =>
    <String, dynamic>{
      'id': id,
      'summary': id,
      'status': status,
      'start': {'dateTime': '2026-07-27T09:00:00+10:00', 'timeZone': 'Australia/Brisbane'},
      'end': {'dateTime': '2026-07-27T09:30:00+10:00', 'timeZone': 'Australia/Brisbane'},
      'organizer': ?organizer,
      'attendees': ?attendees,
      'transparency': ?transparency,
      'eventType': ?eventType,
      'iCalUID': ?iCalUID,
    };

/// A `self` attendee entry with the given RSVP.
Map<String, dynamic> _selfRsvp(String responseStatus) => {
      'email': 'david.hobley@example.com',
      'responseStatus': responseStatus,
      'self': true,
    };

@GenerateMocks([Dio, GoogleCalendarHttpClient])
void main() {
  late MockDio mockDio;
  late GoogleCalendarDatasourceImpl datasource;

  /// Stubs the two GETs `getCalendarEvents` makes: the reminder-defaults
  /// lookup and the events list. Returns whichever `items` are passed in.
  void stubEvents(List<Map<String, dynamic>> items) {
    when(mockDio.get<Map<String, dynamic>>(
      any,
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenAnswer((inv) async {
      final path = inv.positionalArguments.first as String;
      final data = path == '/users/me/calendarList/primary'
          ? <String, dynamic>{'defaultReminders': <dynamic>[]}
          : <String, dynamic>{'items': items};
      return Response(
        data: data,
        statusCode: 200,
        requestOptions: RequestOptions(path: path),
      );
    });
  }

  setUp(() {
    mockDio = MockDio();
    final client = MockGoogleCalendarHttpClient();
    when(client.dio).thenReturn(mockDio);
    datasource = GoogleCalendarDatasourceImpl(client: client);
  });

  group('GoogleCalendarDatasourceImpl participation → colour', () {
    Future<CalendarEvent> parse(Map<String, dynamic> event) async {
      stubEvents([event]);
      final events = await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );
      return events.single;
    }

    Future<MeetingParticipation> participationOf(
            Map<String, dynamic> event) async =>
        (await parse(event)).participation;

    test(
        'organizer with no self-attendee entry is organizer (green), even when '
        'Google omits you from the attendee list', () async {
      // Google inconsistently leaves the organizer out of `attendees` for some
      // self-created events. The `organizer.self` flag is the reliable signal.
      final event = _event(
        id: 'organized-no-self-attendee',
        organizer: {'email': 'david.hobley@example.com', 'self': true},
        attendees: [
          {'email': 'guest@example.com', 'responseStatus': 'needsAction'},
        ],
      );

      expect(await participationOf(event), MeetingParticipation.organizer);
    });

    test('organizer flag wins even if you are also an accepted attendee',
        () async {
      final event = _event(
        id: 'organized-with-self-attendee',
        organizer: {'email': 'david.hobley@example.com', 'self': true},
        attendees: [
          {
            'email': 'david.hobley@example.com',
            'organizer': true,
            'responseStatus': 'accepted',
            'self': true,
          },
          {'email': 'guest@example.com', 'responseStatus': 'needsAction'},
        ],
      );

      expect(await participationOf(event), MeetingParticipation.organizer);
    });

    test('someone else\'s invite you accepted is accepted (blue)', () async {
      final event = _event(
        id: 'accepted-invite',
        organizer: {'email': 'someone.else@example.com'},
        attendees: [
          {
            'email': 'david.hobley@example.com',
            'responseStatus': 'accepted',
            'self': true,
          },
        ],
      );

      expect(await participationOf(event), MeetingParticipation.accepted);
    });

    test('tentatively accepted invite is tentative (yellow)', () async {
      final event = _event(
        id: 'tentative-invite',
        organizer: {'email': 'someone.else@example.com'},
        attendees: [
          {
            'email': 'david.hobley@example.com',
            'responseStatus': 'tentative',
            'self': true,
          },
        ],
      );

      expect(await participationOf(event), MeetingParticipation.tentative);
    });

    test('unanswered invite is needsAction (also yellow)', () async {
      final event = _event(
        id: 'unanswered-invite',
        organizer: {'email': 'someone.else@example.com'},
        attendees: [
          {
            'email': 'david.hobley@example.com',
            'responseStatus': 'needsAction',
            'self': true,
          },
        ],
      );

      expect(await participationOf(event), MeetingParticipation.needsAction);
    });

    test('event with no self-attendee and no organiser flag is none', () async {
      final event = _event(
        id: 'other-owned-no-self',
        organizer: {'email': 'someone.else@example.com'},
        attendees: [
          {'email': 'guest@example.com', 'responseStatus': 'accepted'},
        ],
      );

      expect(await participationOf(event), MeetingParticipation.none);
    });

    test(
        'free/busy status stays independent of participation (conflict '
        'detection relies on it)', () async {
      // A meeting you organise but Google omits you from → status falls back to
      // the event-level "confirmed" → busy. This must NOT be recoloured to free
      // by the participation change, or conflict detection would ignore it.
      final event = _event(
        id: 'organized-no-self-attendee',
        organizer: {'email': 'david.hobley@example.com', 'self': true},
        attendees: [
          {'email': 'guest@example.com', 'responseStatus': 'needsAction'},
        ],
      );

      final parsed = await parse(event);
      expect(parsed.participation, MeetingParticipation.organizer);
      expect(parsed.status, CalendarEventStatus.busy);
    });
  });

  group('GoogleCalendarDatasourceImpl free/busy → conflict detection', () {
    Future<CalendarEventStatus> statusOf(Map<String, dynamic> event) async {
      stubEvents([event]);
      final events = await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );
      return events.single.status;
    }

    test('an invite you accepted is BUSY, so a new invite clashes with it',
        () async {
      // The regression this group exists for: Google's RSVP was fed straight
      // into the free/busy mapping, so `accepted` became
      // CalendarEventStatus.free and conflict detection ignored every meeting
      // the user had agreed to attend.
      final event = _event(
        id: 'accepted-invite',
        organizer: {'email': 'someone.else@example.com'},
        attendees: [_selfRsvp('accepted')],
      );

      expect(await statusOf(event), CalendarEventStatus.busy);
    });

    test('a meeting you organise and are listed on is busy', () async {
      final event = _event(
        id: 'organized-with-self-attendee',
        organizer: {'email': 'david.hobley@example.com', 'self': true},
        attendees: [
          {..._selfRsvp('accepted'), 'organizer': true},
          {'email': 'guest@example.com', 'responseStatus': 'needsAction'},
        ],
      );

      expect(await statusOf(event), CalendarEventStatus.busy);
    });

    test('an unanswered or tentative invite holds the slot', () async {
      expect(
        await statusOf(_event(
          id: 'unanswered',
          attendees: [_selfRsvp('needsAction')],
        )),
        CalendarEventStatus.tentative,
      );
      expect(
        await statusOf(_event(
          id: 'tentative',
          attendees: [_selfRsvp('tentative')],
        )),
        CalendarEventStatus.tentative,
      );
    });

    test('an invite you declined frees the slot', () async {
      final event = _event(
        id: 'declined-invite',
        attendees: [_selfRsvp('declined')],
      );

      expect(await statusOf(event), CalendarEventStatus.free);
    });

    test('transparency is the only signal that means free', () async {
      // Google's Busy/Free toggle. It outranks the RSVP: an accepted meeting
      // the user marked "Free" does not clash.
      expect(
        await statusOf(_event(
          id: 'accepted-but-marked-free',
          attendees: [_selfRsvp('accepted')],
          transparency: 'transparent',
        )),
        CalendarEventStatus.free,
      );
      expect(
        await statusOf(_event(
          id: 'explicitly-opaque',
          attendees: [_selfRsvp('accepted')],
          transparency: 'opaque',
        )),
        CalendarEventStatus.busy,
      );
    });

    test('a cancelled event no longer holds the slot', () async {
      final event = _event(
        id: 'called-off',
        status: 'cancelled',
        attendees: [_selfRsvp('accepted')],
      );

      expect(await statusOf(event), CalendarEventStatus.free);
    });

    test('out-of-office blocks the slot; a working location does not',
        () async {
      expect(
        await statusOf(_event(id: 'on-leave', eventType: 'outOfOffice')),
        CalendarEventStatus.outOfOffice,
      );
      // Returned by events.list for anyone who sets a working location. Mapping
      // it to busy would warn of a conflict on every invite of the day.
      final wfh =
          await statusOf(_event(id: 'from-home', eventType: 'workingLocation'));
      expect(wfh, CalendarEventStatus.workingElsewhere);
    });

    test('iCalUID is carried through so an invite can identify its own copy',
        () async {
      stubEvents([
        _event(id: 'auto-added', iCalUID: 'abc123uid@google.com'),
      ]);

      final events = await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      expect(events.single.iCalUid, 'abc123uid@google.com');
    });
  });
}
