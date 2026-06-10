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
}
