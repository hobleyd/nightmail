import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';

import 'graph_api_rooms_test.mocks.dart';

const _placesPath = '/places/microsoft.graph.room';
const _findRoomsUrl = 'https://graph.microsoft.com/beta/me/findRooms';

Map<String, dynamic> _place({
  required String email,
  required String displayName,
  int? capacity,
  String? building,
  int? floorNumber,
}) =>
    {
      'id': 'place-$email',
      'emailAddress': email,
      'displayName': displayName,
      'capacity': ?capacity,
      'building': ?building,
      'floorNumber': ?floorNumber,
      'isWheelChairAccessible': false,
    };

DioException _dioError(int statusCode, String path) => DioException(
      requestOptions: RequestOptions(path: path),
      response: Response(
        statusCode: statusCode,
        requestOptions: RequestOptions(path: path),
      ),
    );

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GraphApiDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GraphApiDatasourceImpl.withDio(mockDio);
  });

  /// Stubs GET by path prefix, so /places and the absolute beta findRooms URL
  /// can answer differently in the same test.
  void stubGet(Map<String, Response<Map<String, dynamic>>> byPathPrefix) {
    when(mockDio.get<Map<String, dynamic>>(
      any,
      queryParameters: anyNamed('queryParameters'),
      options: anyNamed('options'),
    )).thenAnswer((inv) async {
      final path = inv.positionalArguments.first as String;
      for (final entry in byPathPrefix.entries) {
        if (path.startsWith(entry.key)) return entry.value;
      }
      throw _dioError(404, path);
    });
  }

  Response<Map<String, dynamic>> ok(Map<String, dynamic> data, String path) =>
      Response(
        data: data,
        statusCode: 200,
        requestOptions: RequestOptions(path: path),
      );

  group('getMeetingRooms via /places', () {
    test('maps displayName, capacity, building and floor', () async {
      stubGet({
        _placesPath: ok({
          'value': [
            _place(
              email: 'boardroom@contoso.com',
              displayName: 'Boardroom',
              capacity: 14,
              building: 'SYD',
              floorNumber: 3,
            ),
          ],
        }, _placesPath),
      });

      final rooms = await datasource.getMeetingRooms();

      expect(rooms, hasLength(1));
      expect(rooms.single.email, 'boardroom@contoso.com');
      expect(rooms.single.displayName, 'Boardroom');
      expect(rooms.single.capacity, 14);
      expect(rooms.single.building, 'SYD');
      expect(rooms.single.floorLabel, '3');
      // Graph reports floorNumber as an int; the entity carries it as text so
      // Google's free-form floorName fits the same field.
      expect(rooms.single.detailLine, 'SYD · Level 3 · 14 seats');
    });

    test('asks for a page size above the 100 default', () async {
      stubGet({_placesPath: ok({'value': <dynamic>[]}, _placesPath)});

      await datasource.getMeetingRooms();

      final path = verify(mockDio.get<Map<String, dynamic>>(
        captureAny,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured.first as String;
      expect(path, contains(r'$top='));
    });

    test('drops a place with no email address — there is nothing to book',
        () async {
      stubGet({
        _placesPath: ok({
          'value': [
            {'id': 'x', 'displayName': 'Ghost room'},
            _place(email: 'real@contoso.com', displayName: 'Real'),
          ],
        }, _placesPath),
      });

      final rooms = await datasource.getMeetingRooms();

      expect(rooms.map((r) => r.email), ['real@contoso.com']);
    });

    test('follows @odata.nextLink', () async {
      const nextLink = 'https://graph.microsoft.com/v1.0/places/page2';
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((inv) async {
        final path = inv.positionalArguments.first as String;
        if (path == nextLink) {
          return ok({
            'value': [_place(email: 'b@contoso.com', displayName: 'B')],
          }, path);
        }
        return ok({
          'value': [_place(email: 'a@contoso.com', displayName: 'A')],
          '@odata.nextLink': nextLink,
        }, path);
      });

      final rooms = await datasource.getMeetingRooms();

      expect(rooms.map((r) => r.email), ['a@contoso.com', 'b@contoso.com']);
    });
  });

  group('getMeetingRooms fallback', () {
    test('falls back to beta findRooms on 403 — the shape an account '
        'authorised before Place.Read.All is in', () async {
      stubGet({
        _placesPath: ok({'value': <dynamic>[]}, _placesPath), // unused
      });
      when(mockDio.get<Map<String, dynamic>>(
        argThat(startsWith(_placesPath)),
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(_dioError(403, _placesPath));
      when(mockDio.get<Map<String, dynamic>>(
        _findRoomsUrl,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => ok({
            'value': [
              {'name': 'Small Room', 'address': 'small@contoso.com'},
            ],
          }, _findRoomsUrl));

      final rooms = await datasource.getMeetingRooms();

      expect(rooms, hasLength(1));
      expect(rooms.single.displayName, 'Small Room');
      expect(rooms.single.email, 'small@contoso.com');
      // findRooms carries no capacity or building.
      expect(rooms.single.capacity, isNull);
      expect(rooms.single.detailLine, isNull);
    });

    test('returns empty rather than throwing when both endpoints fail — '
        'listing rooms must never block saving an event', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(_dioError(403, _placesPath));

      await expectLater(datasource.getMeetingRooms(), completion(isEmpty));
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
        options: anyNamed('options'),
      )).thenAnswer((inv) async => ok({
            'id': 'new-event',
            'subject': 'Planning',
            'isAllDay': false,
            'start': {
              'dateTime': '2026-08-10T09:00:00.0000000',
              'timeZone': 'UTC',
            },
            'end': {
              'dateTime': '2026-08-10T10:00:00.0000000',
              'timeZone': 'UTC',
            },
          }, '/me/events'));

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
        options: anyNamed('options'),
      )).captured.single as Map<String, dynamic>;
    }

    test('invites a room as a resource attendee, not a required one — the type '
        'is what runs the room booking policy', () async {
      await create(
        roomEmails: ['boardroom@contoso.com'],
        attendeeEmails: ['sam@contoso.com'],
      );

      final attendees = (body['attendees'] as List).cast<Map<String, dynamic>>();
      final person = attendees.firstWhere((a) =>
          (a['emailAddress'] as Map)['address'] == 'sam@contoso.com');
      final room = attendees.firstWhere((a) =>
          (a['emailAddress'] as Map)['address'] == 'boardroom@contoso.com');
      expect(person['type'], 'required');
      expect(room['type'], 'resource');
    });

    test('adds the room to locations as a conferenceRoom carrying its address',
        () async {
      await create(roomEmails: ['boardroom@contoso.com']);

      final locations =
          (body['locations'] as List).cast<Map<String, dynamic>>();
      expect(locations, hasLength(1));
      expect(locations.single['locationType'], 'conferenceRoom');
      expect(
          locations.single['locationEmailAddress'], 'boardroom@contoso.com');
      // Graph mirrors locations[0] into location, so the primary must agree.
      expect((body['location'] as Map)['displayName'],
          locations.single['displayName']);
    });

    test('keeps free text as a location beside the room', () async {
      await create(
        roomEmails: ['boardroom@contoso.com'],
        location: 'Dial in on 5551234',
      );

      final locations =
          (body['locations'] as List).cast<Map<String, dynamic>>();
      expect(locations, hasLength(2));
      // The room comes first: with a room booked it is the meeting's real place.
      expect(locations.first['locationType'], 'conferenceRoom');
      expect(locations.last['displayName'], 'Dial in on 5551234');
    });

    test('does not repeat a room whose name is also the typed location',
        () async {
      // The room directory has to be warm for the name comparison to be possible.
      stubGet({
        _placesPath: ok({
          'value': [
            _place(email: 'boardroom@contoso.com', displayName: 'Boardroom'),
          ],
        }, _placesPath),
      });
      await datasource.getMeetingRooms();

      await create(
        roomEmails: ['boardroom@contoso.com'],
        location: 'Boardroom',
      );

      expect((body['locations'] as List), hasLength(1));
    });

    test('sends empty attendees and locations when there are none, so a PATCH '
        'can release the last room instead of leaving it booked', () async {
      await create();

      expect(body['locations'], isEmpty);
      expect(body['attendees'], isEmpty);
      expect((body['location'] as Map)['displayName'], '');
    });

    test('a Teams join URL is not stored as a second location beside the room '
        '— the joinUrl lives in onlineMeeting, which this never touches',
        () async {
      const teamsUrl =
          'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0';
      await create(
        roomEmails: ['boardroom@contoso.com'],
        location: teamsUrl,
      );

      final locations =
          (body['locations'] as List).cast<Map<String, dynamic>>();
      expect(locations, hasLength(1));
      expect(locations.single['locationType'], 'conferenceRoom');
      expect(body.toString(), isNot(contains('meetup-join')));
    });

    test('with no room, a join URL is still the location — that is how the '
        'Join Meeting affordance survives a save', () async {
      const teamsUrl =
          'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0';
      await create(location: teamsUrl);

      expect((body['location'] as Map)['displayName'], teamsUrl);
    });
  });
}
