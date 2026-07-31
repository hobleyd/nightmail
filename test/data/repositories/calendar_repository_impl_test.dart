import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:intl/intl.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/exceptions.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/data/datasources/remote/calendar_remote_datasource.dart';
import 'package:nightmail/data/datasources/remote/email_remote_datasource.dart';
import 'package:nightmail/data/models/calendar_event_model.dart';
import 'package:nightmail/data/repositories/calendar_repository_impl.dart';
import 'package:nightmail/domain/entities/attendee_availability.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/local_attachment.dart';
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

@GenerateMocks(
    [AccountManager, CalendarRemoteDatasource, EmailRemoteDatasource])
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
}
