import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/google_calendar_datasource_impl.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
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
///
/// A *forwarded* invitation — one this account is not on the guest list of, so
/// Google never filed it — is kept through `importMeetingInvite` instead, and
/// the second half of this file pins how that differs: an imported copy names
/// the invitation's own organizer, carries its UID and recurrence, and is
/// never an insert. The RSVP path itself still only reports the miss; the
/// repository decides whether the miss is a forwarded invitation.
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

    // Typed, so the repository can tell a forwarded invitation from any other
    // failure — and a 404 so the calendar outbox drops the queued op rather
    // than retrying a lookup that cannot start succeeding.
    await expectLater(
      accept(),
      throwsA(isA<MeetingNotOnCalendarException>()
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

  test('declining an invitation nothing on the calendar matches reports it, '
      'removing nothing', () async {
    stubUidLookup(const []);
    stubWindowLookup(const []);

    // The same typed miss as an accept: a forwarded invitation declined still
    // owes the organizer a reply, and only the repository knows whether this
    // was one. Nothing is patched or deleted on the way out.
    await expectLater(
      datasource.respondToMeetingInvite(
        emailId: 'msg-1',
        response: MeetingInviteResponseType.decline,
        icsData: ics,
        meetingStart: meetingStart,
        userEmail: 'me@example.com',
      ),
      throwsA(isA<MeetingNotOnCalendarException>()),
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
    // What it reports instead is the typed miss, the same as finding nothing.
    stubUidLookup(const []);
    stubWindowLookup([recurringInstance()]);

    await expectLater(
      datasource.respondToMeetingInvite(
        emailId: 'msg-1',
        response: MeetingInviteResponseType.decline,
        icsData: ics,
        meetingStart: meetingStart,
        userEmail: 'me@example.com',
      ),
      throwsA(isA<MeetingNotOnCalendarException>()),
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

  group('importMeetingInvite', () {
    /// An invitation somebody forwarded on: the roster is the organizer's,
    /// and this account is not on it.
    const forwardedIcs = 'BEGIN:VCALENDAR\r\n'
        'METHOD:REQUEST\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:fwd-uid-1\r\n'
        'SEQUENCE:2\r\n'
        'DTSTART:20260910T010000Z\r\n'
        'DTEND:20260910T020000Z\r\n'
        'SUMMARY:Discovery call\r\n'
        'DESCRIPTION:Agenda attached\r\n'
        'LOCATION:Teams\r\n'
        'ORGANIZER;CN=Boss:mailto:boss@example.com\r\n'
        'ATTENDEE:mailto:boss@example.com\r\n'
        'ATTENDEE:mailto:someone.else@example.com\r\n'
        'RRULE:FREQ=WEEKLY;COUNT=4\r\n'
        'EXDATE;TZID=AUS Eastern Standard Time:20260917T110000\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR';

    Map<String, dynamic> imported() => {
          'id': 'kept-1',
          'iCalUID': 'fwd-uid-1',
          'summary': 'Discovery call',
          'start': {'dateTime': '2026-09-10T01:00:00Z'},
          'end': {'dateTime': '2026-09-10T02:00:00Z'},
          'organizer': {'email': 'boss@example.com'},
          'attendees': [
            {'email': 'me@example.com', 'self': true, 'responseStatus': 'accepted'},
          ],
        };

    /// Stubs the import endpoint; [statuses] are what successive calls do —
    /// an int is a failure with that status, null a success. Returns the
    /// bodies posted, in order; [queries] collects their query parameters.
    final queries = <Object?>[];
    List<Map<String, dynamic>> stubImport([List<int?> statuses = const [null]]) {
      final bodies = <Map<String, dynamic>>[];
      var call = 0;
      when(mockDio.post<Map<String, dynamic>>(
        '/calendars/primary/events/import',
        data: anyNamed('data'),
      )).thenAnswer((inv) async {
        bodies.add(
            Map<String, dynamic>.from(inv.namedArguments[#data] as Map));
        queries.add(inv.namedArguments[#queryParameters]);
        final status = call < statuses.length ? statuses[call] : null;
        call++;
        if (status != null) {
          throw DioException(
            requestOptions: RequestOptions(path: '/calendars/primary/events/import'),
            response: Response(
              statusCode: status,
              requestOptions:
                  RequestOptions(path: '/calendars/primary/events/import'),
            ),
          );
        }
        return Response(
          data: imported(),
          statusCode: 200,
          requestOptions:
              RequestOptions(path: '/calendars/primary/events/import'),
        );
      });
      return bodies;
    }

    Future<CalendarEventModel> keep({
      String icsData = forwardedIcs,
      MeetingInviteResponseType response = MeetingInviteResponseType.accept,
      String? message,
    }) =>
        datasource.importMeetingInvite(
          icsData: icsData,
          response: response,
          userEmail: 'me@example.com',
          message: message,
        );

    test('imports a copy under the organizer and UID, and never inserts',
        () async {
      final bodies = stubImport();

      final kept = await keep();

      expect(kept.id, 'kept-1');
      final body = bodies.single;
      expect(body['iCalUID'], 'fwd-uid-1');
      expect((body['organizer'] as Map)['email'], 'boss@example.com');
      expect((body['organizer'] as Map)['displayName'], 'Boss');
      expect(body['summary'], 'Discovery call');
      expect(body['description'], 'Agenda attached');
      expect(body['location'], 'Teams');
      expect(body['sequence'], 2);
      // No insert, and no `sendUpdates`: an imported copy emails nobody.
      verifyNever(mockDio.post<Map<String, dynamic>>(
        '/calendars/primary/events',
        data: anyNamed('data'),
        queryParameters: anyNamed('queryParameters'),
      ));
      expect(queries.single, isNull);
    });

    test('records the answer on this account alone and lists the rest unanswered',
        () async {
      final bodies = stubImport();

      await keep(
          response: MeetingInviteResponseType.tentative, message: 'Maybe');

      final attendees =
          (bodies.single['attendees'] as List).cast<Map<String, dynamic>>();
      final me = attendees.singleWhere((a) => a['email'] == 'me@example.com');
      expect(me['responseStatus'], 'tentative');
      expect(me['comment'], 'Maybe');
      for (final other in attendees.where((a) => a['email'] != 'me@example.com')) {
        expect(other.containsKey('responseStatus'), isFalse,
            reason: 'their real answers live on the organizer\'s copy');
      }
      expect(attendees.map((a) => a['email']),
          containsAll(['boss@example.com', 'someone.else@example.com']));
    });

    test('carries the recurrence through, with a named time zone', () async {
      final bodies = stubImport();

      await keep();

      final body = bodies.single;
      expect(body['recurrence'], [
        'RRULE:FREQ=WEEKLY;COUNT=4',
        'EXDATE;TZID=AUS Eastern Standard Time:20260917T110000',
      ]);
      expect((body['start'] as Map)['timeZone'], isNotEmpty);
      expect((body['end'] as Map)['timeZone'], isNotEmpty);
    });

    test('an exception date Google rejects costs the exceptions, not the copy',
        () async {
      final bodies = stubImport([400, null]);

      await keep();

      expect(bodies, hasLength(2));
      expect(bodies.last['recurrence'], ['RRULE:FREQ=WEEKLY;COUNT=4']);
    });

    test('anything but a rejected body is reported, not retried', () async {
      final bodies = stubImport([500]);

      await expectLater(keep(), throwsA(isA<ServerException>()));

      expect(bodies, hasLength(1));
    });

    test('a rejected body with nothing left to drop is reported', () async {
      const single = 'BEGIN:VCALENDAR\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:fwd-uid-2\r\n'
          'DTSTART:20260910T010000Z\r\n'
          'DTEND:20260910T020000Z\r\n'
          'ORGANIZER:mailto:boss@example.com\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR';
      final bodies = stubImport([400]);

      await expectLater(keep(icsData: single), throwsA(isA<ServerException>()));

      expect(bodies, hasLength(1));
      expect(bodies.single.containsKey('recurrence'), isFalse);
    });

    test('writes an all-day meeting as dates', () async {
      const allDay = 'BEGIN:VCALENDAR\r\n'
          'BEGIN:VEVENT\r\n'
          'UID:fwd-uid-3\r\n'
          'DTSTART;VALUE=DATE:20260910\r\n'
          'DTEND;VALUE=DATE:20260911\r\n'
          'ORGANIZER:mailto:boss@example.com\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR';
      final bodies = stubImport();

      await keep(icsData: allDay);

      expect(bodies.single['start'], {'date': '2026-09-10'});
      expect(bodies.single['end'], {'date': '2026-09-11'});
    });

    test('an invitation with no UID cannot be kept', () async {
      const noUid = 'BEGIN:VCALENDAR\r\n'
          'BEGIN:VEVENT\r\n'
          'DTSTART:20260910T010000Z\r\n'
          'DTEND:20260910T020000Z\r\n'
          'ORGANIZER:mailto:boss@example.com\r\n'
          'END:VEVENT\r\n'
          'END:VCALENDAR';
      final bodies = stubImport();

      await expectLater(keep(icsData: noUid), throwsA(isA<ServerException>()));

      expect(bodies, isEmpty);
    });
  });
}
