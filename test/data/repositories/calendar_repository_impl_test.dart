import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:intl/intl.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/local/calendar_local_datasource.dart';
import 'package:nightmail/data/datasources/local/pending_calendar_operations_datasource.dart';
import 'package:nightmail/data/datasources/remote/calendar_remote_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/data/repositories/calendar_repository_impl.dart';
import 'package:nightmail/domain/entities/attendee_availability.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_event_attendee.dart';
import 'package:nightmail/domain/entities/local_attachment.dart';
import 'package:nightmail/domain/entities/meeting_forward.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';
import 'package:nightmail/domain/entities/meeting_room.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/sync/calendar_outbox_drain_service.dart';
import 'package:nightmail/infrastructure/sync/calendar_pending_op_reconciler.dart';

import 'calendar_repository_impl_test.mocks.dart';

/// Undoes RFC 5545 line folding, so an assertion about a property does not
/// depend on where the writer happened to break the line.
String _unfoldIcs(String ics) => ics.replaceAll(RegExp(r'\r?\n[ \t]'), '');

final _tStart = DateTime.utc(2026, 6, 9);
final _tEnd = DateTime.utc(2026, 6, 16);

final _tEventModel = CalendarEventModel(
  id: 'event-1',
  subject: 'Stand-up',
  start: DateTime.utc(2026, 6, 10, 9, 0),
  end: DateTime.utc(2026, 6, 10, 9, 15),
  isAllDay: false,
);

@GenerateMocks([
  AccountManager,
  CalendarRemoteDatasource,
  EmailRemoteDatasource,
  CalendarLocalDatasource,
  PendingCalendarOperationsDatasource,
  CalendarOutboxDrainService,
  CalendarPendingOpReconciler,
])
void main() {
  late CalendarRepositoryImpl repository;
  late MockAccountManager mockAccountManager;
  late MockCalendarRemoteDatasource mockDatasource;
  late MockCalendarLocalDatasource mockLocal;
  late MockPendingCalendarOperationsDatasource mockPendingOps;
  late MockCalendarOutboxDrainService mockDrain;
  late MockCalendarPendingOpReconciler mockReconciler;

  setUp(() {
    mockAccountManager = MockAccountManager();
    mockDatasource = MockCalendarRemoteDatasource();
    mockLocal = MockCalendarLocalDatasource();
    mockPendingOps = MockPendingCalendarOperationsDatasource();
    mockDrain = MockCalendarOutboxDrainService();
    mockReconciler = MockCalendarPendingOpReconciler();
    repository = CalendarRepositoryImpl(
      accountManager: mockAccountManager,
      localDatasource: mockLocal,
      pendingOperations: mockPendingOps,
      outboxDrainService: mockDrain,
      pendingOpReconciler: mockReconciler,
    );

    // Default: no active account and nothing cached, which is the combination
    // that sends every mutation down the network-first path. Tests of the
    // cache-first behaviour opt in via [givenCached]; the rest are unaffected.
    when(mockAccountManager.activeAccount).thenReturn(null);
    when(mockLocal.getCachedEventById(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
    )).thenAnswer((_) async => null);
    when(mockLocal.getCachedEventByICalUid(
      accountId: anyNamed('accountId'),
      iCalUid: anyNamed('iCalUid'),
    )).thenAnswer((_) async => null);
    when(mockLocal.getCachedEvents(
      accountId: anyNamed('accountId'),
      start: anyNamed('start'),
      end: anyNamed('end'),
    )).thenAnswer((_) async => const []);
    when(mockLocal.cacheEvents(
      accountId: anyNamed('accountId'),
      windowStart: anyNamed('windowStart'),
      windowEnd: anyNamed('windowEnd'),
      events: anyNamed('events'),
    )).thenAnswer((_) async {});
    when(mockLocal.upsertEvent(
      accountId: anyNamed('accountId'),
      event: anyNamed('event'),
    )).thenAnswer((_) async {});
    when(mockLocal.deleteEvent(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
    )).thenAnswer((_) async {});
    when(mockLocal.deleteSeries(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
      seriesMasterId: anyNamed('seriesMasterId'),
    )).thenAnswer((_) async {});
    when(mockPendingOps.enqueueCalendarOperation(
      accountId: anyNamed('accountId'),
      targetId: anyNamed('targetId'),
      opType: anyNamed('opType'),
      payload: anyNamed('payload'),
    )).thenAnswer((_) async => 1);
    when(mockDrain.drainForAccount(any)).thenAnswer((_) async {});
    when(mockReconciler.reconcile(
      accountId: anyNamed('accountId'),
      events: anyNamed('events'),
    )).thenAnswer((inv) async =>
        inv.namedArguments[const Symbol('events')] as List<CalendarEvent>);
  });

  /// Makes the repository see an active account with [cached] on its calendar.
  void givenCached(CalendarEvent cached) {
    when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
      id: 'acct-1',
      displayName: 'Test',
      emailAddress: 'me@example.com',
    ));
    when(mockLocal.getCachedEventById(
      accountId: anyNamed('accountId'),
      eventId: cached.id,
    )).thenAnswer((_) async => cached);
    when(mockLocal.getCachedEvents(
      accountId: anyNamed('accountId'),
      start: anyNamed('start'),
      end: anyNamed('end'),
    )).thenAnswer((_) async => [cached]);
    if (cached.iCalUid != null) {
      when(mockLocal.getCachedEventByICalUid(
        accountId: anyNamed('accountId'),
        iCalUid: cached.iCalUid!,
      )).thenAnswer((_) async => cached);
    }
  }

  /// The event handed to [CalendarLocalDatasource.upsertEvent].
  CalendarEvent capturedUpsert() => verify(mockLocal.upsertEvent(
        accountId: anyNamed('accountId'),
        event: captureAnyNamed('event'),
      )).captured.last as CalendarEvent;

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

    group('excluding the event being edited', () {
      /// Stubs the organizer's own calendar, with attendee free/busy empty so
      /// only the organizer path is under test.
      void stubOrganizer(List<CalendarEventModel> events) {
        when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
        when(mockDatasource.getCalendarEvents(
          startDateTime: anyNamed('startDateTime'),
          endDateTime: anyNamed('endDateTime'),
        )).thenAnswer((_) async => events);
        when(mockDatasource.getAttendeesSchedule(
          emails: anyNamed('emails'),
          start: anyNamed('start'),
          end: anyNamed('end'),
        )).thenAnswer((_) async => []);
      }

      Future<List<AttendeeAvailability>> checkExcluding({
        String? eventId,
        DateTime? exStart,
        DateTime? exEnd,
        String? organizerEmail,
      }) async {
        final result = await repository.checkAttendeesAvailability(
          emails: const ['guest@example.com'],
          start: meetingStart,
          end: meetingEnd,
          organizerEmail: organizerEmail,
          excludeEventId: eventId,
          excludeStart: exStart,
          excludeEnd: exEnd,
        );
        return result.getRight().toNullable()!;
      }

      AttendeeAvailability guestBusyAt(List<(DateTime, DateTime)> slots) =>
          AttendeeAvailability(
            email: 'guest@example.com',
            status: AttendeeAvailabilityStatus.busy,
            scheduleItems: [
              for (final (s, e) in slots)
                AttendeeScheduleItem(
                  start: s,
                  end: e,
                  status: AttendeeAvailabilityStatus.busy,
                ),
            ],
          );

      test("discounts a guest's own copy of the meeting being edited", () async {
        // The guest is busy for exactly this meeting and nothing else, so the
        // meeting does not clash with anything — it *is* the thing.
        stubSchedules([
          guestBusyAt([(meetingStart.toUtc(), meetingEnd.toUtc())]),
        ]);

        final result = await checkExcluding(
          eventId: 'event-1',
          exStart: meetingStart,
          exEnd: meetingEnd,
        );

        expect(result.single.status, AttendeeAvailabilityStatus.free);
        // Dropped from the blocks too, so the pane doesn't paint a red band
        // underneath the meeting's own overlay.
        expect(result.single.scheduleItems, isEmpty);
      });

      test('still reports a clash when the exclusion is not asked for',
          () async {
        stubSchedules([
          guestBusyAt([(meetingStart.toUtc(), meetingEnd.toUtc())]),
        ]);

        expect((await check()).single.status, AttendeeAvailabilityStatus.busy);
      });

      test("keeps the guest's other commitments in the same slot", () async {
        stubSchedules([
          guestBusyAt([
            (meetingStart.toUtc(), meetingEnd.toUtc()),
            (
              meetingStart.toUtc().add(const Duration(minutes: 30)),
              meetingEnd.toUtc().add(const Duration(minutes: 30)),
            ),
          ]),
        ]);

        final result = await checkExcluding(
          eventId: 'event-1',
          exStart: meetingStart,
          exEnd: meetingEnd,
        );

        expect(result.single.status, AttendeeAvailabilityStatus.busy);
        expect(result.single.scheduleItems, hasLength(1));
      });

      test('matches the excluded slot despite second-level rounding', () async {
        // Graph truncates these times to the second, so the guest's copy can
        // come back a few seconds off the stored bounds.
        stubSchedules([
          guestBusyAt([
            (
              meetingStart.toUtc().add(const Duration(seconds: 20)),
              meetingEnd.toUtc().subtract(const Duration(seconds: 20)),
            ),
          ]),
        ]);

        final result = await checkExcluding(
          eventId: 'event-1',
          exStart: meetingStart,
          exEnd: meetingEnd,
        );

        expect(result.single.status, AttendeeAvailabilityStatus.free);
      });

      test('keeps a shorter block that merely sits inside the meeting',
          () async {
        // A 15-minute call within the hour is a real conflict, not this
        // meeting — the slot match has to be tight enough to tell them apart.
        stubSchedules([
          guestBusyAt([
            (
              meetingStart.toUtc().add(const Duration(minutes: 15)),
              meetingStart.toUtc().add(const Duration(minutes: 30)),
            ),
          ]),
        ]);

        final result = await checkExcluding(
          eventId: 'event-1',
          exStart: meetingStart,
          exEnd: meetingEnd,
        );

        expect(result.single.status, AttendeeAvailabilityStatus.busy);
        expect(result.single.scheduleItems, hasLength(1));
      });

      test('cannot discount a stated status that came with no blocks',
          () async {
        // Nothing to match the meeting against, so the day-wide status stands.
        // Over-reporting a clash beats inventing availability.
        stubSchedules([
          const AttendeeAvailability(
            email: 'guest@example.com',
            status: AttendeeAvailabilityStatus.busy,
          ),
        ]);

        final result = await checkExcluding(
          eventId: 'event-1',
          exStart: meetingStart,
          exEnd: meetingEnd,
        );

        expect(result.single.status, AttendeeAvailabilityStatus.busy);
      });

      test("excludes the organizer's own copy by event id", () async {
        stubOrganizer([
          CalendarEventModel(
            id: 'event-1',
            subject: 'The meeting being edited',
            start: meetingStart.toUtc(),
            end: meetingEnd.toUtc(),
            isAllDay: false,
            status: CalendarEventStatus.busy,
          ),
          CalendarEventModel(
            id: 'event-2',
            subject: 'Something else entirely',
            start: meetingStart.toUtc().add(const Duration(hours: 5)),
            end: meetingEnd.toUtc().add(const Duration(hours: 5)),
            isAllDay: false,
            status: CalendarEventStatus.busy,
          ),
        ]);

        final result = await checkExcluding(
          eventId: 'event-1',
          exStart: meetingStart,
          exEnd: meetingEnd,
          organizerEmail: 'me@example.com',
        );

        final organizer = result.single;
        expect(organizer.email, 'me@example.com');
        expect(organizer.status, AttendeeAvailabilityStatus.free);
        expect(organizer.scheduleItems, hasLength(1));
        expect(organizer.scheduleItems.single.subject,
            'Something else entirely');
      });

      test('excludes every occurrence when a whole series is being edited',
          () async {
        // Editing the series master must discount its occurrences too, which
        // carry their own ids and point back via seriesMasterId.
        stubOrganizer([
          CalendarEventModel(
            id: 'occurrence-7',
            subject: 'Stand-up',
            start: meetingStart.toUtc(),
            end: meetingEnd.toUtc(),
            isAllDay: false,
            status: CalendarEventStatus.busy,
            seriesMasterId: 'series-1',
          ),
        ]);

        final result = await checkExcluding(
          eventId: 'series-1',
          exStart: meetingStart,
          exEnd: meetingEnd,
          organizerEmail: 'me@example.com',
        );

        expect(result.single.status, AttendeeAvailabilityStatus.free);
        expect(result.single.scheduleItems, isEmpty);
      });

      test("keeps the organizer's unrelated events when nothing is excluded",
          () async {
        stubOrganizer([
          CalendarEventModel(
            id: 'event-1',
            subject: 'Stand-up',
            start: meetingStart.toUtc(),
            end: meetingEnd.toUtc(),
            isAllDay: false,
            status: CalendarEventStatus.busy,
          ),
        ]);

        final result = await checkExcluding(organizerEmail: 'me@example.com');

        expect(result.single.status, AttendeeAvailabilityStatus.busy);
        expect(result.single.scheduleItems, hasLength(1));
      });
    });
  });

  group('CalendarRepositoryImpl.proposeNewTimeFromEmail', () {
    late MockEmailRemoteDatasource mockEmailDatasource;

    const invite = '''
BEGIN:VCALENDAR
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
UID:evt-1@example.com
SEQUENCE:2
SUMMARY:Quarterly review
ORGANIZER;CN="Dana Chen":mailto:dana@example.com
DTSTART:20260803T230000Z
DTEND:20260803T234500Z
END:VEVENT
END:VCALENDAR''';

    final newStart = DateTime.utc(2026, 8, 5, 1, 30);
    final newEnd = DateTime.utc(2026, 8, 5, 2, 0);

    setUp(() {
      mockEmailDatasource = MockEmailRemoteDatasource();
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockAccountManager.emailDatasource).thenReturn(mockEmailDatasource);
      when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
        id: 'acct-1',
        displayName: 'Sam Patel',
        emailAddress: 'sam@example.com',
      ));
      when(mockDatasource.proposeNewTimeFromEmail(
        emailId: anyNamed('emailId'),
        newStart: anyNamed('newStart'),
        newEnd: anyNamed('newEnd'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        userEmail: anyNamed('userEmail'),
        message: anyNamed('message'),
      )).thenAnswer((_) async {});
      when(mockEmailDatasource.replyToEmail(
        messageId: anyNamed('messageId'),
        comment: anyNamed('comment'),
        replyAll: anyNamed('replyAll'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async {});
    });

    Future<Either<Failure, void>> propose({
      String? icsData = invite,
      String? message,
    }) =>
        repository.proposeNewTimeFromEmail(
          emailId: 'msg-1',
          newStart: newStart,
          newEnd: newEnd,
          icsData: icsData,
          meetingStart: DateTime.utc(2026, 8, 3, 23),
          message: message,
        );

    /// The single reply the repository sent, as its captured named arguments.
    Map<Symbol, dynamic> capturedReply() {
      final call = verify(mockEmailDatasource.replyToEmail(
        messageId: captureAnyNamed('messageId'),
        comment: captureAnyNamed('comment'),
        toAddresses: captureAnyNamed('toAddresses'),
        newAttachments: captureAnyNamed('newAttachments'),
        bodyType: anyNamed('bodyType'),
        replyAll: anyNamed('replyAll'),
        ccAddresses: anyNamed('ccAddresses'),
      ));
      call.called(1);
      final captured = call.captured;
      return {
        #messageId: captured[0],
        #comment: captured[1],
        #toAddresses: captured[2],
        #newAttachments: captured[3],
      };
    }

    test('emails a COUNTER when the provider cannot propose natively',
        () async {
      // Regression: proposing from a Gmail account reached the organizer as a
      // bare decline, with the proposed time dropped entirely.
      when(mockDatasource.supportsNativeProposeNewTime).thenReturn(false);

      final result = await propose();

      expect(result.isRight(), isTrue);
      final reply = capturedReply();
      expect(reply[#messageId], 'msg-1');
      final attachments = reply[#newAttachments] as List<LocalAttachment>;
      expect(attachments, hasLength(1));
      expect(attachments.single.mimeType, contains('method=COUNTER'));
      final ics = utf8.decode(attachments.single.bytes);
      expect(ics, contains('METHOD:COUNTER'));
      expect(ics, contains('UID:evt-1@example.com'));
      expect(ics, contains('DTSTART:20260805T013000Z'));
      expect(ics, contains('DTEND:20260805T020000Z'));
    });

    test('sends no email when the provider proposes natively', () async {
      // Graph's own decline+proposedNewTime already reached the organizer; a
      // second, emailed proposal would double up.
      when(mockDatasource.supportsNativeProposeNewTime).thenReturn(true);

      final result = await propose();

      expect(result.isRight(), isTrue);
      verifyNever(mockEmailDatasource.replyToEmail(
        messageId: anyNamed('messageId'),
        comment: anyNamed('comment'),
        replyAll: anyNamed('replyAll'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      ));
    });

    test('addresses the reply to the ICS organizer, not the sender', () async {
      // An invite can be sent by a delegate or a room system; the RSVP and
      // counter belong to the organizer named in the ICS.
      when(mockDatasource.supportsNativeProposeNewTime).thenReturn(false);

      await propose();

      expect(capturedReply()[#toAddresses], ['dana@example.com']);
    });

    test('states the proposed time in the body for clients that ignore COUNTER',
        () async {
      when(mockDatasource.supportsNativeProposeNewTime).thenReturn(false);

      await propose();

      final body = capturedReply()[#comment] as String;
      expect(body, contains('Quarterly review'));
      expect(body, contains('Proposed:'));
      expect(body, contains('Originally:'));
      // The body is written in the sender's local zone, so assert on the
      // rendered local time rather than a fixed string.
      expect(body, contains(DateFormat('h:mm a').format(newStart.toLocal())));
    });

    test('includes the note in both the body and the COUNTER', () async {
      when(mockDatasource.supportsNativeProposeNewTime).thenReturn(false);

      await propose(message: 'Clashes with my flight');

      final reply = capturedReply();
      expect(reply[#comment], contains('Clashes with my flight'));
      final attachments = reply[#newAttachments] as List<LocalAttachment>;
      expect(utf8.decode(attachments.single.bytes),
          contains('COMMENT:Clashes with my flight'));
    });

    test('still emails the proposal when the invite has no ICS', () async {
      // No ICS means no counter can be built, but the organizer must still be
      // told a time was proposed. Falls back to replying to the sender.
      when(mockDatasource.supportsNativeProposeNewTime).thenReturn(false);

      final result = await propose(icsData: null);

      expect(result.isRight(), isTrue);
      final reply = capturedReply();
      expect(reply[#newAttachments], isEmpty);
      expect(reply[#toAddresses], isEmpty);
      expect(reply[#comment], contains('Proposed:'));
    });

    test('fails, naming the decline, when the reply cannot be sent', () async {
      // The invite is already declined by this point: reporting success would
      // leave the user believing a proposal they never sent had gone out.
      when(mockDatasource.supportsNativeProposeNewTime).thenReturn(false);
      when(mockEmailDatasource.replyToEmail(
        messageId: anyNamed('messageId'),
        comment: anyNamed('comment'),
        replyAll: anyNamed('replyAll'),
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenThrow(const ServerException(message: 'SMTP rejected'));

      final result = await propose();

      expect(result.isLeft(), isTrue);
      result.fold(
        (failure) {
          expect(failure, isA<ServerFailure>());
          expect(failure.message, contains('declined'));
          expect(failure.message, contains('SMTP rejected'));
        },
        (_) => fail('Expected Left'),
      );
    });
  });

  group('CalendarRepositoryImpl.acceptProposedTimeFromEmail', () {
    final newStart = DateTime.utc(2026, 8, 5, 1, 30);
    final newEnd = DateTime.utc(2026, 8, 5, 2, 0);
    final currentStart = DateTime.utc(2026, 8, 4, 1, 30);
    const icsData = 'BEGIN:VCALENDAR\r\nMETHOD:COUNTER\r\nEND:VCALENDAR';

    Future<Either<Failure, void>> accept() => repository.acceptProposedTimeFromEmail(
          emailId: 'msg-9',
          newStart: newStart,
          newEnd: newEnd,
          icsData: icsData,
          meetingStart: currentStart,
        );

    setUp(() {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.acceptProposedTimeFromEmail(
        emailId: anyNamed('emailId'),
        newStart: anyNamed('newStart'),
        newEnd: anyNamed('newEnd'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
      )).thenAnswer((_) async {});
    });

    test('forwards the proposed time and the locators to the datasource',
        () async {
      final result = await accept();

      expect(result.isRight(), isTrue);
      final call = verify(mockDatasource.acceptProposedTimeFromEmail(
        emailId: captureAnyNamed('emailId'),
        newStart: captureAnyNamed('newStart'),
        newEnd: captureAnyNamed('newEnd'),
        icsData: captureAnyNamed('icsData'),
        meetingStart: captureAnyNamed('meetingStart'),
      ));
      call.called(1);
      // The ICS and the *current* start are both locators: providers without
      // message-to-event navigation need one of them to find the meeting.
      expect(call.captured, ['msg-9', newStart, newEnd, icsData, currentStart]);
    });

    test('returns Left(ServerFailure) when calendarDatasource is null',
        () async {
      when(mockAccountManager.calendarDatasource).thenReturn(null);

      final result = await accept();

      expect(result.isLeft(), isTrue);
      result.fold(
        (failure) => expect(failure, isA<ServerFailure>()),
        (_) => fail('Expected Left'),
      );
    });

    test('maps AuthException to Left(AuthFailure)', () async {
      // Must stay an AuthFailure or the re-auth prompt never appears.
      when(mockDatasource.acceptProposedTimeFromEmail(
        emailId: anyNamed('emailId'),
        newStart: anyNamed('newStart'),
        newEnd: anyNamed('newEnd'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
      )).thenThrow(const AuthException(message: 'token expired'));

      final result = await accept();

      result.fold(
        (failure) {
          expect(failure, isA<AuthFailure>());
          expect(failure.message, 'token expired');
        },
        (_) => fail('Expected Left'),
      );
    });

    test('maps NetworkException to Left(NetworkFailure)', () async {
      when(mockDatasource.acceptProposedTimeFromEmail(
        emailId: anyNamed('emailId'),
        newStart: anyNamed('newStart'),
        newEnd: anyNamed('newEnd'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
      )).thenThrow(const NetworkException(message: 'offline'));

      final result = await accept();

      result.fold(
        (failure) => expect(failure, isA<NetworkFailure>()),
        (_) => fail('Expected Left'),
      );
    });

    test('surfaces the not-organizer refusal as a Left', () async {
      // Only the organizer can move a meeting; the message has to reach the UI
      // rather than the banner reporting a move that never happened.
      when(mockDatasource.acceptProposedTimeFromEmail(
        emailId: anyNamed('emailId'),
        newStart: anyNamed('newStart'),
        newEnd: anyNamed('newEnd'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
      )).thenThrow(const ServerException(
          message: 'You are not the organizer of this meeting',
          statusCode: 403));

      final result = await accept();

      expect(result.isLeft(), isTrue);
      result.fold(
        (failure) {
          expect(failure, isA<ServerFailure>());
          expect(failure.message, contains('not the organizer'));
          expect((failure as ServerFailure).statusCode, 403);
        },
        (_) => fail('Expected Left'),
      );
    });
  });

  // ---------------------------------------------------------------------------
  // Cache-first mutations
  // ---------------------------------------------------------------------------

  group('CalendarRepositoryImpl caches the fetched window', () {
    test('reconciles a fetch against queued ops before caching it', () async {
      when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
        id: 'acct-1',
        displayName: 'Test',
        emailAddress: 'me@example.com',
      ));
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenAnswer((_) async => [_tEventModel]);
      // A queued decline the server snapshot doesn't know about yet.
      final reconciled = _tEventModel.copyWith(
          participation: MeetingParticipation.declined);
      when(mockReconciler.reconcile(
        accountId: anyNamed('accountId'),
        events: anyNamed('events'),
      )).thenAnswer((_) async => [reconciled]);

      final result = await repository.getCalendarEvents(
        startDateTime: _tStart,
        endDateTime: _tEnd,
      );

      // The reconciled view is what the caller sees, not the raw response.
      result.fold(
        (_) => fail('Expected Right'),
        (events) =>
            expect(events.single.participation, MeetingParticipation.declined),
      );
      // …and it is what gets written, keyed to the window that was fetched.
      final captured = verify(mockLocal.cacheEvents(
        accountId: 'acct-1',
        windowStart: captureAnyNamed('windowStart'),
        windowEnd: captureAnyNamed('windowEnd'),
        events: captureAnyNamed('events'),
      )).captured;
      expect(captured[0], _tStart);
      expect(captured[1], _tEnd);
      expect((captured[2] as List<CalendarEvent>).single.participation,
          MeetingParticipation.declined);
    });

    test('does not cache when there is no active account', () async {
      when(mockAccountManager.activeAccount).thenReturn(null);
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockDatasource.getCalendarEvents(
        startDateTime: anyNamed('startDateTime'),
        endDateTime: anyNamed('endDateTime'),
      )).thenAnswer((_) async => [_tEventModel]);

      await repository.getCalendarEvents(
          startDateTime: _tStart, endDateTime: _tEnd);

      verifyNever(mockLocal.cacheEvents(
        accountId: anyNamed('accountId'),
        windowStart: anyNamed('windowStart'),
        windowEnd: anyNamed('windowEnd'),
        events: anyNamed('events'),
      ));
    });
  });

  group('CalendarRepositoryImpl.declineCalendarEvent', () {
    test('marks the cache declined and queues, without calling the provider',
        () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      givenCached(_tEventModel);

      final result = await repository.declineCalendarEvent(eventId: 'event-1');

      expect(result.isRight(), isTrue);
      expect(capturedUpsert().participation, MeetingParticipation.declined);
      verify(mockPendingOps.enqueueCalendarOperation(
        accountId: 'acct-1',
        targetId: 'event-1',
        opType: PendingCalendarOperationType.declineEvent,
        payload: anyNamed('payload'),
      )).called(1);
      verify(mockDrain.drainForAccount('acct-1')).called(1);
      verifyNever(mockDatasource.declineCalendarEvent(
        eventId: anyNamed('eventId'),
        userEmail: anyNamed('userEmail'),
      ));
    });

    test('falls back to the provider when the event is not cached', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
        id: 'acct-1',
        displayName: 'Test',
        emailAddress: 'me@example.com',
      ));
      when(mockDatasource.declineCalendarEvent(
        eventId: anyNamed('eventId'),
        userEmail: anyNamed('userEmail'),
      )).thenAnswer((_) async {});

      final result = await repository.declineCalendarEvent(eventId: 'nope');

      expect(result.isRight(), isTrue);
      verify(mockDatasource.declineCalendarEvent(
              eventId: 'nope', userEmail: 'me@example.com'))
          .called(1);
      verifyNever(mockPendingOps.enqueueCalendarOperation(
        accountId: anyNamed('accountId'),
        targetId: anyNamed('targetId'),
        opType: anyNamed('opType'),
        payload: anyNamed('payload'),
      ));
    });
  });

  group('CalendarRepositoryImpl.cancelCalendarEvent', () {
    test('drops the cached row and queues the cancellation', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      givenCached(_tEventModel);

      final result = await repository.cancelCalendarEvent(eventId: 'event-1');

      expect(result.isRight(), isTrue);
      verify(mockLocal.deleteEvent(accountId: 'acct-1', eventId: 'event-1'))
          .called(1);
      verify(mockPendingOps.enqueueCalendarOperation(
        accountId: 'acct-1',
        targetId: 'event-1',
        opType: PendingCalendarOperationType.cancelEvent,
        payload: anyNamed('payload'),
      )).called(1);
      verifyNever(mockDatasource.cancelCalendarEvent(
          eventId: anyNamed('eventId')));
    });

    test('cancelling a series drops every cached occurrence', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      givenCached(_tEventModel);

      await repository.cancelCalendarEventSeries(
        eventId: 'event-1',
        seriesMasterId: 'master-1',
        occurrenceStart: DateTime.utc(2026, 6, 10, 9),
      );

      verify(mockLocal.deleteSeries(
        accountId: 'acct-1',
        eventId: 'event-1',
        seriesMasterId: 'master-1',
      )).called(1);
    });
  });

  group('CalendarRepositoryImpl.respondToMeetingInvite', () {
    const ics = 'BEGIN:VCALENDAR\r\n'
        'BEGIN:VEVENT\r\n'
        'UID:meeting-uid-1\r\n'
        'SUMMARY:Stand-up\r\n'
        'DTSTART:20260610T090000Z\r\n'
        'DTEND:20260610T091500Z\r\n'
        'END:VEVENT\r\n'
        'END:VCALENDAR';

    test('accepting marks the copy found by iCalendar UID accepted', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      givenCached(_tEventModel.copyWith(iCalUid: 'meeting-uid-1'));

      final result = await repository.respondToMeetingInvite(
        emailId: 'mail-1',
        response: MeetingInviteResponseType.accept,
        icsData: ics,
      );

      expect(result.isRight(), isTrue);
      final upserted = capturedUpsert();
      expect(upserted.participation, MeetingParticipation.accepted);
      expect(upserted.status, CalendarEventStatus.busy);
      // Queued against the *email* id — that is all the provider is given.
      verify(mockPendingOps.enqueueCalendarOperation(
        accountId: 'acct-1',
        targetId: 'mail-1',
        opType: PendingCalendarOperationType.respondToInvite,
        payload: anyNamed('payload'),
      )).called(1);
      verifyNever(mockDatasource.respondToMeetingInvite(
        emailId: anyNamed('emailId'),
        response: anyNamed('response'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        userEmail: anyNamed('userEmail'),
        message: anyNamed('message'),
      ));
    });

    test('tentative sets a tentative free/busy status too', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      givenCached(_tEventModel.copyWith(iCalUid: 'meeting-uid-1'));

      await repository.respondToMeetingInvite(
        emailId: 'mail-1',
        response: MeetingInviteResponseType.tentative,
        icsData: ics,
      );

      final upserted = capturedUpsert();
      expect(upserted.participation, MeetingParticipation.tentative);
      expect(upserted.status, CalendarEventStatus.tentative);
    });

    test('with no ICS, matches an unambiguous start time', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      givenCached(_tEventModel);

      final result = await repository.respondToMeetingInvite(
        emailId: 'mail-1',
        response: MeetingInviteResponseType.accept,
        meetingStart: DateTime.utc(2026, 6, 10, 9, 0),
      );

      expect(result.isRight(), isTrue);
      expect(capturedUpsert().participation, MeetingParticipation.accepted);
    });

    test('two meetings at the same time are too ambiguous to patch', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
        id: 'acct-1',
        displayName: 'Test',
        emailAddress: 'me@example.com',
      ));
      when(mockLocal.getCachedEvents(
        accountId: anyNamed('accountId'),
        start: anyNamed('start'),
        end: anyNamed('end'),
      )).thenAnswer((_) async => [
            _tEventModel,
            _tEventModel.copyWith(id: 'event-2', subject: 'Other'),
          ]);
      when(mockDatasource.respondToMeetingInvite(
        emailId: anyNamed('emailId'),
        response: anyNamed('response'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        userEmail: anyNamed('userEmail'),
        message: anyNamed('message'),
      )).thenAnswer((_) async {});

      final result = await repository.respondToMeetingInvite(
        emailId: 'mail-1',
        response: MeetingInviteResponseType.accept,
        meetingStart: DateTime.utc(2026, 6, 10, 9, 0),
      );

      // Rather than move the wrong meeting, this waits for the provider.
      expect(result.isRight(), isTrue);
      verify(mockDatasource.respondToMeetingInvite(
        emailId: 'mail-1',
        response: MeetingInviteResponseType.accept,
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        userEmail: anyNamed('userEmail'),
        message: anyNamed('message'),
      )).called(1);
      verifyNever(mockLocal.upsertEvent(
        accountId: anyNamed('accountId'),
        event: anyNamed('event'),
      ));
    });
  });

  group('CalendarRepositoryImpl.updateCalendarEvent', () {
    test('rewrites the cached row from the save params and queues it', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      givenCached(_tEventModel.copyWith(
        iCalUid: 'meeting-uid-1',
        seriesMasterId: 'master-1',
        isOrganizer: true,
      ));

      final newStart = DateTime.utc(2026, 6, 11, 14, 0);
      final result = await repository.updateCalendarEvent(
        params: UpdateCalendarEventParams(
          id: 'event-1',
          subject: 'Stand-up (moved)',
          start: newStart,
          end: newStart.add(const Duration(minutes: 15)),
          isAllDay: false,
          timezone: 'Australia/Sydney',
        ),
      );

      expect(result.isRight(), isTrue);
      final optimistic = result.getOrElse((_) => fail('Expected Right'));
      expect(optimistic.start, newStart);
      expect(optimistic.subject, 'Stand-up (moved)');
      // Fields the params cannot carry survive the rewrite.
      expect(optimistic.iCalUid, 'meeting-uid-1');
      expect(optimistic.seriesMasterId, 'master-1');
      expect(optimistic.isOrganizer, isTrue);

      verify(mockPendingOps.enqueueCalendarOperation(
        accountId: 'acct-1',
        targetId: 'event-1',
        opType: PendingCalendarOperationType.updateEvent,
        payload: anyNamed('payload'),
      )).called(1);
      verifyNever(
          mockDatasource.updateCalendarEvent(params: anyNamed('params')));
    });

    test('an uncached event still goes to the provider for its real result',
        () async {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
        id: 'acct-1',
        displayName: 'Test',
        emailAddress: 'me@example.com',
      ));
      when(mockDatasource.updateCalendarEvent(params: anyNamed('params')))
          .thenAnswer((_) async => _tEventModel);

      final result = await repository.updateCalendarEvent(
        params: UpdateCalendarEventParams(
          id: 'not-cached',
          subject: 'x',
          start: _tStart,
          end: _tEnd,
          isAllDay: false,
          timezone: 'UTC',
        ),
      );

      expect(result.isRight(), isTrue);
      verify(mockDatasource.updateCalendarEvent(params: anyNamed('params')))
          .called(1);
      // Cached anyway, so the week it lands in has it next time.
      verify(mockLocal.upsertEvent(
        accountId: 'acct-1',
        event: anyNamed('event'),
      )).called(1);
    });
  });

  group('getMeetingRooms', () {
    const rooms = [
      MeetingRoom(email: 'boardroom@example.com', displayName: 'Boardroom'),
    ];

    void givenActiveAccount() {
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
        id: 'acct-1',
        displayName: 'Test',
        emailAddress: 'me@example.com',
      ));
    }

    test('returns the account\'s rooms', () async {
      givenActiveAccount();
      when(mockDatasource.getMeetingRooms()).thenAnswer((_) async => rooms);

      final result = await repository.getMeetingRooms();

      expect(result.getRight().toNullable(), rooms);
    });

    test('fetches once and serves the rest of the session from memory — the '
        'picker must open at typing speed, not at network speed', () async {
      givenActiveAccount();
      when(mockDatasource.getMeetingRooms()).thenAnswer((_) async => rooms);

      await repository.getMeetingRooms();
      await repository.getMeetingRooms();
      await repository.getMeetingRooms();

      verify(mockDatasource.getMeetingRooms()).called(1);
    });

    test('caches the in-flight future, so two forms opening at once make one '
        'request', () async {
      givenActiveAccount();
      when(mockDatasource.getMeetingRooms()).thenAnswer((_) async => rooms);

      await Future.wait([
        repository.getMeetingRooms(),
        repository.getMeetingRooms(),
      ]);

      verify(mockDatasource.getMeetingRooms()).called(1);
    });

    test('caches per account', () async {
      givenActiveAccount();
      when(mockAccountManager.accountById('acct-2'))
          .thenReturn(const GmailAccount(
        id: 'acct-2',
        displayName: 'Other',
        emailAddress: 'other@example.com',
      ));
      when(mockAccountManager
              .buildCalendarDatasourceForAccount(argThat(isNotNull)))
          .thenReturn(mockDatasource);
      when(mockDatasource.getMeetingRooms()).thenAnswer((_) async => rooms);

      await repository.getMeetingRooms(accountId: 'acct-1');
      await repository.getMeetingRooms(accountId: 'acct-2');

      verify(mockDatasource.getMeetingRooms()).called(2);
    });

    test('does not cache a failure — a room list that failed once must be '
        'retried, not dead for the session', () async {
      givenActiveAccount();
      var calls = 0;
      when(mockDatasource.getMeetingRooms()).thenAnswer((_) async {
        calls++;
        if (calls == 1) throw const ServerException(message: 'boom');
        return rooms;
      });

      final first = await repository.getMeetingRooms();
      final second = await repository.getMeetingRooms();

      expect(first.isLeft(), isTrue);
      expect(second.getRight().toNullable(), rooms);
    });

    test('an account type with no calendar answers with no rooms', () async {
      when(mockAccountManager.calendarDatasource).thenReturn(null);
      when(mockAccountManager.activeAccount).thenReturn(null);

      final result = await repository.getMeetingRooms();

      expect(result.getRight().toNullable(), isEmpty);
    });
  });

  group('CalendarRepositoryImpl.forwardMeetingFromEmail', () {
    late MockEmailRemoteDatasource mockEmailDatasource;

    const invite = '''
BEGIN:VCALENDAR
VERSION:2.0
METHOD:REQUEST
BEGIN:VEVENT
UID:evt-1@example.com
SEQUENCE:2
SUMMARY:Quarterly review
ORGANIZER;CN="Dana Chen":mailto:dana@example.com
ATTENDEE:mailto:sam@example.com
RRULE:FREQ=WEEKLY;BYDAY=MO
DTSTART:20260803T230000Z
DTEND:20260803T234500Z
END:VEVENT
END:VCALENDAR''';

    setUp(() {
      mockEmailDatasource = MockEmailRemoteDatasource();
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockAccountManager.emailDatasource).thenReturn(mockEmailDatasource);
      when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
        id: 'acct-1',
        displayName: 'Sam Patel',
        emailAddress: 'sam@example.com',
      ));
      when(mockEmailDatasource.sendEmail(
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async {});
    });

    void givenProviderForwards() {
      when(mockDatasource.forwardMeetingFromEmail(
        emailId: anyNamed('emailId'),
        toAddresses: anyNamed('toAddresses'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        comment: anyNamed('comment'),
      )).thenAnswer((_) async {});
    }

    void givenProviderRefuses() {
      when(mockDatasource.forwardMeetingFromEmail(
        emailId: anyNamed('emailId'),
        toAddresses: anyNamed('toAddresses'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        comment: anyNamed('comment'),
      )).thenThrow(const MeetingForwardUnsupportedException(
          message: 'guests may not invite others'));
    }

    Future<Either<Failure, MeetingForwardMode>> forward({
      List<String> to = const ['ravi@example.com'],
      String? icsData = invite,
      String? comment,
    }) =>
        repository.forwardMeetingFromEmail(
          emailId: 'msg-1',
          toAddresses: to,
          icsData: icsData,
          meetingStart: DateTime.utc(2026, 8, 3, 23),
          comment: comment,
        );

    /// The single message the repository sent, as its captured named arguments.
    Map<Symbol, dynamic> capturedSend() {
      final call = verify(mockEmailDatasource.sendEmail(
        toAddresses: captureAnyNamed('toAddresses'),
        subject: captureAnyNamed('subject'),
        body: captureAnyNamed('body'),
        newAttachments: captureAnyNamed('newAttachments'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
      ));
      call.called(1);
      final captured = call.captured;
      return {
        #toAddresses: captured[0],
        #subject: captured[1],
        #body: captured[2],
        #newAttachments: captured[3],
      };
    }

    test('lets the provider forward it, and sends nothing itself', () async {
      givenProviderForwards();

      final result = await forward(comment: 'You should be across this');

      expect(result.getRight().toNullable(),
          MeetingForwardMode.onBehalfOfOrganizer);
      verify(mockDatasource.forwardMeetingFromEmail(
        emailId: 'msg-1',
        toAddresses: ['ravi@example.com'],
        icsData: invite,
        meetingStart: anyNamed('meetingStart'),
        comment: 'You should be across this',
      )).called(1);
      verifyNever(mockEmailDatasource.sendEmail(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      ));
    });

    test('emails the invitation when the provider will not forward it',
        () async {
      givenProviderRefuses();

      final result = await forward();

      expect(result.getRight().toNullable(), MeetingForwardMode.fromMe);
      final sent = capturedSend();
      expect(sent[#toAddresses], ['ravi@example.com']);
      expect(sent[#subject], 'FW: Quarterly review');
    });

    test('attaches a METHOD=REQUEST part built from the invitation', () async {
      givenProviderRefuses();

      await forward();

      final attachments = capturedSend()[#newAttachments] as List<dynamic>;
      final ics = attachments.single as LocalAttachment;
      expect(ics.name, 'invite.ics');
      // The `method` parameter is what makes a client offer Accept/Decline
      // rather than show a file to save.
      expect(ics.mimeType, 'text/calendar; method=REQUEST');

      final text = _unfoldIcs(utf8.decode(ics.bytes));
      expect(text, contains('METHOD:REQUEST'));
      // Identifies the organizer's meeting, so the RSVP lands on it.
      expect(text, contains('UID:evt-1@example.com'));
      expect(text, contains('SEQUENCE:2'));
      expect(text, contains('ORGANIZER;CN="Dana Chen":mailto:dana@example.com'));
      expect(text, contains('mailto:ravi@example.com'));
      // The series is forwarded as a series, not as one occurrence.
      expect(text, contains('RRULE:FREQ=WEEKLY;BYDAY=MO'));
    });

    test('tells the recipient the organiser has not been told', () async {
      // Without this the recipient believes they are on the guest list, and
      // silently misses every later change to the meeting.
      givenProviderRefuses();

      await forward();

      expect(capturedSend()[#body], contains('have not been told'));
    });

    test('falls back to the cached meeting when there is no iCalendar part',
        () async {
      // Microsoft invitations arrive as eventMessages with no calendar part at
      // all, so the cached copy is the only description of the meeting.
      givenProviderRefuses();
      givenCached(CalendarEventModel(
        id: 'event-9',
        subject: 'Board meeting',
        start: DateTime.utc(2026, 8, 3, 23),
        end: DateTime.utc(2026, 8, 4),
        isAllDay: false,
        iCalUid: 'evt-9@example.com',
        organizerEmail: 'dana@example.com',
        organizerName: 'Dana Chen',
      ));

      final result = await forward(icsData: null);

      expect(result.getRight().toNullable(), MeetingForwardMode.fromMe);
      final attachments = capturedSend()[#newAttachments] as List<dynamic>;
      final text =
          _unfoldIcs(utf8.decode((attachments.single as LocalAttachment).bytes));
      expect(text, contains('UID:evt-9@example.com'));
      expect(text, contains('mailto:dana@example.com'));
    });

    test('reports a failure when the meeting cannot be described at all',
        () async {
      givenProviderRefuses();

      final result = await forward(icsData: null);

      expect(result.isLeft(), isTrue);
      verifyNever(mockEmailDatasource.sendEmail(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      ));
    });

    test('does not email a copy when the provider forward failed outright',
        () async {
      // The provider may have forwarded it before failing, so following up with
      // an emailed copy would invite the recipient twice. Only a settled
      // "cannot forward this" reaches the fallback.
      when(mockDatasource.forwardMeetingFromEmail(
        emailId: anyNamed('emailId'),
        toAddresses: anyNamed('toAddresses'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        comment: anyNamed('comment'),
      )).thenThrow(const ServerException(message: 'boom', statusCode: 500));

      final result = await forward();

      expect(result.isLeft(), isTrue);
      verifyNever(mockEmailDatasource.sendEmail(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      ));
    });

    test('an expired token stays an AuthFailure', () async {
      // Falling back here would quietly change how the meeting is sent instead
      // of raising the re-auth prompt.
      when(mockDatasource.forwardMeetingFromEmail(
        emailId: anyNamed('emailId'),
        toAddresses: anyNamed('toAddresses'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        comment: anyNamed('comment'),
      )).thenThrow(const AuthException(message: 'expired'));

      final result = await forward();

      expect(result.getLeft().toNullable(), isA<AuthFailure>());
    });

    test('emails the invitation when the account has no calendar at all',
        () async {
      // An IMAP account: nothing to ask, so it goes straight to the fallback.
      when(mockAccountManager.calendarDatasource).thenReturn(null);

      final result = await forward();

      expect(result.getRight().toNullable(), MeetingForwardMode.fromMe);
      expect(capturedSend()[#subject], 'FW: Quarterly review');
    });

    test('refuses an empty recipient list without calling anything', () async {
      givenProviderForwards();

      final result = await forward(to: const ['', '   ']);

      expect(result.isLeft(), isTrue);
      verifyNever(mockDatasource.forwardMeetingFromEmail(
        emailId: anyNamed('emailId'),
        toAddresses: anyNamed('toAddresses'),
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        comment: anyNamed('comment'),
      ));
    });

    test('de-duplicates recipients before sending', () async {
      givenProviderForwards();

      await forward(to: const ['ravi@example.com', 'Ravi@Example.com ']);

      verify(mockDatasource.forwardMeetingFromEmail(
        emailId: anyNamed('emailId'),
        toAddresses: ['ravi@example.com'],
        icsData: anyNamed('icsData'),
        meetingStart: anyNamed('meetingStart'),
        comment: anyNamed('comment'),
      )).called(1);
    });
  });

  group('CalendarRepositoryImpl.forwardCalendarEvent', () {
    late MockEmailRemoteDatasource mockEmailDatasource;

    final event = CalendarEventModel(
      id: 'event-1',
      subject: 'Quarterly review',
      start: DateTime.utc(2026, 8, 3, 23),
      end: DateTime.utc(2026, 8, 3, 23, 45),
      isAllDay: false,
      iCalUid: 'evt-1@example.com',
      organizerEmail: 'dana@example.com',
      organizerName: 'Dana Chen',
      attendees: const [
        CalendarEventAttendee(email: 'sam@example.com'),
        CalendarEventAttendee(email: 'room-3@example.com', isResource: true),
      ],
    );

    setUp(() {
      mockEmailDatasource = MockEmailRemoteDatasource();
      when(mockAccountManager.calendarDatasource).thenReturn(mockDatasource);
      when(mockAccountManager.emailDatasource).thenReturn(mockEmailDatasource);
      when(mockEmailDatasource.sendEmail(
        toAddresses: anyNamed('toAddresses'),
        ccAddresses: anyNamed('ccAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        bodyType: anyNamed('bodyType'),
        newAttachments: anyNamed('newAttachments'),
      )).thenAnswer((_) async {});
    });

    test('lets the provider forward it', () async {
      when(mockDatasource.forwardCalendarEvent(
        eventId: anyNamed('eventId'),
        toAddresses: anyNamed('toAddresses'),
        comment: anyNamed('comment'),
      )).thenAnswer((_) async {});

      final result = await repository.forwardCalendarEvent(
        eventId: 'event-1',
        toAddresses: const ['ravi@example.com'],
      );

      expect(result.getRight().toNullable(),
          MeetingForwardMode.onBehalfOfOrganizer);
    });

    test('emails the cached meeting when the provider will not', () async {
      when(mockDatasource.forwardCalendarEvent(
        eventId: anyNamed('eventId'),
        toAddresses: anyNamed('toAddresses'),
        comment: anyNamed('comment'),
      )).thenThrow(const MeetingForwardUnsupportedException(
          message: 'no forward API'));
      givenCached(event);

      final result = await repository.forwardCalendarEvent(
        eventId: 'event-1',
        toAddresses: const ['ravi@example.com'],
      );

      expect(result.getRight().toNullable(), MeetingForwardMode.fromMe);
      final call = verify(mockEmailDatasource.sendEmail(
        toAddresses: anyNamed('toAddresses'),
        subject: anyNamed('subject'),
        body: anyNamed('body'),
        newAttachments: captureAnyNamed('newAttachments'),
        ccAddresses: anyNamed('ccAddresses'),
        bodyType: anyNamed('bodyType'),
      ));
      call.called(1);
      final attachments = call.captured.single as List<dynamic>;
      final text =
          _unfoldIcs(utf8.decode((attachments.single as LocalAttachment).bytes));
      expect(text, contains('UID:evt-1@example.com'));
      expect(text, contains('mailto:ravi@example.com'));
      expect(text, contains('mailto:sam@example.com'));
      // A booked room is the organizer's reservation, not a guest to list.
      expect(text, isNot(contains('room-3@example.com')));
    });

    test('fetches the meeting when it is not in the cache', () async {
      // The cache keeps only a few weeks warm, and a meeting further out is
      // exactly the kind somebody forwards.
      when(mockDatasource.forwardCalendarEvent(
        eventId: anyNamed('eventId'),
        toAddresses: anyNamed('toAddresses'),
        comment: anyNamed('comment'),
      )).thenThrow(const MeetingForwardUnsupportedException(
          message: 'no forward API'));
      when(mockAccountManager.activeAccount).thenReturn(const GmailAccount(
        id: 'acct-1',
        displayName: 'Test',
        emailAddress: 'me@example.com',
      ));
      when(mockDatasource.getCalendarEvent(id: 'event-1'))
          .thenAnswer((_) async => event);

      final result = await repository.forwardCalendarEvent(
        eventId: 'event-1',
        toAddresses: const ['ravi@example.com'],
      );

      expect(result.getRight().toNullable(), MeetingForwardMode.fromMe);
      verify(mockDatasource.getCalendarEvent(id: 'event-1')).called(1);
    });
  });
}
