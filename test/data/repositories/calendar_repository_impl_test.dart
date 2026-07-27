import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/remote/calendar_remote_datasource.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/data/repositories/calendar_repository_impl.dart';
import 'package:nightmail/domain/entities/attendee_availability.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
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

  group('CalendarRepositoryImpl.checkAttendeesAvailability', () {
    // A 10:00–11:00 meeting on 10 Jun 2026 in the machine's own timezone — the
    // form supplies local wall-clock times, and picking one inside the working
    // day keeps these cases independent of where the tests run. Schedule blocks
    // are expressed as UTC offsets from it for the same reason.
    final meetingStart = DateTime(2026, 6, 10, 10);
    final meetingEnd = DateTime(2026, 6, 10, 11);

    /// Stubs the attendee free/busy call, and the organizer's own calendar as
    /// empty so only the attendee path is under test.
    void stubSchedules(List<AttendeeAvailability> schedules) {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenAnswer((_) async => []);
      when(mockDatasource.getAttendeesSchedule(
        emails: anyNamed('emails'),
        start: anyNamed('start'),
        end: anyNamed('end'),
      )).thenAnswer((_) async => schedules);
    }

    Future<List<AttendeeAvailability>> check({String? accountId}) async {
      final result = await repository.checkAttendeesAvailability(
        emails: const ['guest@example.com'],
        start: meetingStart,
        end: meetingEnd,
        accountId: accountId,
      );
      return result.getRight().toNullable()!;
    }

    test('queries the whole working day, not just the meeting window', () async {
      // The schedule pane draws 07:00–20:00, so it can only show blocks that
      // were fetched for that range.
      stubSchedules([]);

      await check();

      final captured = verify(mockDatasource.getAttendeesSchedule(
        emails: anyNamed('emails'),
        start: captureAnyNamed('start'),
        end: captureAnyNamed('end'),
      )).captured;

      expect((captured[0] as DateTime).toLocal().hour, 7);
      expect((captured[1] as DateTime).toLocal().hour, 20);
    });

    test('widens the window when the meeting falls outside 07:00–20:00',
        () async {
      stubSchedules([]);

      final early = DateTime(2026, 6, 10, 5, 30);
      await repository.checkAttendeesAvailability(
        emails: const ['guest@example.com'],
        start: early,
        end: early.add(const Duration(minutes: 30)),
      );

      final captured = verify(mockDatasource.getAttendeesSchedule(
        emails: anyNamed('emails'),
        start: captureAnyNamed('start'),
        end: captureAnyNamed('end'),
      )).captured;

      expect(captured[0], early);
      expect((captured[1] as DateTime).toLocal().hour, 20);
    });

    test('narrows a day-wide busy status to free when no block overlaps',
        () async {
      // Busy at 15:00 but the meeting is at 10:00 — the guest is free for it.
      stubSchedules([
        AttendeeAvailability(
          email: 'guest@example.com',
          status: AttendeeAvailabilityStatus.busy,
          scheduleItems: [
            AttendeeScheduleItem(
              start: meetingStart.toUtc().add(const Duration(hours: 5)),
              end: meetingStart.toUtc().add(const Duration(hours: 6)),
              status: AttendeeAvailabilityStatus.busy,
            ),
          ],
        ),
      ]);

      final result = await check();

      expect(result.single.status, AttendeeAvailabilityStatus.free);
      // The out-of-window block is still carried through for the pane to draw.
      expect(result.single.scheduleItems, hasLength(1));
    });

    test('keeps busy when a block does overlap the meeting', () async {
      stubSchedules([
        AttendeeAvailability(
          email: 'guest@example.com',
          status: AttendeeAvailabilityStatus.busy,
          scheduleItems: [
            AttendeeScheduleItem(
              start: meetingStart.toUtc().add(const Duration(minutes: 30)),
              end: meetingStart.toUtc().add(const Duration(minutes: 90)),
              status: AttendeeAvailabilityStatus.busy,
            ),
          ],
        ),
      ]);

      expect((await check()).single.status, AttendeeAvailabilityStatus.busy);
    });

    test('preserves unknown rather than reporting free', () async {
      // unknown means "we cannot see this mailbox". Having no blocks for that
      // reason must never be presented as availability.
      stubSchedules([
        const AttendeeAvailability(
          email: 'guest@example.com',
          status: AttendeeAvailabilityStatus.unknown,
        ),
      ]);

      expect((await check()).single.status, AttendeeAvailabilityStatus.unknown);
    });

    test('keeps a stated status when the provider gave no detail blocks',
        () async {
      // Exchange discloses free/busy without details for some guests. The
      // day-wide status is then all there is, and over-reporting a clash beats
      // claiming a guest is free.
      stubSchedules([
        const AttendeeAvailability(
          email: 'guest@example.com',
          status: AttendeeAvailabilityStatus.busy,
        ),
      ]);

      expect((await check()).single.status, AttendeeAvailabilityStatus.busy);
    });

    test('uses the active datasource when accountId is the active account',
        () async {
      stubSchedules([]);
      when(mockAccountManager.activeAccount).thenReturn(const MicrosoftAccount(
        id: 'acct-1',
        displayName: 'Work',
        emailAddress: 'me@example.com',
        tenantId: 'tenant',
      ));

      await check(accountId: 'acct-1');

      verifyNever(mockAccountManager.buildCalendarDatasourceForAccount(any));
      verify(mockAccountManager.calendarDatasource).called(greaterThan(0));
    });

    test('builds a datasource for a non-active account', () async {
      // The event window runs in its own engine and restores whichever account
      // was persisted as active, so a meeting created on another account must
      // not silently query the wrong mailbox.
      const other = MicrosoftAccount(
        id: 'acct-2',
        displayName: 'Other',
        emailAddress: 'other@example.com',
        tenantId: 'tenant',
      );
      when(mockAccountManager.activeAccount).thenReturn(const MicrosoftAccount(
        id: 'acct-1',
        displayName: 'Work',
        emailAddress: 'me@example.com',
        tenantId: 'tenant',
      ));
      when(mockAccountManager.accountById('acct-2')).thenReturn(other);
      when(mockAccountManager.buildCalendarDatasourceForAccount(other))
          .thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenAnswer((_) async => []);
      when(mockDatasource.getAttendeesSchedule(
        emails: anyNamed('emails'),
        start: anyNamed('start'),
        end: anyNamed('end'),
      )).thenAnswer((_) async => []);

      await check(accountId: 'acct-2');

      verify(mockAccountManager.buildCalendarDatasourceForAccount(other))
          .called(1);
    });
  });
}
