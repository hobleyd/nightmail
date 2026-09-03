import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/google_calendar_datasource_impl.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/http/google_calendar_http_client.dart';

import 'google_calendar_rooms_test.mocks.dart';

const _directoryUrl =
    'https://admin.googleapis.com/admin/directory/v1/customer/my_customer'
    '/resources/calendars';
const _calendarListPath = '/users/me/calendarList';

/// Google's resource-calendar address shape — the only room signal available
/// without the Admin SDK.
const _roomCalendarId = 'c_188abc@resource.calendar.google.com';

DioException _dioError(int statusCode, String path) => DioException(
      requestOptions: RequestOptions(path: path),
      response: Response(
        statusCode: statusCode,
        requestOptions: RequestOptions(path: path),
      ),
    );

@GenerateMocks([Dio, GoogleCalendarHttpClient])
void main() {
  late MockDio mockDio;
  late GoogleCalendarDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    final client = MockGoogleCalendarHttpClient();
    when(client.dio).thenReturn(mockDio);
    datasource = GoogleCalendarDatasourceImpl(
      client: client,
      accountEmail: 'me@example.com',
    );
  });

  Response<Map<String, dynamic>> ok(Map<String, dynamic> data, String path) =>
      Response(
        data: data,
        statusCode: 200,
        requestOptions: RequestOptions(path: path),
      );

  void stubDirectory(Map<String, dynamic> data) {
    when(mockDio.get<Map<String, dynamic>>(
      _directoryUrl,
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenAnswer((_) async => ok(data, _directoryUrl));
  }

  void stubDirectoryDenied(int statusCode) {
    when(mockDio.get<Map<String, dynamic>>(
      _directoryUrl,
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenThrow(_dioError(statusCode, _directoryUrl));
  }

  void stubCalendarList(List<Map<String, dynamic>> items) {
    when(mockDio.get<Map<String, dynamic>>(
      _calendarListPath,
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenAnswer((_) async => ok({'items': items}, _calendarListPath));
  }

  group('getMeetingRooms via the Admin SDK', () {
    test('maps resourceName, capacity, building and floor', () async {
      stubDirectory({
        'items': [
          {
            'resourceId': '1',
            'resourceName': 'Boardroom',
            'generatedResourceName': 'SYD-3-Boardroom (14)',
            'resourceEmail': _roomCalendarId,
            'capacity': 14,
            'buildingId': 'SYD',
            'floorName': 'M',
          },
        ],
      });

      final rooms = await datasource.getMeetingRooms();

      expect(rooms, hasLength(1));
      expect(rooms.single.email, _roomCalendarId);
      // The plain name, not generatedResourceName — building and floor are shown
      // as the dropdown's own subtitle rather than baked into the title.
      expect(rooms.single.displayName, 'Boardroom');
      expect(rooms.single.capacity, 14);
      expect(rooms.single.floorLabel, 'M');
      expect(rooms.single.detailLine, 'SYD · Level M · 14 seats');
    });

    test('falls back to generatedResourceName when resourceName is blank',
        () async {
      stubDirectory({
        'items': [
          {
            'resourceName': '   ',
            'generatedResourceName': 'SYD-3-Boardroom',
            'resourceEmail': _roomCalendarId,
          },
        ],
      });

      final rooms = await datasource.getMeetingRooms();

      expect(rooms.single.displayName, 'SYD-3-Boardroom');
    });

    test('follows nextPageToken', () async {
      when(mockDio.get<Map<String, dynamic>>(
        _directoryUrl,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((inv) async {
        final params =
            inv.namedArguments[const Symbol('queryParameters')] as Map;
        if (params['pageToken'] == 'page2') {
          return ok({
            'items': [
              {'resourceName': 'B', 'resourceEmail': 'b@resource.calendar.google.com'},
            ],
          }, _directoryUrl);
        }
        return ok({
          'items': [
            {'resourceName': 'A', 'resourceEmail': 'a@resource.calendar.google.com'},
          ],
          'nextPageToken': 'page2',
        }, _directoryUrl);
      });

      final rooms = await datasource.getMeetingRooms();

      expect(rooms.map((r) => r.displayName), ['A', 'B']);
    });
  });

  group('getMeetingRooms fallback to subscribed resource calendars', () {
    test('a 403 — a non-admin user, or a token without the Admin SDK scope — '
        'falls back to calendarList', () async {
      stubDirectoryDenied(403);
      stubCalendarList([
        {'id': 'someone@contoso.com', 'summary': 'A colleague'},
        {'id': _roomCalendarId, 'summary': 'Level 3 Boardroom'},
      ]);

      final rooms = await datasource.getMeetingRooms();

      // Only the resource calendar; a shared personal calendar is not a room.
      expect(rooms, hasLength(1));
      expect(rooms.single.email, _roomCalendarId);
      expect(rooms.single.displayName, 'Level 3 Boardroom');
    });

    test('prefers the user\'s own summaryOverride for a room they renamed',
        () async {
      stubDirectoryDenied(403);
      stubCalendarList([
        {
          'id': _roomCalendarId,
          'summary': 'SYD-3-BR-14',
          'summaryOverride': 'The good boardroom',
        },
      ]);

      final rooms = await datasource.getMeetingRooms();

      expect(rooms.single.displayName, 'The good boardroom');
    });

    test('returns empty rather than throwing when both sources fail', () async {
      stubDirectoryDenied(403);
      when(mockDio.get<Map<String, dynamic>>(
        _calendarListPath,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(_dioError(500, _calendarListPath));

      await expectLater(datasource.getMeetingRooms(), completion(isEmpty));
    });

    test('no subscribed room calendars is an ordinary empty result', () async {
      stubDirectoryDenied(403);
      stubCalendarList([
        {'id': 'someone@contoso.com', 'summary': 'A colleague'},
      ]);

      expect(await datasource.getMeetingRooms(), isEmpty);
    });
  });

  group('parsing a room back off an event', () {
    Future<List<dynamic>> attendeesOf(
        List<Map<String, dynamic>> rawAttendees) async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((inv) async {
        final path = inv.positionalArguments.first as String;
        if (path.contains('calendarList')) {
          return ok({'defaultReminders': <dynamic>[]}, path);
        }
        return ok({
          'items': [
            {
              'id': 'event-1',
              'summary': 'Review',
              'start': {'dateTime': '2026-08-10T09:00:00Z'},
              'end': {'dateTime': '2026-08-10T10:00:00Z'},
              'attendees': rawAttendees,
            },
          ],
        }, path);
      });

      final events = await datasource.getCalendarEvents(
        startDateTime: DateTime.utc(2026, 8, 10),
        endDateTime: DateTime.utc(2026, 8, 11),
      );
      return events.single.attendees;
    }

    test('resource:true marks a room; a person is left unmarked', () async {
      final attendees = await attendeesOf([
        {'email': 'sam@contoso.com', 'responseStatus': 'accepted'},
        {'email': _roomCalendarId, 'resource': true, 'responseStatus': 'accepted'},
      ]);

      expect(attendees[0].isResource, isFalse);
      expect(attendees[1].isResource, isTrue);
    });

    test('a resource-calendar address is treated as a room even when another '
        'client omitted the resource flag', () async {
      final attendees = await attendeesOf([
        {'email': _roomCalendarId, 'responseStatus': 'accepted'},
      ]);

      expect(attendees.single.isResource, isTrue);
    });
  });

  group('a Meet link is parsed apart from the location', () {
    const meetUrl = 'https://meet.google.com/abc-defg-hij';

    Future<CalendarEvent> parse(Map<String, dynamic> eventJson) async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((inv) async {
        final p = inv.positionalArguments.first as String;
        if (p.contains('calendarList')) {
          return ok({'defaultReminders': <dynamic>[]}, p);
        }
        return ok({
          'items': [
            {
              'id': 'e1',
              'summary': 'Design review',
              'start': {'dateTime': '2026-08-10T09:00:00Z'},
              'end': {'dateTime': '2026-08-10T10:00:00Z'},
              ...eventJson,
            },
          ],
        }, p);
      });

      final events = await datasource.getCalendarEvents(
        startDateTime: DateTime.utc(2026, 8, 10),
        endDateTime: DateTime.utc(2026, 8, 11),
      );
      return events.single;
    }

    test('conferenceData becomes the link; the location stays the place',
        () async {
      final event = await parse({
        'location': 'Level 3 kitchen',
        'conferenceData': {
          'entryPoints': [
            {'entryPointType': 'video', 'uri': meetUrl},
          ],
        },
      });

      expect(event.location, 'Level 3 kitchen');
      expect(event.onlineMeetingUrl, meetUrl);
    });

    test('a link left in the location by the old convention is recovered',
        () async {
      final event = await parse({'location': meetUrl});

      expect(event.onlineMeetingUrl, meetUrl);
      expect(event.location, isNull);
    });

    test('a link only in the description is still found', () async {
      final event = await parse({
        'description': 'Join at $meetUrl',
      });

      expect(event.onlineMeetingUrl, meetUrl);
      expect(event.location, isNull);
    });

    test('an ordinary meeting has no link', () async {
      final event = await parse({'location': 'Level 3 kitchen'});

      expect(event.location, 'Level 3 kitchen');
      expect(event.hasOnlineMeeting, isFalse);
    });
  });

  group('createCalendarEvent with rooms', () {
    late Map<String, dynamic> body;

    Future<void> create({
      List<String> roomEmails = const [],
      List<String> attendeeEmails = const [],
      String? location,
    }) async {
      when(mockDio.post<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => ok({
            'id': 'new-event',
            'summary': 'Planning',
            'start': {'dateTime': '2026-08-10T09:00:00Z'},
            'end': {'dateTime': '2026-08-10T10:00:00Z'},
          }, '/calendars/primary/events'));

      await datasource.createCalendarEvent(
        params: CreateCalendarEventParams(
          subject: 'Planning',
          start: DateTime.utc(2026, 8, 10, 9),
          end: DateTime.utc(2026, 8, 10, 10),
          isAllDay: false,
          timezone: 'Australia/Brisbane',
          location: location,
          attendeeEmails: attendeeEmails,
          roomEmails: roomEmails,
        ),
      );

      body = verify(mockDio.post<Map<String, dynamic>>(
        any,
        data: captureAnyNamed('data'),
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured.single as Map<String, dynamic>;
    }

    test('marks a room attendee resource:true and leaves people unmarked',
        () async {
      await create(
        roomEmails: [_roomCalendarId],
        attendeeEmails: ['sam@contoso.com'],
      );

      final attendees =
          (body['attendees'] as List).cast<Map<String, dynamic>>();
      final person =
          attendees.firstWhere((a) => a['email'] == 'sam@contoso.com');
      final room = attendees.firstWhere((a) => a['email'] == _roomCalendarId);
      expect(person.containsKey('resource'), isFalse);
      expect(room['resource'], isTrue);
    });

    test('names the room in the free-text location, which is all Google has',
        () async {
      stubDirectory({
        'items': [
          {'resourceName': 'Boardroom', 'resourceEmail': _roomCalendarId},
        ],
      });
      await datasource.getMeetingRooms();

      await create(roomEmails: [_roomCalendarId], location: 'Bring laptops');

      expect(body['location'], 'Boardroom, Bring laptops');
    });

    test('does not repeat a room whose name is also the typed location',
        () async {
      stubDirectory({
        'items': [
          {'resourceName': 'Boardroom', 'resourceEmail': _roomCalendarId},
        ],
      });
      await datasource.getMeetingRooms();

      await create(roomEmails: [_roomCalendarId], location: 'Boardroom');

      expect(body['location'], 'Boardroom');
    });

    test('sends an empty location and attendee list when there are none, so a '
        'PATCH can release the last room', () async {
      await create();

      expect(body['location'], '');
      expect(body['attendees'], isEmpty);
    });
  });

  // Adding a room to a meeting that already has a Google Meet used to take the
  // join link away. `_parseLocation` hands the conference URL up as the
  // location, so the form hands it straight back — and prefixing a room name
  // left a location that no longer started with `https://`, which is the only
  // signal the app has for "joinable".
  group('a room on a meeting that already has a Meet link', () {
    const meetUrl = 'https://meet.google.com/abc-defg-hij';
    late Map<String, dynamic> body;
    late Map<String, dynamic> queryParams;

    Future<void> update({
      required String? location,
      List<String> roomEmails = const [],
      bool isOnlineMeeting = false,
    }) async {
      when(mockDio.patch<Map<String, dynamic>>(
        any,
        data: anyNamed('data'),
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => ok({
            'id': 'e1',
            'summary': 'Design review',
            'start': {'dateTime': '2026-08-10T09:00:00Z'},
            'end': {'dateTime': '2026-08-10T10:00:00Z'},
          }, '/calendars/primary/events/e1'));

      await datasource.updateCalendarEvent(
        params: UpdateCalendarEventParams(
          id: 'e1',
          subject: 'Design review',
          start: DateTime.utc(2026, 8, 10, 9),
          end: DateTime.utc(2026, 8, 10, 10),
          isAllDay: false,
          timezone: 'Australia/Brisbane',
          location: location,
          roomEmails: roomEmails,
          isOnlineMeeting: isOnlineMeeting,
        ),
      );

      final captured = verify(mockDio.patch<Map<String, dynamic>>(
        any,
        data: captureAnyNamed('data'),
        queryParameters: captureAnyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured;
      body = captured[0] as Map<String, dynamic>;
      queryParams = captured[1] as Map<String, dynamic>;
    }

    test('the join URL stays the whole location, so the meeting is still '
        'joinable', () async {
      await update(location: meetUrl, roomEmails: [_roomCalendarId]);

      expect(body['location'], meetUrl);
      expect((body['location'] as String).startsWith('https://'), isTrue);
    });

    test('the room is still booked as a resource attendee', () async {
      await update(location: meetUrl, roomEmails: [_roomCalendarId]);

      final attendees =
          (body['attendees'] as List).cast<Map<String, dynamic>>();
      // The organizer travels alongside it — Google does not add them to
      // `attendees` itself, and a guest list is drawn from that alone.
      final room = attendees.singleWhere((a) => a['resource'] == true);
      expect(room['email'], _roomCalendarId);
      expect(attendees.map((a) => a['email']), contains('me@example.com'));
    });

    test('conferenceData is not sent, so the PATCH leaves the Meet alone',
        () async {
      await update(location: meetUrl, roomEmails: [_roomCalendarId]);

      expect(body.containsKey('conferenceData'), isFalse);
    });

    test('conferenceDataVersion is always 1 — version 0 leaves conferenceData '
        'out of the response, and the cache is rewritten from it', () async {
      await update(location: meetUrl, roomEmails: [_roomCalendarId]);
      expect(queryParams['conferenceDataVersion'], 1);

      // Also for a save that has nothing to do with online meetings.
      await update(location: 'Level 3');
      expect(queryParams['conferenceDataVersion'], 1);
    });

    test('an ordinary location still gets the room named in front of it',
        () async {
      stubDirectory({
        'items': [
          {'resourceName': 'Boardroom', 'resourceEmail': _roomCalendarId},
        ],
      });
      await datasource.getMeetingRooms();

      await update(location: 'Level 3', roomEmails: [_roomCalendarId]);

      expect(body['location'], 'Boardroom, Level 3');
    });

    test('a Teams link pasted into a Google event is protected too', () async {
      const teamsUrl =
          'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0';
      await update(location: teamsUrl, roomEmails: [_roomCalendarId]);

      expect(body['location'], teamsUrl);
    });

    test('the "Google Meet" placeholder is not a URL, so a room still names '
        'itself — the real link arrives via conferenceData', () async {
      stubDirectory({
        'items': [
          {'resourceName': 'Boardroom', 'resourceEmail': _roomCalendarId},
        ],
      });
      await datasource.getMeetingRooms();

      await update(
        location: 'Google Meet',
        roomEmails: [_roomCalendarId],
        isOnlineMeeting: true,
      );

      expect(body['location'], 'Boardroom, Google Meet');
    });
  });

  test('createCalendarEvent always asks for conference data in the response',
      () async {
    when(mockDio.post<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenAnswer((_) async => ok({
          'id': 'e1',
          'summary': 'x',
          'start': {'dateTime': '2026-08-10T09:00:00Z'},
          'end': {'dateTime': '2026-08-10T10:00:00Z'},
        }, '/calendars/primary/events'));

    await datasource.createCalendarEvent(
      params: CreateCalendarEventParams(
        subject: 'x',
        start: DateTime.utc(2026, 8, 10, 9),
        end: DateTime.utc(2026, 8, 10, 10),
        isAllDay: false,
        timezone: 'UTC',
      ),
    );

    final params = verify(mockDio.post<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      queryParameters: captureAnyNamed('queryParameters'),
      options: anyNamed('options'),
    )).captured.single as Map<String, dynamic>;
    expect(params['conferenceDataVersion'], 1);
  });
}
