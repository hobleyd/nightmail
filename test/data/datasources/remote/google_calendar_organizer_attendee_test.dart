import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/google_calendar_datasource_impl.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/domain/entities/meeting_notify_scope.dart';
import 'package:nightmail/infrastructure/http/google_calendar_http_client.dart';

import 'google_calendar_organizer_attendee_test.mocks.dart';

/// Google sets `organizer` from the calendar posted to and takes `attendees`
/// verbatim — it does not add the organizer to the guest list the way its own
/// web UI does. Every guest list is drawn from `attendees`, so an organizer
/// left out of it is absent from their own meeting everywhere.
@GenerateMocks([Dio, GoogleCalendarHttpClient])
void main() {
  late MockDio mockDio;
  late GoogleCalendarDatasourceImpl datasource;

  final start = DateTime.utc(2026, 9, 10, 1);
  final end = DateTime.utc(2026, 9, 10, 2);

  /// Minimal event resource — the datasource only has to parse it back.
  Map<String, dynamic> okBody() => <String, dynamic>{
        'id': 'evt-1',
        'summary': 'Standup',
        'status': 'confirmed',
        'start': {'dateTime': '2026-09-10T11:00:00+10:00'},
        'end': {'dateTime': '2026-09-10T12:00:00+10:00'},
      };

  Response<Map<String, dynamic>> okResponse() => Response(
        data: okBody(),
        statusCode: 200,
        requestOptions: RequestOptions(path: '/calendars/primary/events'),
      );

  setUp(() {
    mockDio = MockDio();
    final client = MockGoogleCalendarHttpClient();
    when(client.dio).thenReturn(mockDio);
    datasource = GoogleCalendarDatasourceImpl(
      client: client,
      accountEmail: 'Me@Example.com',
    );

    when(mockDio.post<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((_) async => okResponse());

    when(mockDio.patch<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((_) async => okResponse());
  });

  CreateCalendarEventParams createParams({
    List<String> attendeeEmails = const [],
    List<String> roomEmails = const [],
  }) =>
      CreateCalendarEventParams(
        subject: 'Standup',
        start: start,
        end: end,
        isAllDay: false,
        timezone: 'Australia/Brisbane',
        attendeeEmails: attendeeEmails,
        roomEmails: roomEmails,
      );

  /// The request body of the single POST/PATCH the datasource made.
  Map<String, dynamic> sentBody({bool patch = false}) {
    final call = verify(patch
        ? mockDio.patch<Map<String, dynamic>>(
            any,
            data: captureAnyNamed('data'),
            queryParameters: anyNamed('queryParameters'),
          )
        : mockDio.post<Map<String, dynamic>>(
            any,
            data: captureAnyNamed('data'),
            queryParameters: anyNamed('queryParameters'),
          ));
    return call.captured.single as Map<String, dynamic>;
  }

  List<Map<String, dynamic>> attendeesOf(Map<String, dynamic> body) =>
      (body['attendees'] as List<dynamic>).cast<Map<String, dynamic>>();

  group('organizer is sent as an attendee of their own meeting', () {
    test('create with guests includes self, accepted', () async {
      await datasource.createCalendarEvent(params: createParams(
        attendeeEmails: ['guest@example.com'],
      ));

      final attendees = attendeesOf(sentBody());
      final self = attendees.singleWhere((a) => a['email'] == 'Me@Example.com');
      expect(self['responseStatus'], 'accepted');
      expect(attendees.map((a) => a['email']), contains('guest@example.com'));
    });

    test('a room-only meeting still names the organizer', () async {
      await datasource.createCalendarEvent(params: createParams(
        roomEmails: ['room@resource.calendar.google.com'],
      ));

      final attendees = attendeesOf(sentBody());
      expect(attendees.first['email'], 'Me@Example.com');
      expect(attendees.last['resource'], isTrue);
    });

    test('an event with nobody invited stays attendee-less', () async {
      await datasource.createCalendarEvent(params: createParams());

      expect(attendeesOf(sentBody()), isEmpty);
    });

    test('a roster that already names self keeps the RSVP, once', () async {
      // The shape `CalendarBloc`'s drag-to-reschedule sends: the roster read
      // back off the server, which now contains the organizer. Passing that
      // entry straight through would send it bare — Google defaults it to
      // `needsAction`, and the meeting stops counting as busy. Matched
      // case-insensitively, since an address the user typed is not normalised.
      await datasource.createCalendarEvent(params: createParams(
        attendeeEmails: ['me@example.COM', 'guest@example.com'],
      ));

      final attendees = attendeesOf(sentBody());
      final selves = attendees.where(
          (a) => (a['email'] as String).toLowerCase() == 'me@example.com');
      expect(selves, hasLength(1));
      expect(selves.single['responseStatus'], 'accepted');
      expect(attendees.map((a) => a['email']), contains('guest@example.com'));
    });

    test('an update carries it too, so a PATCH cannot drop it', () async {
      await datasource.updateCalendarEvent(
        params: UpdateCalendarEventParams(
          id: 'evt-1',
          subject: 'Standup',
          start: start,
          end: end,
          isAllDay: false,
          timezone: 'Australia/Brisbane',
          attendeeEmails: ['guest@example.com'],
          notifyScope: MeetingNotifyScope.all,
        ),
      );

      final self = attendeesOf(sentBody(patch: true))
          .singleWhere((a) => a['email'] == 'Me@Example.com');
      expect(self['responseStatus'], 'accepted');
    });
  });

  test('a create emails the invitation rather than only writing calendars',
      () async {
    await datasource.createCalendarEvent(params: createParams(
      attendeeEmails: ['guest@example.com'],
    ));

    final call = verify(mockDio.post<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      queryParameters: captureAnyNamed('queryParameters'),
    ));
    final query = call.captured.single as Map<String, dynamic>;
    // Google's default is `sendUpdates=false`: Google-calendar guests are
    // added silently and everyone else hears nothing at all.
    expect(query['sendUpdates'], 'all');
    expect(query['conferenceDataVersion'], 1);
  });
}
