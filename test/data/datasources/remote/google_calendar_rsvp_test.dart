import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/google_calendar_datasource_impl.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';
import 'package:nightmail/infrastructure/http/google_calendar_http_client.dart';

import 'google_calendar_rsvp_test.mocks.dart';

/// Answering an invitation may never *create* an event.
///
/// A created event is organized by this account, so Google mails everybody on
/// the invitation "Invitation: <title>" for a meeting they are already in — and
/// the created copy carries no RRULE, so a recurring series arrives as a single
/// occurrence. That is what the old create fallback did whenever the `iCalUID`
/// lookup missed, which a recurring invitation makes likely: the ICS carries
/// the series' bare UID while Google files the expanded instance under
/// `<masterUid>_<instanceStart>@google.com`.
@GenerateMocks([Dio, GoogleCalendarHttpClient])
void main() {
  late MockDio mockDio;
  late GoogleCalendarDatasourceImpl datasource;

  const ics = 'BEGIN:VCALENDAR\r\n'
      'METHOD:REQUEST\r\n'
      'BEGIN:VEVENT\r\n'
      'UID:series-uid-1\r\n'
      'DTSTART:20260910T010000Z\r\n'
      'DTEND:20260910T020000Z\r\n'
      'SUMMARY:Weekly sync\r\n'
      'ORGANIZER:mailto:boss@example.com\r\n'
      'ATTENDEE:mailto:boss@example.com\r\n'
      'ATTENDEE:mailto:me@example.com\r\n'
      'END:VEVENT\r\n'
      'END:VCALENDAR';

  /// The shape Google sends for "Updated invitation: … @ Thu 17 Sept": one
  /// occurrence of a series, named by `RECURRENCE-ID`, under the (split)
  /// master's UID.
  const occurrenceIcs = 'BEGIN:VCALENDAR\r\n'
      'METHOD:REQUEST\r\n'
      'BEGIN:VEVENT\r\n'
      'UID:series-uid-1\r\n'
      'DTSTART:20260910T010000Z\r\n'
      'DTEND:20260910T020000Z\r\n'
      'RECURRENCE-ID:20260910T011500Z\r\n'
      'SUMMARY:Weekly sync\r\n'
      'ORGANIZER:mailto:boss@example.com\r\n'
      'ATTENDEE:mailto:boss@example.com\r\n'
      'ATTENDEE:mailto:me@example.com\r\n'
      'END:VEVENT\r\n'
      'END:VCALENDAR';

  final meetingStart = DateTime.utc(2026, 9, 10, 1);

  Response<Map<String, dynamic>> listing(List<Map<String, dynamic>> items) =>
      Response(
        data: {'items': items},
        statusCode: 200,
        requestOptions: RequestOptions(path: '/calendars/primary/events'),
      );

  /// The expanded instance of a recurring series, as `singleEvents=true`
  /// returns it: a suffixed `iCalUID`, and the master's id beside it.
  Map<String, dynamic> recurringInstance() => {
        'id': 'master-1_20260910T010000Z',
        'recurringEventId': 'master-1',
        'iCalUID': 'series-uid-1_20260910T010000Z@google.com',
        'start': {'dateTime': '2026-09-10T01:00:00Z'},
        'organizer': {'email': 'boss@example.com'},
        'attendees': [
          {'email': 'boss@example.com', 'responseStatus': 'accepted'},
          {'email': 'me@example.com', 'self': true, 'responseStatus': 'needsAction'},
          {'email': 'someone.else@example.com', 'responseStatus': 'needsAction'},
        ],
      };

  void stubUidLookup(List<Map<String, dynamic>> items) {
    when(mockDio.get<Map<String, dynamic>>(
      '/calendars/primary/events',
      queryParameters: argThat(
        containsPair('iCalUID', 'series-uid-1'),
        named: 'queryParameters',
      ),
    )).thenAnswer((_) async => listing(items));
  }

  void stubWindowLookup(List<Map<String, dynamic>> items) {
    when(mockDio.get<Map<String, dynamic>>(
      '/calendars/primary/events',
      queryParameters: argThat(
        containsPair('singleEvents', true),
        named: 'queryParameters',
      ),
    )).thenAnswer((_) async => listing(items));
  }

  setUp(() {
    mockDio = MockDio();
    final client = MockGoogleCalendarHttpClient();
    when(client.dio).thenReturn(mockDio);
    datasource = GoogleCalendarDatasourceImpl(
      client: client,
      accountEmail: 'me@example.com',
    );

    when(mockDio.patch<void>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((inv) async => Response<void>(
          statusCode: 200,
          requestOptions:
              RequestOptions(path: inv.positionalArguments.first as String),
        ));
    when(mockDio.delete<void>(
      any,
      queryParameters: anyNamed('queryParameters'),
    )).thenAnswer((inv) async => Response<void>(
          statusCode: 204,
          requestOptions:
              RequestOptions(path: inv.positionalArguments.first as String),
        ));
  });

  Future<void> accept() => datasource.respondToMeetingInvite(
        emailId: 'msg-1',
        response: MeetingInviteResponseType.accept,
        icsData: ics,
        meetingStart: meetingStart,
        userEmail: 'me@example.com',
      );

  test('a meeting that cannot be found is reported, never created', () async {
    stubUidLookup(const []);
    stubWindowLookup(const []);

    // 404 so the calendar outbox drops the queued op rather than retrying a
    // lookup that cannot start succeeding.
    await expectLater(
      accept(),
      throwsA(isA<ServerException>()
          .having((e) => e.statusCode, 'statusCode', 404)),
    );

    verifyNever(mockDio.post<void>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    ));
    verifyNever(mockDio.patch<void>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    ));
  });

  test('a recurring invitation the UID lookup misses is answered on its master',
      () async {
    stubUidLookup(const []);
    stubWindowLookup([recurringInstance()]);

    await accept();

    final patch = verify(mockDio.patch<void>(
      captureAny,
      data: captureAnyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    )).captured;
    expect(patch[0], '/calendars/primary/events/master-1');

    final attendees =
        ((patch[1] as Map)['attendees'] as List).cast<Map<String, dynamic>>();
    expect(
      attendees.firstWhere((a) => a['email'] == 'me@example.com')['responseStatus'],
      'accepted',
    );
    // Everybody else's entry is sent back exactly as the server gave it.
    expect(
      attendees.firstWhere((a) => a['email'] == 'boss@example.com')['responseStatus'],
      'accepted',
    );
    expect(attendees.map((a) => a['email']), contains('someone.else@example.com'));

    verifyNever(mockDio.post<void>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    ));
  });

  test('the roster sent is the server\'s, not the invitation\'s', () async {
    // The UID lookup hits, and the event's roster holds somebody the ICS does
    // not name. Sending the ICS's list instead would read as that guest being
    // removed, and `sendUpdates: all` would cancel their copy of the meeting.
    stubUidLookup([
      {
        'id': 'master-1',
        'iCalUID': 'series-uid-1',
        'start': {'dateTime': '2026-09-10T01:00:00Z'},
        'organizer': {'email': 'boss@example.com'},
        'attendees': [
          {'email': 'boss@example.com', 'responseStatus': 'accepted'},
          {'email': 'me@example.com', 'self': true, 'responseStatus': 'needsAction'},
          {'email': 'someone.else@example.com', 'responseStatus': 'tentative'},
        ],
      }
    ]);

    await accept();

    final patch = verify(mockDio.patch<void>(
      captureAny,
      data: captureAnyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    )).captured;
    expect(patch[0], '/calendars/primary/events/master-1');
    final attendees =
        ((patch[1] as Map)['attendees'] as List).cast<Map<String, dynamic>>();
    expect(attendees.map((a) => a['email']),
        containsAll(['boss@example.com', 'someone.else@example.com']));
    expect(
      attendees.firstWhere((a) => a['email'] == 'someone.else@example.com')['responseStatus'],
      'tentative',
    );
  });

  test('declining an invitation nothing on the calendar matches does nothing',
      () async {
    stubUidLookup(const []);
    stubWindowLookup(const []);

    await datasource.respondToMeetingInvite(
      emailId: 'msg-1',
      response: MeetingInviteResponseType.decline,
      icsData: ics,
      meetingStart: meetingStart,
      userEmail: 'me@example.com',
    );

    verifyNever(mockDio.post<void>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    ));
    verifyNever(mockDio.patch<void>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    ));
  });

  test('declining never acts on a start-time guess', () async {
    // A decline answers *and* deletes, and an instance's answer belongs on its
    // master — so the heuristic match is not offered a whole series to remove.
    stubUidLookup(const []);
    stubWindowLookup([recurringInstance()]);

    await datasource.respondToMeetingInvite(
      emailId: 'msg-1',
      response: MeetingInviteResponseType.decline,
      icsData: ics,
      meetingStart: meetingStart,
      userEmail: 'me@example.com',
    );

    verifyNever(mockDio.patch<void>(
      any,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    ));
    verifyNever(mockDio.delete<void>(any,
        queryParameters: anyNamed('queryParameters')));
  });

  test('declining answers the organizer and then removes our copy', () async {
    stubUidLookup([
      {
        'id': 'master-1',
        'iCalUID': 'series-uid-1',
        'start': {'dateTime': '2026-09-10T01:00:00Z'},
        'organizer': {'email': 'boss@example.com'},
        'attendees': [
          {'email': 'boss@example.com', 'responseStatus': 'accepted'},
          {
            'email': 'me@example.com',
            'self': true,
            'responseStatus': 'needsAction'
          },
        ],
      }
    ]);

    await datasource.respondToMeetingInvite(
      emailId: 'msg-1',
      response: MeetingInviteResponseType.decline,
      icsData: ics,
      meetingStart: meetingStart,
      userEmail: 'me@example.com',
    );

    final patch = verify(mockDio.patch<void>(
      captureAny,
      data: captureAnyNamed('data'),
      queryParameters: captureAnyNamed('queryParameters'),
    )).captured;
    expect(patch[0], '/calendars/primary/events/master-1');
    final attendees =
        ((patch[1] as Map)['attendees'] as List).cast<Map<String, dynamic>>();
    expect(
      attendees.firstWhere((a) => a['email'] == 'me@example.com')['responseStatus'],
      'declined',
    );
    expect((patch[2] as Map)['sendUpdates'], 'all');

    final deleted = verify(mockDio.delete<void>(
      captureAny,
      queryParameters: captureAnyNamed('queryParameters'),
    )).captured;
    expect(deleted[0], '/calendars/primary/events/master-1');
    expect((deleted[1] as Map)['sendUpdates'], 'none');
  });

  test('an invitation to one occurrence is answered on that occurrence',
      () async {
    // Google keeps a modified occurrence as its own resource with its own
    // roster, so an answer sent to the series master never reaches it — the
    // occurrence stays on `needsAction`, which the app draws as tentative.
    stubUidLookup(const []);
    stubWindowLookup([recurringInstance()]);

    await datasource.respondToMeetingInvite(
      emailId: 'msg-1',
      response: MeetingInviteResponseType.accept,
      icsData: occurrenceIcs,
      meetingStart: meetingStart,
      userEmail: 'me@example.com',
    );

    final patch = verify(mockDio.patch<void>(
      captureAny,
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    )).captured;
    expect(patch.single, '/calendars/primary/events/master-1_20260910T010000Z');
  });

  test('a series master that 404s falls back to the occurrence', () async {
    // "This and following" splits a series: the instances after the split name
    // a master `<id>_R<start>` an attendee holds no copy of.
    stubUidLookup(const []);
    stubWindowLookup([recurringInstance()]);
    when(mockDio.patch<void>(
      '/calendars/primary/events/master-1',
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    )).thenThrow(DioException(
      requestOptions: RequestOptions(path: '/calendars/primary/events/master-1'),
      response: Response<void>(
        statusCode: 404,
        requestOptions:
            RequestOptions(path: '/calendars/primary/events/master-1'),
      ),
    ));

    await accept();

    verify(mockDio.patch<void>(
      '/calendars/primary/events/master-1_20260910T010000Z',
      data: anyNamed('data'),
      queryParameters: anyNamed('queryParameters'),
    )).called(1);
  });

  test('declining one occurrence removes that occurrence, not the series',
      () async {
    stubUidLookup(const []);
    stubWindowLookup([recurringInstance()]);

    await datasource.respondToMeetingInvite(
      emailId: 'msg-1',
      response: MeetingInviteResponseType.decline,
      icsData: occurrenceIcs,
      meetingStart: meetingStart,
      userEmail: 'me@example.com',
    );

    final deleted = verify(mockDio.delete<void>(
      captureAny,
      queryParameters: anyNamed('queryParameters'),
    )).captured;
    expect(
        deleted.single, '/calendars/primary/events/master-1_20260910T010000Z');
  });
}
