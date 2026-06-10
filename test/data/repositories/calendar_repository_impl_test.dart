import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/remote/calendar_remote_datasource.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/data/repositories/calendar_repository_impl.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';

import 'calendar_repository_impl_test.mocks.dart';

final _tStart = DateTime.utc(2026, 6, 9);
final _tEnd = DateTime.utc(2026, 6, 16);

final _tEventModel = CalendarEventModel(
  id: 'event-1',
  subject: 'Stand-up',
  start: DateTime.utc(2026, 6, 10, 9, 0),
  end: DateTime.utc(2026, 6, 10, 9, 15),
  isAllDay: false,
);

@GenerateMocks([AccountManager, CalendarRemoteDatasource])
void main() {
  late CalendarRepositoryImpl repository;
  late MockAccountManager mockAccountManager;
  late MockCalendarRemoteDatasource mockDatasource;

  setUp(() {
    mockAccountManager = MockAccountManager();
    mockDatasource = MockCalendarRemoteDatasource();
    repository = CalendarRepositoryImpl(accountManager: mockAccountManager);
  });

  group('CalendarRepositoryImpl.getCalendarEvents', () {
    test('returns Right(events) on success', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenAnswer((_) async => [_tEventModel]);

      final result = await repository.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      expect(result.isRight(), isTrue);
      result.fold(
        (_) => fail('Expected Right'),
        (events) {
          expect(events.length, 1);
          expect(events.first.id, 'event-1');
        },
      );
    });

    test('returns Left(ServerFailure) when calendarDatasource is null', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(null);

      final result = await repository.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      expect(result, isA<Left<dynamic, dynamic>>());
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Expected Left'),
      );
    });

    test('maps AuthException to Left(AuthFailure)', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenThrow(const AuthException(message: 'Token expired'));

      final result = await repository.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      result.fold(
        (failure) {
          expect(failure, isA<AuthFailure>());
          expect(failure.message, 'Token expired');
        },
        (_) => fail('Expected Left'),
      );
    });

    test('maps NetworkException to Left(NetworkFailure)', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenThrow(const NetworkException(message: 'No internet'));

      final result = await repository.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      result.fold(
        (failure) {
          expect(failure, isA<NetworkFailure>());
          expect(failure.message, 'No internet');
        },
        (_) => fail('Expected Left'),
      );
    });

    test('maps ServerException to Left(ServerFailure) with status code', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenThrow(const ServerException(
        message: 'The OData query option is not supported.',
        statusCode: 400,
      ));

      final result = await repository.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      result.fold(
        (failure) {
          expect(failure, isA<ServerFailure>());
          expect((failure as ServerFailure).statusCode, 400);
        },
        (_) => fail('Expected Left'),
      );
    });

    test('returns empty Right([]) when datasource returns no events', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenAnswer((_) async => []);

      final result = await repository.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      expect(result.isRight(), isTrue);
      result.fold((_) => fail('Expected Right'), (events) => expect(events, isEmpty));
    });
  });
}
