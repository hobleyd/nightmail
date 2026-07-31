import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/data/datasources/remote/graph_api_datasource_impl.dart';

import 'graph_api_calendar_test.mocks.dart';

final _tStart = DateTime.utc(2026, 6, 9);
final _tEnd = DateTime.utc(2026, 6, 16);

final _tEventJson = <String, dynamic>{
  'id': 'event-1',
  'subject': 'Stand-up',
  'isAllDay': false,
  'showAs': 'busy',
  'isOrganizer': true,
  'start': {'dateTime': '2026-06-10T09:00:00.0000000', 'timeZone': 'UTC'},
  'end': {'dateTime': '2026-06-10T09:15:00.0000000', 'timeZone': 'UTC'},
};

@GenerateMocks([Dio])
void main() {
  late MockDio mockDio;
  late GraphApiDatasourceImpl datasource;

  setUp(() {
    mockDio = MockDio();
    datasource = GraphApiDatasourceImpl.withDio(mockDio);
  });

  group('GraphApiDatasourceImpl.getCalendarEvents', () {
    test('calls /me/calendarView with startDateTime and endDateTime', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: {'value': <dynamic>[]},
            statusCode: 200,
            requestOptions: RequestOptions(path: '/me/calendarView'),
          ));

      await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      final captured = verify(mockDio.get<Map<String, dynamic>>(
        captureAny,
        queryParameters: captureAnyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured;

      expect(captured[0], '/me/calendarView');
      final params = captured[1] as Map<String, dynamic>;
      expect(params['startDateTime'], _tStart.toIso8601String());
      expect(params['endDateTime'], _tEnd.toIso8601String());
    });

    test('does NOT include \$orderby — calendarView does not support it', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: {'value': <dynamic>[]},
            statusCode: 200,
            requestOptions: RequestOptions(path: '/me/calendarView'),
          ));

      await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      final captured = verify(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: captureAnyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured;

      final params = captured.first as Map<String, dynamic>;
      expect(params.containsKey(r'$orderby'), isFalse,
          reason:
              '/me/calendarView does not support \$orderby and returns 400 when it is present');
    });

    test('includes required \$select fields', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: {'value': <dynamic>[]},
            statusCode: 200,
            requestOptions: RequestOptions(path: '/me/calendarView'),
          ));

      await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      final captured = verify(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: captureAnyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured;

      final params = captured.first as Map<String, dynamic>;
      final select = params[r'$select'] as String;
      for (final field in ['id', 'subject', 'start', 'end', 'isAllDay', 'showAs']) {
        expect(select, contains(field), reason: '\$select must include $field');
      }
    });

    test('sends Prefer outlook.timezone=UTC header', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: {'value': <dynamic>[]},
            statusCode: 200,
            requestOptions: RequestOptions(path: '/me/calendarView'),
          ));

      await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      final captured = verify(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: captureAnyNamed('options'),
      )).captured;

      final options = captured.first as Options?;
      expect(options?.headers?['Prefer'], contains('UTC'));
    });

    test('returns parsed events on success', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: {
              'value': [_tEventJson],
            },
            statusCode: 200,
            requestOptions: RequestOptions(path: '/me/calendarView'),
          ));

      final events = await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      expect(events.length, 1);
      expect(events.first.id, 'event-1');
      expect(events.first.subject, 'Stand-up');
    });

    test('returns empty list when value is absent', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((_) async => Response(
            data: <String, dynamic>{},
            statusCode: 200,
            requestOptions: RequestOptions(path: '/me/calendarView'),
          ));

      final events = await datasource.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      expect(events, isEmpty);
    });

    test('throws AuthException on 401', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        type: DioExceptionType.badResponse,
        response: Response(
          statusCode: 401,
          data: {
            'error': {'message': 'Access token expired.'}
          },
          requestOptions: RequestOptions(path: '/me/calendarView'),
        ),
        requestOptions: RequestOptions(path: '/me/calendarView'),
      ));

      expect(
        () => datasource.getCalendarEvents(
          startDateTime: _tStart,
          endDateTime: _tEnd,
        ),
        throwsA(isA<AuthException>()),
      );
    });

    test('throws ServerException on 400 (e.g. unsupported query parameter)', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        type: DioExceptionType.badResponse,
        response: Response(
          statusCode: 400,
          data: {
            'error': {'message': 'The OData query option is not supported.'}
          },
          requestOptions: RequestOptions(path: '/me/calendarView'),
        ),
        requestOptions: RequestOptions(path: '/me/calendarView'),
      ));

      expect(
        () => datasource.getCalendarEvents(
          startDateTime: _tStart,
          endDateTime: _tEnd,
        ),
        throwsA(isA<ServerException>()),
      );
    });

    test('throws NetworkException on connection error', () async {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(DioException(
        type: DioExceptionType.connectionError,
        requestOptions: RequestOptions(path: '/me/calendarView'),
      ));

      expect(
        () => datasource.getCalendarEvents(
          startDateTime: _tStart,
          endDateTime: _tEnd,
        ),
        throwsA(isA<NetworkException>()),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Accepting an attendee's proposed new time (organizer side)
  // ---------------------------------------------------------------------------

  group('GraphApiDatasourceImpl.acceptProposedTimeFromEmail', () {
    final newStart = DateTime.utc(2026, 8, 5, 1, 30);
    final newEnd = DateTime.utc(2026, 8, 5, 2, 0);
    final currentStart = DateTime.utc(2026, 8, 4, 1, 30);

    Response<Map<String, dynamic>> resp(Map<String, dynamic> data, String path) =>
        Response(
            data: data,
            statusCode: 200,
            requestOptions: RequestOptions(path: path));

    DioException dioErr(String path, int status) => DioException(
          response: Response(
            data: {
              'error': {'code': 'ErrorItemNotFound', 'message': 'Not found.'}
            },
            statusCode: status,
            requestOptions: RequestOptions(path: path),
          ),
          requestOptions: RequestOptions(path: path),
        );

    /// Routes every GET by path; a responder returning null raises a 404.
    void stubGets(Map<String, dynamic>? Function(String path) responder) {
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((inv) async {
        final path = inv.positionalArguments[0] as String;
        final data = responder(path);
        if (data == null) throw dioErr(path, 404);
        return resp(data, path);
      });
    }

    void stubPatchOk() {
      when(mockDio.patch<void>(any, data: anyNamed('data'))).thenAnswer(
        (inv) async => Response<void>(
          statusCode: 200,
          requestOptions:
              RequestOptions(path: inv.positionalArguments[0] as String),
        ),
      );
    }

    const counterIcs = 'BEGIN:VCALENDAR\r\n'
        'METHOD:COUNTER\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:evt-1@example.com\r\n'
        'SUMMARY:Quarterly review\r\n'
        'DTSTART:20260805T013000Z\r\n'
        'DTEND:20260805T020000Z\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR';

    Future<void> accept({DateTime? meetingStart, String? icsData}) =>
        datasource.acceptProposedTimeFromEmail(
          emailId: 'msg-9',
          newStart: newStart,
          newEnd: newEnd,
          meetingStart: meetingStart,
          icsData: icsData,
        );

    ({String path, Map<String, dynamic> data}) capturedPatch() {
      final captured = verify(mockDio.patch<void>(
        captureAny,
        data: captureAnyNamed('data'),
      )).captured;
      return (
        path: captured[0] as String,
        data: (captured[1] as Map).cast<String, dynamic>(),
      );
    }

    test('finds the meeting by the UID in the calendar attachment', () async {
      // Regression: a METHOD:COUNTER from a non-Exchange client stays an
      // ordinary message, so every event navigation is rejected outright with
      // "Resource not found for the segment 'EventMessage'". The UID in the
      // attached .ics is the only locator that survives that.
      stubGets((path) {
        if (path == '/me/messages/msg-9/attachments') {
          return {
            'value': [
              {'id': 'att-doc', 'name': 'agenda.pdf', 'contentType': 'application/pdf'},
              {'id': 'att-cal', 'name': 'counter.ics', 'contentType': 'text/calendar; method=COUNTER'},
            ],
          };
        }
        if (path == '/me/messages/msg-9/attachments/att-cal') {
          return {
            'id': 'att-cal',
            'contentBytes': base64Encode(utf8.encode(counterIcs)),
          };
        }
        if (path == '/me/events') {
          return {
            'value': [
              {'id': 'event-uid', 'isOrganizer': true},
            ],
          };
        }
        return null;
      });
      stubPatchOk();

      await accept();

      expect(capturedPatch().path, '/me/events/event-uid');
      final params = verify(mockDio.get<Map<String, dynamic>>(
        '/me/events',
        queryParameters: captureAnyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured.single as Map<String, dynamic>;
      expect(params[r'$filter'], "iCalUId eq 'evt-1@example.com'");
    });

    test('uses a caller-supplied ICS without fetching attachments', () async {
      stubGets((path) => path == '/me/events'
          ? {
              'value': [
                {'id': 'event-uid', 'isOrganizer': true}
              ]
            }
          : null);
      stubPatchOk();

      await accept(icsData: counterIcs);

      expect(capturedPatch().path, '/me/events/event-uid');
      verifyNever(mockDio.get<Map<String, dynamic>>(
        '/me/messages/msg-9/attachments',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      ));
    });

    test('refuses when the UID resolves to a meeting someone else organizes',
        () async {
      stubGets((path) => path == '/me/events'
          ? {
              'value': [
                {'id': 'event-uid', 'isOrganizer': false}
              ]
            }
          : null);
      stubPatchOk();

      await expectLater(
        accept(icsData: counterIcs),
        throwsA(isA<ServerException>().having(
            (e) => e.message, 'message', contains('not the organizer'))),
      );
      verifyNever(mockDio.patch<void>(any, data: anyNamed('data')));
    });

    test('reads the UID from the decline that accompanies the proposal',
        () async {
      // Outlook splits propose-new-time into two messages: a decline carrying
      // the .ics, and the proposal itself, which has no calendar part and whose
      // event navigation Exchange does not implement. The UID therefore has to
      // come from the sibling.
      stubGets((path) {
        if (path == '/me/messages/msg-9') {
          return {
            'id': 'msg-9',
            'conversationId': 'conv-1',
            '@odata.type': '#microsoft.graph.eventMessageResponse',
          };
        }
        if (path == '/me/messages') {
          return {
            'value': [
              {'id': 'msg-9'},
              {'id': 'msg-decline'},
            ],
          };
        }
        if (path == '/me/messages/msg-decline/attachments') {
          return {
            'value': [
              {'id': 'att-cal', 'name': 'meeting.ics', 'contentType': 'text/calendar'},
            ],
          };
        }
        if (path == '/me/messages/msg-decline/attachments/att-cal') {
          return {'contentBytes': base64Encode(utf8.encode(counterIcs))};
        }
        if (path == '/me/events') {
          return {
            'value': [
              {'id': 'event-uid', 'isOrganizer': true},
            ],
          };
        }
        return null; // the proposal has no attachments and no navigable event
      });
      stubPatchOk();

      await accept();

      expect(capturedPatch().path, '/me/events/event-uid');
    });

    test('reaches the event through the eventMessage type cast', () async {
      // Regression: the uncast /me/messages/{id}/event draws HTTP 400
      // "Resource not found for the segment 'event'" — `event` is declared on
      // the derived eventMessage type, so OData needs the cast segment.
      stubGets((path) =>
          path == linkedEventPath('msg-9') ? {'id': 'event-7', 'isOrganizer': true} : null);
      stubPatchOk();

      await accept(meetingStart: currentStart);

      expect(capturedPatch().path, '/me/events/event-7');
      verify(mockDio.get<Map<String, dynamic>>(
        '/me/messages/msg-9/microsoft.graph.eventMessage/event',
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).called(1);
    });

    test('still accepts a mailbox that only answers the uncast path', () async {
      stubGets((path) => path == '/me/messages/msg-9/event'
          ? {'id': 'event-7', 'isOrganizer': true}
          : null);
      stubPatchOk();

      await accept(meetingStart: currentStart);

      expect(capturedPatch().path, '/me/events/event-7');
    });

    test('sends the new time as UTC wall-clock labelled UTC', () async {
      // The dateTime string and the timeZone field must describe the same zone;
      // disagreeing shifts the meeting by the local offset.
      stubGets((path) =>
          path == linkedEventPath('msg-9') ? {'id': 'event-7', 'isOrganizer': true} : null);
      stubPatchOk();

      await accept(meetingStart: currentStart);

      final data = capturedPatch().data;
      expect(data['start'], {'dateTime': '2026-08-05T01:30:00.000', 'timeZone': 'UTC'});
      expect(data['end'], {'dateTime': '2026-08-05T02:00:00.000', 'timeZone': 'UTC'});
    });

    test('refuses when the caller does not organize the meeting', () async {
      // Settled answer, not a failed lookup: no fallback should be attempted.
      stubGets((path) => path == linkedEventPath('msg-9')
          ? {'id': 'event-7', 'isOrganizer': false}
          : null);
      stubPatchOk();

      await expectLater(
        accept(meetingStart: currentStart),
        throwsA(isA<ServerException>().having(
            (e) => e.message, 'message', contains('not the organizer'))),
      );
      verifyNever(mockDio.patch<void>(any, data: anyNamed('data')));
    });

    test('falls back to the calendar search when navigation fails', () async {
      // Graph's message-to-event navigation is specified around meeting
      // requests and often 404s from a response.
      stubGets((path) {
        if (path == '/me/calendarView') {
          return {
            'value': [
              {'id': 'event-other', 'isOrganizer': false},
              {'id': 'event-mine', 'isOrganizer': true},
            ],
          };
        }
        return null;
      });
      stubPatchOk();

      await accept(meetingStart: currentStart);

      expect(capturedPatch().path, '/me/events/event-mine');
    });

    test('traces back to the original invitation in the conversation',
        () async {
      // Last resort when the message carries no usable time: the invitation we
      // sent is in the same thread, and *its* navigation Graph does support.
      stubGets((path) {
        if (path == '/me/messages/msg-9') {
          return {'id': 'msg-9', 'conversationId': 'conv-1'};
        }
        if (path == '/me/messages') {
          return {
            'value': [
              {'id': 'msg-9'},
              {'id': 'msg-plain'},
              {'id': 'msg-1'},
            ],
          };
        }
        if (path == linkedEventPath('msg-1')) {
          return {'id': 'event-orig', 'isOrganizer': true};
        }
        return null; // the proposal's own navigation, and msg-plain, fail
      });
      stubPatchOk();

      await accept();

      expect(capturedPatch().path, '/me/events/event-orig');
    });

    test('does not ask a message collection for meetingMessageType', () async {
      // Regression: that property lives on the derived eventMessage type, so
      // selecting it drew HTTP 400 and killed this strategy outright.
      stubGets((path) => path == '/me/messages/msg-9'
          ? {'id': 'msg-9', 'conversationId': 'conv-1'}
          : null);
      stubPatchOk();

      await accept().catchError((_) {});

      final selects = verify(mockDio.get<Map<String, dynamic>>(
        '/me/messages',
        queryParameters: captureAnyNamed('queryParameters'),
        options: anyNamed('options'),
      )).captured;
      expect(selects, isNotEmpty);
      for (final params in selects.cast<Map<String, dynamic>>()) {
        expect(params[r'$select'], isNot(contains('meetingMessageType')));
      }
    });

    test('names every strategy it tried when the meeting cannot be found',
        () async {
      // Regression: this reported a bare "Could not locate the calendar event
      // to update", which said nothing about which step failed or why.
      stubGets((path) => path == '/me/messages/msg-9'
          ? {'id': 'msg-9'} // no startDateTime, no conversationId
          : null);
      stubPatchOk();

      await expectLater(
        accept(),
        throwsA(isA<ServerException>().having((e) => e.message, 'message',
            allOf(
              contains('calendar attachment'),
              contains('microsoft.graph.eventMessageResponse/event'),
              contains('HTTP 404'),
              contains('no current meeting time'),
              contains('no conversation'),
            ))),
      );
    });

    test('reports the message type when nothing resolves', () async {
      // The real type explains most of the failures above and is otherwise
      // invisible: a plain message has no event to navigate to.
      stubGets((path) => path == '/me/messages/msg-9'
          ? {'id': 'msg-9', '@odata.type': '#microsoft.graph.message'}
          : null);
      stubPatchOk();

      await expectLater(
        accept(),
        throwsA(isA<ServerException>().having((e) => e.message, 'message',
            contains('the message is a #microsoft.graph.message'))),
      );
    });

    test('surfaces an auth failure instead of trying the fallbacks', () async {
      // A 401 has to reach the UI as an AuthException so re-auth is offered.
      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenThrow(dioErr('/me/messages/msg-9/event', 401));

      await expectLater(accept(meetingStart: currentStart),
          throwsA(isA<AuthException>()));
    });
  });

  group('GraphApiDatasourceImpl.proposeNewTimeFromEmail', () {
    test('labels the proposed time with the zone it is actually in', () async {
      // Regression: the value was rendered as local wall-clock but labelled
      // 'UTC', so a proposal of 11:30 Sydney reached the organizer as 21:30.
      final newStart = DateTime.utc(2026, 8, 5, 1, 30);
      final newEnd = DateTime.utc(2026, 8, 5, 2, 0);

      when(mockDio.get<Map<String, dynamic>>(
        any,
        queryParameters: anyNamed('queryParameters'),
        options: anyNamed('options'),
      )).thenAnswer((inv) async => Response(
            data: {'id': 'event-3', 'isOrganizer': false},
            statusCode: 200,
            requestOptions: RequestOptions(
                path: inv.positionalArguments[0] as String),
          ));
      when(mockDio.post<void>(any, data: anyNamed('data'))).thenAnswer(
        (inv) async => Response<void>(
          statusCode: 202,
          requestOptions:
              RequestOptions(path: inv.positionalArguments[0] as String),
        ),
      );

      await datasource.proposeNewTimeFromEmail(
        emailId: 'msg-2',
        newStart: newStart,
        newEnd: newEnd,
      );

      final captured = verify(mockDio.post<void>(
        captureAny,
        data: captureAnyNamed('data'),
      )).captured;
      expect(captured[0], '/me/events/event-3/decline');
      final slot = ((captured[1] as Map)['proposedNewTime'] as Map)
          .cast<String, dynamic>();
      expect(slot['start'],
          {'dateTime': '2026-08-05T01:30:00.000', 'timeZone': 'UTC'});
      expect(slot['end'],
          {'dateTime': '2026-08-05T02:00:00.000', 'timeZone': 'UTC'});
    });
  });
}
