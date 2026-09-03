import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/data/datasources/remote/google_calendar_datasource_impl.dart';
import 'package:nightmail/domain/entities/attendee_availability.dart';
import 'package:nightmail/infrastructure/http/google_calendar_http_client.dart';

import 'google_calendar_freebusy_test.mocks.dart';

// A 09:00–10:00 Brisbane (UTC+10) meeting on 27 Jul 2026.
final _start = DateTime.utc(2026, 7, 26, 23);
final _end = DateTime.utc(2026, 7, 27, 0);

@GenerateMocks([Dio, GoogleCalendarHttpClient])
void main() {
  late MockDio mockDio;
  late GoogleCalendarDatasourceImpl datasource;

  /// Stubs `POST /freeBusy` with a `calendars` map keyed by address.
  void stubFreeBusy(Map<String, dynamic> calendars) {
    when(mockDio.post<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      options: anyNamed('options'),
    )).thenAnswer((inv) async => Response(
          data: <String, dynamic>{'calendars': calendars},
          statusCode: 200,
          requestOptions:
              RequestOptions(path: inv.positionalArguments.first as String),
        ));
  }

  void stubFreeBusyError(int statusCode) {
    when(mockDio.post<Map<String, dynamic>>(
      any,
      data: anyNamed('data'),
      options: anyNamed('options'),
    )).thenThrow(DioException(
      requestOptions: RequestOptions(path: '/freeBusy'),
      response: Response(
        statusCode: statusCode,
        requestOptions: RequestOptions(path: '/freeBusy'),
      ),
    ));
  }

  setUp(() {
    mockDio = MockDio();
    final client = MockGoogleCalendarHttpClient();
    when(client.dio).thenReturn(mockDio);
    datasource = GoogleCalendarDatasourceImpl(
      client: client,
      accountEmail: 'me@example.com',
    );
  });

  Future<List<AttendeeAvailability>> query(List<String> emails) =>
      datasource.getAttendeesSchedule(
        emails: emails,
        start: _start,
        end: _end,
      );

  group('GoogleCalendarDatasourceImpl.getAttendeesSchedule', () {
    test('maps busy intervals to schedule items in UTC', () async {
      stubFreeBusy({
        'guest@example.com': {
          'busy': [
            {
              'start': '2026-07-27T09:00:00+10:00',
              'end': '2026-07-27T09:30:00+10:00',
            },
          ],
        },
      });

      final result = await query(['guest@example.com']);

      expect(result, hasLength(1));
      expect(result.single.email, 'guest@example.com');
      expect(result.single.status, AttendeeAvailabilityStatus.busy);
      expect(result.single.scheduleItems, hasLength(1));

      final item = result.single.scheduleItems.single;
      expect(item.start, DateTime.utc(2026, 7, 26, 23));
      expect(item.end, DateTime.utc(2026, 7, 26, 23, 30));
      expect(item.status, AttendeeAvailabilityStatus.busy);
      // Google's freeBusy discloses intervals only, never titles.
      expect(item.subject, isNull);
    });

    test('reports free when the calendar is visible and has no busy blocks',
        () async {
      stubFreeBusy({
        'guest@example.com': {'busy': <dynamic>[]},
      });

      final result = await query(['guest@example.com']);

      expect(result.single.status, AttendeeAvailabilityStatus.free);
      expect(result.single.scheduleItems, isEmpty);
    });

    test('reports unknown — not free — when the calendar returns errors',
        () async {
      // An address outside the domain, or one that does not share free/busy,
      // comes back with errors and an empty busy list. Reporting that as Free
      // would tell the organizer a guest is available when it is not known.
      stubFreeBusy({
        'outsider@other.com': {
          'busy': <dynamic>[],
          'errors': [
            {'domain': 'global', 'reason': 'notFound'},
          ],
        },
      });

      final result = await query(['outsider@other.com']);

      expect(result.single.status, AttendeeAvailabilityStatus.unknown);
      expect(result.single.scheduleItems, isEmpty);
    });

    test('reports unknown for an address missing from the response', () async {
      stubFreeBusy({});

      final result = await query(['ghost@example.com']);

      expect(result.single.status, AttendeeAvailabilityStatus.unknown);
    });

    test('returns one entry per requested address, in order', () async {
      stubFreeBusy({
        'b@example.com': {
          'busy': [
            {
              'start': '2026-07-27T09:00:00+10:00',
              'end': '2026-07-27T10:00:00+10:00',
            },
          ],
        },
        'a@example.com': {'busy': <dynamic>[]},
      });

      final result = await query(['a@example.com', 'b@example.com']);

      expect(result.map((a) => a.email), ['a@example.com', 'b@example.com']);
      expect(result.first.status, AttendeeAvailabilityStatus.free);
      expect(result.last.status, AttendeeAvailabilityStatus.busy);
    });

    test('degrades to unknown on 403 instead of throwing', () async {
      // Expected for an account authorised before calendar.freebusy was
      // requested: the stored token lacks the scope. The form must keep
      // working — the organizer just gets no availability until re-consent.
      stubFreeBusyError(403);

      final result = await query(['a@example.com', 'b@example.com']);

      expect(result, hasLength(2));
      expect(
        result.every((a) => a.status == AttendeeAvailabilityStatus.unknown),
        isTrue,
      );
    });

    test('propagates other HTTP failures', () async {
      stubFreeBusyError(500);

      expect(query(['a@example.com']), throwsA(isA<Exception>()));
    });

    test('skips malformed busy intervals rather than failing the query',
        () async {
      stubFreeBusy({
        'guest@example.com': {
          'busy': [
            {'start': '2026-07-27T09:00:00+10:00'}, // no end
            {
              'start': '2026-07-27T11:00:00+10:00',
              'end': '2026-07-27T11:30:00+10:00',
            },
          ],
        },
      });

      final result = await query(['guest@example.com']);

      expect(result.single.scheduleItems, hasLength(1));
      expect(result.single.scheduleItems.single.start,
          DateTime.utc(2026, 7, 27, 1));
    });
  });
}
