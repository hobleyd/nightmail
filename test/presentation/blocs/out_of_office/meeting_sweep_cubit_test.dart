import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/annotations.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/usecases/cancel_calendar_event.dart';
import 'package:nightmail/domain/usecases/decline_calendar_event.dart';
import 'package:nightmail/domain/usecases/get_calendar_events.dart';
import 'package:nightmail/presentation/blocs/out_of_office/meeting_sweep_cubit.dart';
import 'package:nightmail/presentation/blocs/out_of_office/meeting_sweep_state.dart';

import 'meeting_sweep_cubit_test.mocks.dart';

final _windowStart = DateTime(2026, 3, 1);
final _windowEnd = DateTime(2026, 3, 7, 23, 59, 59);

CalendarEvent _accepted(String id) => CalendarEvent(
      id: id,
      subject: 'Accepted $id',
      start: DateTime(2026, 3, 2, 10),
      end: DateTime(2026, 3, 2, 11),
      isAllDay: false,
      participation: MeetingParticipation.accepted,
      isOrganizer: false,
    );

CalendarEvent _organized(String id) => CalendarEvent(
      id: id,
      subject: 'Organized $id',
      start: DateTime(2026, 3, 3, 14),
      end: DateTime(2026, 3, 3, 15),
      isAllDay: false,
      participation: MeetingParticipation.organizer,
      isOrganizer: true,
    );

CalendarEvent _tentative(String id) => CalendarEvent(
      id: id,
      subject: 'Tentative $id',
      start: DateTime(2026, 3, 4, 9),
      end: DateTime(2026, 3, 4, 10),
      isAllDay: false,
      participation: MeetingParticipation.tentative,
      isOrganizer: false,
    );

@GenerateMocks([GetCalendarEvents, DeclineCalendarEvent, CancelCalendarEvent])
void main() {
  late MockGetCalendarEvents mockGetEvents;
  late MockDeclineCalendarEvent mockDecline;
  late MockCancelCalendarEvent mockCancel;
  late MeetingSweepCubit cubit;

  setUp(() {
    // Mockito cannot auto-generate dummy values for sealed/abstract types
    // like Either, so we register one explicitly.
    provideDummy<Either<Failure, List<CalendarEvent>>>(const Right([]));
    provideDummy<Either<Failure, void>>(const Right(null));

    mockGetEvents = MockGetCalendarEvents();
    mockDecline = MockDeclineCalendarEvent();
    mockCancel = MockCancelCalendarEvent();
    cubit = MeetingSweepCubit(
      getCalendarEvents: mockGetEvents,
      declineCalendarEvent: mockDecline,
      cancelCalendarEvent: mockCancel,
    );
  });

  tearDown(() => cubit.close());

  Future<void> load(List<CalendarEvent> events) async {
    when(mockGetEvents(any)).thenAnswer((_) async => Right(events));
    await cubit.load(accountId: 'acct-1', start: _windowStart, end: _windowEnd);
  }

  group('load', () {
    test('passes the account id and window straight through', () async {
      when(mockGetEvents(any)).thenAnswer((_) async => const Right([]));

      await cubit.load(
        accountId: 'acct-1',
        start: _windowStart,
        end: _windowEnd,
      );

      final params = verify(mockGetEvents(captureAny)).captured.single
          as GetCalendarEventsParams;
      expect(params.accountId, 'acct-1');
      expect(params.startDateTime, _windowStart);
      expect(params.endDateTime, _windowEnd);
    });

    test('splits accepted invites from organized meetings', () async {
      await load([_accepted('e1'), _organized('e2')]);

      expect(cubit.state.status, MeetingSweepStatus.ready);
      expect(cubit.state.accepted.map((e) => e.id), ['e1']);
      expect(cubit.state.organized.map((e) => e.id), ['e2']);
    });

    test('a tentative (not accepted) invite is left out entirely', () async {
      await load([_tentative('e3')]);

      expect(cubit.state.status, MeetingSweepStatus.empty);
    });

    test('an organized meeting the user also organizes is never treated as '
        'accepted, even if participation says otherwise', () async {
      final weird = CalendarEvent(
        id: 'e4',
        subject: 'Odd',
        start: DateTime(2026, 3, 5),
        end: DateTime(2026, 3, 5, 1),
        isAllDay: false,
        participation: MeetingParticipation.accepted,
        isOrganizer: true,
      );

      await load([weird]);

      expect(cubit.state.accepted, isEmpty);
      expect(cubit.state.organized.map((e) => e.id), ['e4']);
    });

    test('accepted meetings start pre-selected; organized ones do not',
        () async {
      await load([_accepted('e1'), _organized('e2')]);

      expect(cubit.state.selectedIds, {'e1'});
    });

    test('nothing in the window reports "empty", not an error', () async {
      await load([]);

      expect(cubit.state.status, MeetingSweepStatus.empty);
    });

    test('a fetch failure is reported as an error', () async {
      when(mockGetEvents(any)).thenAnswer(
          (_) async => const Left(ServerFailure(message: 'offline')));

      await cubit.load(
        accountId: 'acct-1',
        start: _windowStart,
        end: _windowEnd,
      );

      expect(cubit.state.status, MeetingSweepStatus.error);
      expect(cubit.state.errorMessage, 'offline');
    });
  });

  group('toggle / selectAll', () {
    test('toggle flips one meeting\'s selection without touching the others',
        () async {
      await load([_accepted('e1'), _organized('e2')]);

      cubit.toggle('e2');
      expect(cubit.state.selectedIds, {'e1', 'e2'});

      cubit.toggle('e1');
      expect(cubit.state.selectedIds, {'e2'});
    });

    test('selectAll(true) selects every meeting; selectAll(false) clears it',
        () async {
      await load([_accepted('e1'), _organized('e2')]);

      cubit.selectAll(true);
      expect(cubit.state.selectedIds, {'e1', 'e2'});

      cubit.selectAll(false);
      expect(cubit.state.selectedIds, isEmpty);
    });

    test('toggling before a load has produced a ready state does nothing',
        () {
      cubit.toggle('e1');
      expect(cubit.state.status, MeetingSweepStatus.idle);
    });
  });

  group('confirm', () {
    test('declines only the selected accepted meetings and cancels only the '
        'selected organized ones, passing the load\'s account id', () async {
      await load([_accepted('e1'), _accepted('e2'), _organized('e3')]);
      // e1 and e2 start selected (both accepted); e3 starts unselected
      // (organized). Deselect e2 and opt e3 in, so both directions of the
      // selection are actually exercised rather than confirming the defaults.
      cubit.toggle('e2');
      cubit.toggle('e3');

      when(mockDecline(any)).thenAnswer((_) async => const Right(null));
      when(mockCancel(any)).thenAnswer((_) async => const Right(null));

      await cubit.confirm();

      expect(cubit.state.status, MeetingSweepStatus.done);
      expect(cubit.state.results, hasLength(2));
      expect(cubit.state.results.every((r) => r.succeeded), isTrue);

      final declineParams =
          verify(mockDecline(captureAny)).captured.cast<DeclineCalendarEventParams>();
      expect(declineParams.single.eventId, 'e1');
      expect(declineParams.single.accountId, 'acct-1');

      final cancelParams =
          verify(mockCancel(captureAny)).captured.cast<CancelCalendarEventParams>();
      expect(cancelParams.single.eventId, 'e3');
      expect(cancelParams.single.accountId, 'acct-1');
    });

    test('an unselected organized meeting is never cancelled', () async {
      await load([_organized('e1')]);
      // Organized meetings start unselected — confirm without toggling it in.

      await cubit.confirm();

      verifyNever(mockCancel(any));
      expect(cubit.state.results, isEmpty);
    });

    test('one failing meeting does not stop the rest', () async {
      // Both start selected — they're both accepted invites.
      await load([_accepted('e1'), _accepted('e2')]);

      when(mockDecline(argThat(predicate<DeclineCalendarEventParams>(
              (p) => p.eventId == 'e1'))))
          .thenAnswer(
              (_) async => const Left(ServerFailure(message: 'network')));
      when(mockDecline(argThat(predicate<DeclineCalendarEventParams>(
              (p) => p.eventId == 'e2'))))
          .thenAnswer((_) async => const Right(null));

      await cubit.confirm();

      expect(cubit.state.status, MeetingSweepStatus.done);
      expect(cubit.state.failedCount, 1);
      final byId = {for (final r in cubit.state.results) r.eventId: r};
      expect(byId['e1']!.succeeded, isFalse);
      expect(byId['e1']!.errorMessage, 'network');
      expect(byId['e2']!.succeeded, isTrue);
    });

    test('confirming with nothing selected reports done with no results',
        () async {
      await load([_accepted('e1')]);
      cubit.toggle('e1'); // deselect the only one

      await cubit.confirm();

      expect(cubit.state.status, MeetingSweepStatus.done);
      expect(cubit.state.results, isEmpty);
      verifyNever(mockDecline(any));
      verifyNever(mockCancel(any));
    });

    test('confirming before a load has produced a ready state does nothing',
        () async {
      await cubit.confirm();

      expect(cubit.state.status, MeetingSweepStatus.idle);
      verifyNever(mockDecline(any));
      verifyNever(mockCancel(any));
    });
  });
}
