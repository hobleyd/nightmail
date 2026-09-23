import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';
import 'package:nightmail/domain/usecases/propose_new_time.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';
import 'package:nightmail/presentation/blocs/event_edit/event_edit_bloc.dart';
import 'package:nightmail/presentation/blocs/event_edit/event_edit_event.dart';
import 'package:nightmail/presentation/blocs/event_edit/event_edit_state.dart';

import 'event_edit_bloc_test.mocks.dart';

final _start = DateTime(2026, 4, 1, 10);
final _end = DateTime(2026, 4, 1, 11);

CalendarEvent _savedEvent(String id) => CalendarEvent(
      id: id,
      subject: 'Planning',
      start: _start,
      end: _end,
      isAllDay: false,
    );

EventEditSubmitted _newEventSubmitted({int? reminderMinutes}) =>
    EventEditSubmitted(
      subject: 'Planning',
      start: _start,
      end: _end,
      isAllDay: false,
      timezone: 'Australia/Sydney',
      reminderMinutes: reminderMinutes,
    );

EventEditSubmitted _updateSubmitted({int? reminderMinutes}) =>
    EventEditSubmitted(
      id: 'event-1',
      subject: 'Planning',
      start: _start,
      end: _end,
      isAllDay: false,
      timezone: 'Australia/Sydney',
      reminderMinutes: reminderMinutes,
    );

@GenerateMocks([
  CreateCalendarEvent,
  UpdateCalendarEvent,
  ProposeNewTime,
  NotificationService,
])
void main() {
  late MockCreateCalendarEvent mockCreate;
  late MockUpdateCalendarEvent mockUpdate;
  late MockProposeNewTime mockPropose;
  late MockNotificationService mockNotifications;

  setUp(() {
    provideDummy<Either<Failure, CalendarEvent>>(Right(_savedEvent('x')));
    provideDummy<Either<Failure, void>>(const Right(null));
    mockCreate = MockCreateCalendarEvent();
    mockUpdate = MockUpdateCalendarEvent();
    mockPropose = MockProposeNewTime();
    mockNotifications = MockNotificationService();
    // Fire-and-forget calls from _onSubmitted — stub unconditionally so an
    // unstubbed call doesn't throw MissingStubError; tests verify() the ones
    // they care about.
    when(mockNotifications.scheduleEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
      eventTitle: anyNamed('eventTitle'),
      startUtc: anyNamed('startUtc'),
      reminderMinutes: anyNamed('reminderMinutes'),
      startIso: anyNamed('startIso'),
    )).thenAnswer((_) async {});
    when(mockNotifications.cancelEventReminder(
      accountId: anyNamed('accountId'),
      eventId: anyNamed('eventId'),
    )).thenAnswer((_) async {});
  });

  EventEditBloc makeBloc({String? accountId = 'acct-1'}) => EventEditBloc(
        createCalendarEvent: mockCreate,
        updateCalendarEvent: mockUpdate,
        proposeNewTime: mockPropose,
        notificationService: mockNotifications,
        accountId: accountId,
      );

  test('starts in EventEditInitial', () {
    final bloc = makeBloc();
    addTearDown(bloc.close);
    expect(bloc.state, const EventEditInitial());
  });

  group('a new event (no id)', () {
    test('creates it and moves through Saving to Saved', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockCreate(any)).thenAnswer((_) async => Right(_savedEvent('e1')));

      bloc.add(_newEventSubmitted());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const EventEditSaving(),
          isA<EventEditSaved>()
              .having((s) => s.event.id, 'event.id', 'e1'),
        ]),
      );
      verifyNever(mockUpdate(any));
    });

    test('schedules a reminder when one was asked for and an account id is '
        'known', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockCreate(any)).thenAnswer((_) async => Right(_savedEvent('e1')));

      bloc.add(_newEventSubmitted(reminderMinutes: 15));
      await bloc.stream.firstWhere((s) => s is EventEditSaved);

      verify(mockNotifications.scheduleEventReminder(
        accountId: 'acct-1',
        eventId: 'e1',
        eventTitle: 'Planning',
        startUtc: _start,
        reminderMinutes: 15,
        startIso: _start.toIso8601String(),
      )).called(1);
    });

    test('schedules no reminder when none was asked for', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockCreate(any)).thenAnswer((_) async => Right(_savedEvent('e1')));

      bloc.add(_newEventSubmitted());
      await bloc.stream.firstWhere((s) => s is EventEditSaved);

      verifyNever(mockNotifications.scheduleEventReminder(
        accountId: anyNamed('accountId'),
        eventId: anyNamed('eventId'),
        eventTitle: anyNamed('eventTitle'),
        startUtc: anyNamed('startUtc'),
        reminderMinutes: anyNamed('reminderMinutes'),
        startIso: anyNamed('startIso'),
      ));
    });

    test('schedules nothing when the account id is unknown, even with a '
        'reminder requested', () async {
      final bloc = makeBloc(accountId: null);
      addTearDown(bloc.close);
      when(mockCreate(any)).thenAnswer((_) async => Right(_savedEvent('e1')));

      bloc.add(_newEventSubmitted(reminderMinutes: 15));
      await bloc.stream.firstWhere((s) => s is EventEditSaved);

      verifyNever(mockNotifications.scheduleEventReminder(
        accountId: anyNamed('accountId'),
        eventId: anyNamed('eventId'),
        eventTitle: anyNamed('eventTitle'),
        startUtc: anyNamed('startUtc'),
        reminderMinutes: anyNamed('reminderMinutes'),
        startIso: anyNamed('startIso'),
      ));
    });

    test('a failure reports EventEditError with the failure message',
        () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockCreate(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'no calendar')));

      bloc.add(_newEventSubmitted());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const EventEditSaving(),
          const EventEditError(message: 'no calendar'),
        ]),
      );
    });
  });

  group('an existing event (id given)', () {
    test('updates it and moves through Saving to Saved', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockUpdate(any))
          .thenAnswer((_) async => Right(_savedEvent('event-1')));

      bloc.add(_updateSubmitted());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const EventEditSaving(),
          isA<EventEditSaved>()
              .having((s) => s.event.id, 'event.id', 'event-1'),
        ]),
      );
      verifyNever(mockCreate(any));
    });

    test('cancels any existing reminder before scheduling a new one',
        () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockUpdate(any))
          .thenAnswer((_) async => Right(_savedEvent('event-1')));

      bloc.add(_updateSubmitted(reminderMinutes: 30));
      await bloc.stream.firstWhere((s) => s is EventEditSaved);

      verifyInOrder([
        mockNotifications.cancelEventReminder(
            accountId: 'acct-1', eventId: 'event-1'),
        mockNotifications.scheduleEventReminder(
          accountId: 'acct-1',
          eventId: 'event-1',
          eventTitle: 'Planning',
          startUtc: _start,
          reminderMinutes: 30,
          startIso: _start.toIso8601String(),
        ),
      ]);
    });

    test('cancels the existing reminder and schedules nothing when none is '
        'requested any more', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockUpdate(any))
          .thenAnswer((_) async => Right(_savedEvent('event-1')));

      bloc.add(_updateSubmitted());
      await bloc.stream.firstWhere((s) => s is EventEditSaved);

      verify(mockNotifications.cancelEventReminder(
              accountId: 'acct-1', eventId: 'event-1'))
          .called(1);
      verifyNever(mockNotifications.scheduleEventReminder(
        accountId: anyNamed('accountId'),
        eventId: anyNamed('eventId'),
        eventTitle: anyNamed('eventTitle'),
        startUtc: anyNamed('startUtc'),
        reminderMinutes: anyNamed('reminderMinutes'),
        startIso: anyNamed('startIso'),
      ));
    });

    test('a failure reports EventEditError with the failure message',
        () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockUpdate(any))
          .thenAnswer((_) async => const Left(ServerFailure(message: 'nope')));

      bloc.add(_updateSubmitted());

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const EventEditSaving(),
          const EventEditError(message: 'nope'),
        ]),
      );
    });
  });

  group('a counter-proposal', () {
    final proposal = EventEditProposeSubmitted(
      eventId: 'event-1',
      newStart: _start,
      newEnd: _end,
      timezone: 'Australia/Sydney',
      message: 'Any chance of the afternoon?',
    );

    test('sends it and moves through Saving to Proposed, saving nothing',
        () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockPropose(any)).thenAnswer((_) async => const Right(null));

      bloc.add(proposal);

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const EventEditSaving(),
          const EventEditProposed(eventId: 'event-1'),
        ]),
      );
      verify(mockPropose(ProposeNewTimeParams(
        eventId: 'event-1',
        newStart: _start,
        newEnd: _end,
        timezone: 'Australia/Sydney',
        message: 'Any chance of the afternoon?',
      ))).called(1);
      verifyNever(mockCreate(any));
      verifyNever(mockUpdate(any));
      // Only the organizer can move the meeting, so there is no reminder to
      // move either.
      verifyNever(mockNotifications.cancelEventReminder(
        accountId: anyNamed('accountId'),
        eventId: anyNamed('eventId'),
      ));
    });

    test('reports a failure', () async {
      final bloc = makeBloc();
      addTearDown(bloc.close);
      when(mockPropose(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'boom')));

      bloc.add(proposal);

      await expectLater(
        bloc.stream,
        emitsInOrder([
          const EventEditSaving(),
          const EventEditError(message: 'boom'),
        ]),
      );
    });
  });
}
