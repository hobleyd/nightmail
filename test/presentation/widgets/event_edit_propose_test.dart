import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/attendee_availability.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_event_attendee.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/repositories/calendar_repository.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/domain/usecases/check_attendees_availability.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';
import 'package:nightmail/domain/usecases/propose_new_time.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/event_edit/event_edit_bloc.dart';
import 'package:nightmail/presentation/blocs/event_edit/event_edit_state.dart';
import 'package:nightmail/presentation/widgets/event_edit_dialog.dart';

// The event form's counter-proposal mode (`EventEditForm.proposeNewTime`),
// which replaced the calendar's two pickers-only "Propose New Time" dialogs.
// What those could not do, and what this pins: the guests' free/busy is
// fetched for the slot being proposed, and the proposal goes out through the
// form's own bloc with the times shown.

const _account = MicrosoftAccount(
  id: 'acct-1',
  displayName: 'Work',
  emailAddress: 'me@example.com',
  tenantId: 'tenant',
);

class _FakeAccountManager extends Fake implements AccountManager {
  @override
  Account? accountById(String? id) => id == _account.id ? _account : null;

  @override
  Account? get activeAccount => _account;
}

class _FakeCreateCalendarEvent extends Fake implements CreateCalendarEvent {}

class _FakeUpdateCalendarEvent extends Fake implements UpdateCalendarEvent {}

class _FakeNotificationService extends Fake implements NotificationService {}

class _FakeSystemContacts extends Fake implements SystemContactsRepository {
  @override
  Future<void> warmUp() async {}

  @override
  Future<List<ContactSuggestion>> search(String query) async => const [];
}

/// Records the free/busy queries and the counter-proposals the form makes.
class _RecordingCalendarRepository extends Fake implements CalendarRepository {
  final availabilityCalls = <_AvailabilityCall>[];
  final proposals = <_Proposal>[];
  List<AttendeeAvailability> availabilities = const [];
  Failure? proposeFailure;

  @override
  Future<Either<Failure, List<AttendeeAvailability>>>
      checkAttendeesAvailability({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
    String? organizerEmail,
    String? accountId,
    String? excludeEventId,
    DateTime? excludeStart,
    DateTime? excludeEnd,
  }) async {
    availabilityCalls.add(_AvailabilityCall(
      emails: emails,
      start: start,
      end: end,
      organizerEmail: organizerEmail,
      excludeEventId: excludeEventId,
    ));
    return Right(availabilities);
  }

  @override
  Future<Either<Failure, void>> proposeNewTime({
    required String eventId,
    required DateTime newStart,
    required DateTime newEnd,
    String? timezone,
    String? message,
    String? accountId,
  }) async {
    proposals.add(_Proposal(
      eventId: eventId,
      newStart: newStart,
      newEnd: newEnd,
      timezone: timezone,
      message: message,
    ));
    final f = proposeFailure;
    return f != null ? Left(f) : const Right(null);
  }
}

class _AvailabilityCall {
  _AvailabilityCall({
    required this.emails,
    required this.start,
    required this.end,
    this.organizerEmail,
    this.excludeEventId,
  });
  final List<String> emails;
  final DateTime start;
  final DateTime end;
  final String? organizerEmail;
  final String? excludeEventId;
}

class _Proposal {
  _Proposal({
    required this.eventId,
    required this.newStart,
    required this.newEnd,
    this.timezone,
    this.message,
  });
  final String eventId;
  final DateTime newStart;
  final DateTime newEnd;
  final String? timezone;
  final String? message;
}

// Local wall-clock, as the form reads and draws them.
final _start = DateTime(2026, 6, 10, 10);
final _end = DateTime(2026, 6, 10, 11);

/// Somebody else's meeting, with this account among the guests — the shape
/// an invitation has once it is on the calendar.
CalendarEvent _theirMeeting({bool isAllDay = false}) => CalendarEvent(
      id: 'event-1',
      subject: 'Design review',
      start: _start,
      end: _end,
      isAllDay: isAllDay,
      isOrganizer: false,
      organizerEmail: 'boss@example.com',
      attendees: const [
        CalendarEventAttendee(email: 'guest@example.com'),
        CalendarEventAttendee(email: 'me@example.com'),
      ],
    );

void main() {
  late _RecordingCalendarRepository repository;
  late EventEditBloc bloc;

  setUp(() {
    repository = _RecordingCalendarRepository();
    sl.registerSingleton<AccountManager>(_FakeAccountManager());
    sl.registerSingleton<SystemContactsRepository>(_FakeSystemContacts());
  });

  tearDown(() => sl.reset());

  Future<void> pumpForm(
    WidgetTester tester, {
    required CalendarEvent event,
    bool proposeNewTime = true,
    DateTime? initialStart,
    DateTime? initialEnd,
  }) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        // Built here, inside the test's zone, so the bloc's awaits run under
        // pumpAndSettle rather than on the real event loop.
        body: BlocProvider<EventEditBloc>(
          create: (_) => bloc = EventEditBloc(
            createCalendarEvent: _FakeCreateCalendarEvent(),
            updateCalendarEvent: _FakeUpdateCalendarEvent(),
            proposeNewTime: ProposeNewTime(repository),
            notificationService: _FakeNotificationService(),
            accountId: 'acct-1',
          ),
          child: Center(
            child: SizedBox(
              width: 1000,
              height: 800,
              child: EventEditForm(
                event: event,
                proposeNewTime: proposeNewTime,
                initialStart: initialStart,
                initialEnd: initialEnd,
                accountId: 'acct-1',
                onClose: () {},
                checkAttendeesAvailability:
                    CheckAttendeesAvailability(repository),
              ),
            ),
          ),
        ),
      ),
    ));
  }

  /// Past the form's 600 ms edit debounce.
  Future<void> settleDebounce(WidgetTester tester) async {
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();
  }

  group('EventEditForm — proposing a new time', () {
    testWidgets("fetches everyone's free/busy for somebody else's meeting",
        (tester) async {
      // A viewer of the same meeting gets no availability at all (see
      // event_edit_availability_test); a proposer needs it, organizer included
      // — Graph keeps the organizer out of `attendees`, and theirs is the one
      // calendar a counter-proposal most has to suit.
      await pumpForm(tester, event: _theirMeeting());
      await settleDebounce(tester);

      final call = repository.availabilityCalls.single;
      expect(call.emails,
          ['boss@example.com', 'guest@example.com', 'me@example.com']);
      expect(call.organizerEmail, 'me@example.com',
          reason: 'the account is "Me" in the grid, whoever organizes');
      expect(call.excludeEventId, 'event-1',
          reason: 'the meeting must not clash with its own copies');
      expect(call.start, _start);
      expect(call.end, _end);
    });

    testWidgets('queries the slot a dragged tile was dropped on',
        (tester) async {
      final droppedStart = DateTime(2026, 6, 10, 14);
      final droppedEnd = DateTime(2026, 6, 10, 15, 30);
      await pumpForm(tester,
          event: _theirMeeting(),
          initialStart: droppedStart,
          initialEnd: droppedEnd);
      await settleDebounce(tester);

      final call = repository.availabilityCalls.single;
      expect(call.start, droppedStart);
      expect(call.end, droppedEnd);
    });

    testWidgets('keeps the meeting length when only a start is given',
        (tester) async {
      await pumpForm(tester,
          event: _theirMeeting(), initialStart: DateTime(2026, 6, 11, 9));
      await settleDebounce(tester);

      final call = repository.availabilityCalls.single;
      expect(call.start, DateTime(2026, 6, 11, 9));
      expect(call.end, DateTime(2026, 6, 11, 10));
    });

    testWidgets('offers the schedule pane and a message to the organizer',
        (tester) async {
      await pumpForm(tester, event: _theirMeeting());
      await settleDebounce(tester);

      expect(find.text('Find a time'), findsOneWidget);
      expect(find.text('Message to organizer (optional)'), findsOneWidget);
      expect(find.widgetWithText(FilledButton, 'Propose New Time'),
          findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
      expect(find.text('Forward'), findsNothing,
          reason: 'forwarding belongs to the plain view of the meeting');
    });

    testWidgets('leaves everything but the time read-only', (tester) async {
      await pumpForm(tester, event: _theirMeeting());
      await settleDebounce(tester);

      final title = tester.widget<TextField>(
          find.widgetWithText(TextField, 'Design review'));
      expect(title.readOnly, isTrue);
      // The guests field is under an AbsorbPointer, so typing a new guest is
      // not possible; the roster shown is the meeting's.
      expect(find.text('guest@example.com'), findsWidgets);
    });

    testWidgets('sends the proposal with the times shown and the message',
        (tester) async {
      final droppedStart = DateTime(2026, 6, 10, 14);
      final droppedEnd = DateTime(2026, 6, 10, 15);
      await pumpForm(tester,
          event: _theirMeeting(),
          initialStart: droppedStart,
          initialEnd: droppedEnd);
      await settleDebounce(tester);

      await tester.enterText(
          find.widgetWithText(TextField, 'Message to organizer (optional)'),
          'Clashes with the board meeting');
      await tester.tap(find.widgetWithText(FilledButton, 'Propose New Time'));
      await tester.pumpAndSettle();

      final proposal = repository.proposals.single;
      expect(proposal.eventId, 'event-1');
      expect(proposal.newStart, droppedStart);
      expect(proposal.newEnd, droppedEnd);
      expect(proposal.message, 'Clashes with the board meeting');
      expect(proposal.timezone, isNotNull,
          reason: 'wall-clock times need the zone they are in');
      expect(bloc.state, const EventEditProposed(eventId: 'event-1'));
    });

    testWidgets('sends no message when the field is left blank',
        (tester) async {
      await pumpForm(tester, event: _theirMeeting());
      await settleDebounce(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Propose New Time'));
      await tester.pumpAndSettle();

      expect(repository.proposals.single.message, isNull);
    });

    testWidgets('reports a failed proposal instead of closing',
        (tester) async {
      repository.proposeFailure = const ServerFailure(message: 'boom');
      await pumpForm(tester, event: _theirMeeting());
      await settleDebounce(tester);

      await tester.tap(find.widgetWithText(FilledButton, 'Propose New Time'));
      await tester.pumpAndSettle();

      expect(bloc.state, const EventEditError(message: 'boom'));
    });

    testWidgets('fetches nothing for an all-day meeting', (tester) async {
      await pumpForm(tester, event: _theirMeeting(isAllDay: true));
      await settleDebounce(tester);

      expect(repository.availabilityCalls, isEmpty);
    });
  });
}
