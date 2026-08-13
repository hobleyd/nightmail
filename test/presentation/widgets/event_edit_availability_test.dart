import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/attendee_availability.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_event_attendee.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/repositories/calendar_repository.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/domain/usecases/check_attendees_availability.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/event_edit/event_edit_bloc.dart';
import 'package:nightmail/presentation/widgets/event_edit_dialog.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

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

// The form's footer builds against EventEditBloc for its saving spinner, so a
// real bloc (never dispatched to here) sits above it with inert use cases.
class _FakeCreateCalendarEvent extends Fake implements CreateCalendarEvent {}

class _FakeUpdateCalendarEvent extends Fake implements UpdateCalendarEvent {}

class _FakeNotificationService extends Fake implements NotificationService {}

EventEditBloc _stubBloc() => EventEditBloc(
      createCalendarEvent: _FakeCreateCalendarEvent(),
      updateCalendarEvent: _FakeUpdateCalendarEvent(),
      notificationService: _FakeNotificationService(),
    );

class _FakeSystemContacts extends Fake implements SystemContactsRepository {
  @override
  Future<void> warmUp() async {}

  @override
  Future<List<ContactSuggestion>> search(String query) async => const [];
}

/// Records every free/busy query the form makes, so the tests can assert both
/// *that* it asked and *what* it asked for.
class _RecordingCalendarRepository extends Fake implements CalendarRepository {
  final calls = <_AvailabilityCall>[];
  List<AttendeeAvailability> availabilities = const [];
  Failure? failure;

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
    calls.add(_AvailabilityCall(
      emails: emails,
      start: start,
      end: end,
      organizerEmail: organizerEmail,
      accountId: accountId,
      excludeEventId: excludeEventId,
      excludeStart: excludeStart,
      excludeEnd: excludeEnd,
    ));
    final f = failure;
    return f != null ? Left(f) : Right(availabilities);
  }
}

class _AvailabilityCall {
  _AvailabilityCall({
    required this.emails,
    required this.start,
    required this.end,
    this.organizerEmail,
    this.accountId,
    this.excludeEventId,
    this.excludeStart,
    this.excludeEnd,
  });

  final List<String> emails;
  final DateTime start;
  final DateTime end;
  final String? organizerEmail;
  final String? accountId;
  final String? excludeEventId;
  final DateTime? excludeStart;
  final DateTime? excludeEnd;
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

// Local wall-clock times: the form reads the event with .toLocal() and the
// schedule pane draws 07:00–20:00 local, so anchoring here keeps the
// expectations independent of where the tests run.
final _start = DateTime(2026, 6, 10, 10);
final _end = DateTime(2026, 6, 10, 11);

CalendarEvent _event({
  List<String> guests = const ['guest@example.com'],
  bool isAllDay = false,
  bool isOrganizer = true,
  String id = 'event-1',
  int? reminderMinutes,
}) =>
    CalendarEvent(
      id: id,
      subject: 'Design review',
      start: _start,
      end: _end,
      isAllDay: isAllDay,
      isOrganizer: isOrganizer,
      reminderMinutes: reminderMinutes,
      attendees: [
        for (final g in guests) CalendarEventAttendee(email: g),
      ],
    );

void main() {
  late _RecordingCalendarRepository repository;

  setUp(() {
    repository = _RecordingCalendarRepository();
    sl.registerSingleton<AccountManager>(_FakeAccountManager());
    sl.registerSingleton<SystemContactsRepository>(_FakeSystemContacts());
  });

  tearDown(() => sl.reset());

  // The schedule pane widens the form to 560 + 280, which overflows the
  // default 800x600 test surface.
  //
  // It also overflows its own 280px header here, which it does not do in the
  // app: flutter_test substitutes a font whose every glyph is a square of the
  // font size, so the "Schedules — Wed, Jun 10" title measures roughly twice
  // its real width. Drop those specific errors and let everything else fail
  // the test.
  Future<void> useLargeSurface(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));

    final original = FlutterError.onError;
    FlutterError.onError = (details) {
      if (details.exceptionAsString().contains('A RenderFlex overflowed')) {
        return;
      }
      original?.call(details);
    };

    addTearDown(() async {
      FlutterError.onError = original;
      await tester.binding.setSurfaceSize(null);
    });
  }

  Future<void> pumpForm(
    WidgetTester tester, {
    CalendarEvent? event,
    String? accountId = 'acct-1',
    bool fillsWindow = false,
    bool loose = false,
  }) async {
    // Most tests hand the form a *tight* box, which stretches it to fill
    // whatever it is given. `loose` reproduces the constraint a Scaffold body
    // hands its child instead — the only shape in which the form's own choice
    // of size (see [EventEditForm.fillsWindow]) is visible at all.
    Widget box(Widget child) => loose
        ? Align(alignment: Alignment.topLeft, child: child)
        : child;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlocProvider<EventEditBloc>(
          create: (_) => _stubBloc(),
          child: Center(
            child: SizedBox(
              width: 1000,
              height: 800,
              child: box(EventEditForm(
                event: event,
                accountId: accountId,
                onClose: () {},
                fillsWindow: fillsWindow,
                checkAttendeesAvailability:
                    CheckAttendeesAvailability(repository),
              )),
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

  group('EventEditForm — availability on open', () {
    testWidgets('fetches free/busy for a meeting opened with guests',
        (tester) async {
      // The regression this guards: every other trigger is a user edit, so a
      // meeting that is merely opened and looked at used to query nothing.
      await pumpForm(tester, event: _event());
      await settleDebounce(tester);

      expect(repository.calls, hasLength(1));
      expect(repository.calls.single.emails, ['guest@example.com']);
      expect(repository.calls.single.organizerEmail, 'me@example.com');
      expect(repository.calls.single.accountId, 'acct-1');
    });

    testWidgets('queries the times shown in the form', (tester) async {
      await pumpForm(tester, event: _event());
      await settleDebounce(tester);

      expect(repository.calls.single.start, _start);
      expect(repository.calls.single.end, _end);
    });

    testWidgets('asks for nothing when a new meeting has no guests',
        (tester) async {
      await pumpForm(tester, event: null);
      await settleDebounce(tester);

      expect(repository.calls, isEmpty);
    });

    testWidgets('asks for nothing when the meeting has no guests',
        (tester) async {
      await pumpForm(tester, event: _event(guests: const []));
      await settleDebounce(tester);

      expect(repository.calls, isEmpty);
    });

    testWidgets('asks for nothing for an all-day meeting', (tester) async {
      // There is no time to negotiate, so the readout and the pane are both
      // hidden — querying would be wasted network.
      await pumpForm(tester, event: _event(isAllDay: true));
      await settleDebounce(tester);

      expect(repository.calls, isEmpty);
    });

    testWidgets('asks for nothing when the meeting is read-only',
        (tester) async {
      // Someone else's meeting: the availability section is not rendered, so
      // there is nothing to populate.
      await pumpForm(tester, event: _event(isOrganizer: false));
      await settleDebounce(tester);

      expect(repository.calls, isEmpty);
    });
  });

  group('EventEditForm — excluding the meeting from its own check', () {
    testWidgets('passes the stored event as the exclusion', (tester) async {
      await pumpForm(tester, event: _event());
      await settleDebounce(tester);

      final call = repository.calls.single;
      expect(call.excludeEventId, 'event-1');
      expect(call.excludeStart, _start);
      expect(call.excludeEnd, _end);
    });

    testWidgets('excludes nothing when composing a new meeting',
        (tester) async {
      // Nothing is on anyone's calendar yet, so there is nothing to discount.
      await pumpForm(tester, event: null);
      await tester.enterText(
          find.widgetWithText(TextField, 'Add guests by email'),
          'guest@example.com,');
      await settleDebounce(tester);

      expect(repository.calls, isNotEmpty);
      expect(repository.calls.last.excludeEventId, isNull);
      expect(repository.calls.last.excludeStart, isNull);
      expect(repository.calls.last.excludeEnd, isNull);
    });
  });

  group('EventEditForm — the schedule pane', () {
    testWidgets('renders a status row once availability arrives',
        (tester) async {
      repository.availabilities = const [
        AttendeeAvailability(
          email: 'guest@example.com',
          status: AttendeeAvailabilityStatus.busy,
        ),
      ];

      await pumpForm(tester, event: _event());
      await settleDebounce(tester);

      expect(find.text('guest@example.com'), findsWidgets);
      expect(find.text('Busy'), findsOneWidget);
    });

    testWidgets('fetches immediately when the pane is opened, without waiting '
        'for the edit debounce', (tester) async {
      // A failed first attempt leaves availability null. Opening the pane is an
      // explicit request to see schedules, so it must retry there and then
      // rather than sitting behind the debounce or showing an empty grid.
      await useLargeSurface(tester);
      repository.failure = const ServerFailure(message: 'boom');

      await pumpForm(tester, event: _event());
      await settleDebounce(tester);
      expect(repository.calls, hasLength(1));

      repository.failure = null;
      await tester.tap(find.text('Find a time'));
      await tester.pump(const Duration(milliseconds: 20));

      expect(repository.calls, hasLength(2),
          reason: 'the pane should fetch on open, well inside the 600ms '
              'debounce window');
      await tester.pumpAndSettle();
    });

    testWidgets('does not refetch when the pane is opened over fresh data',
        (tester) async {
      await useLargeSurface(tester);
      repository.availabilities = const [
        AttendeeAvailability(
          email: 'guest@example.com',
          status: AttendeeAvailabilityStatus.free,
        ),
      ];

      await pumpForm(tester, event: _event());
      await settleDebounce(tester);
      expect(repository.calls, hasLength(1));

      await tester.tap(find.text('Find a time'));
      await tester.pumpAndSettle();

      expect(repository.calls, hasLength(1));
      expect(find.text('Hide schedules'), findsOneWidget);
    });

    testWidgets("draws a guest's blocks when the stored address differs in "
        'case', (tester) async {
      await useLargeSurface(tester);
      // An existing event carries whatever casing the server stored, which need
      // not match how the provider echoes the address back.
      repository.availabilities = [
        AttendeeAvailability(
          email: 'guest@example.com',
          status: AttendeeAvailabilityStatus.busy,
          scheduleItems: [
            AttendeeScheduleItem(
              start: DateTime(2026, 6, 10, 14).toUtc(),
              end: DateTime(2026, 6, 10, 15).toUtc(),
              status: AttendeeAvailabilityStatus.busy,
              subject: 'Existing commitment',
            ),
          ],
        ),
      ];

      await pumpForm(tester, event: _event(guests: const ['Guest@Example.com']));
      await settleDebounce(tester);

      await tester.tap(find.text('Find a time'));
      await tester.pumpAndSettle();

      expect(find.text('Existing commitment'), findsOneWidget);
    });

    testWidgets('gives the grid every pixel the form column does not use',
        (tester) async {
      // The pane is the only part that grows: resizing the window has to widen
      // the grid rather than leave a gap beside a fixed-width pane.
      await useLargeSurface(tester);

      await pumpForm(tester, event: _event());
      await settleDebounce(tester);
      await tester.tap(find.text('Find a time'));
      await tester.pumpAndSettle();

      // pumpForm lays the form out in a 1000x800 box; 560 goes to the form
      // column and 1 to the divider between them.
      final grid = tester.getSize(find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ScheduleGrid'));
      expect(grid.width, 1000 - 560 - 1);
      expect(grid.height, 800);
    });
  });

  group('EventEditForm — filling its window', () {
    testWidgets('takes the whole window rather than its natural width',
        (tester) async {
      // Opening a meeting in its own window and resizing that window used to
      // leave the form pinned at 560 with dead space beside and below it.
      await useLargeSurface(tester);

      await pumpForm(tester, event: _event(), fillsWindow: true, loose: true);
      await settleDebounce(tester);

      expect(tester.getSize(find.byType(EventEditForm)), const Size(1000, 800));
    });

    testWidgets('the in-app dialog still states its own width',
        (tester) async {
      // The dialog sizes itself to the form, so a form that took everything on
      // offer would open full-screen.
      await useLargeSurface(tester);

      await pumpForm(tester, event: _event(), loose: true);
      await settleDebounce(tester);

      expect(tester.getSize(find.byType(EventEditForm)).width, kEventFormWidth);
    });

    testWidgets('opening the schedule pane leaves the form the width it had',
        (tester) async {
      // The host window grows by the pane's width when it opens, so the pane
      // takes that and the form keeps what it was already using — snapping the
      // form back to 560 would reflow every field under the user.
      await useLargeSurface(tester);

      await pumpForm(tester, event: _event(), fillsWindow: true, loose: true);
      await settleDebounce(tester);
      await tester.tap(find.text('Find a time'));
      await tester.pumpAndSettle();

      final grid = tester.getSize(find.byWidgetPredicate(
          (w) => w.runtimeType.toString() == '_ScheduleGrid'));
      expect(grid.width, kSchedulePaneWidth);
      expect(grid.height, 800);
    });
  });

  group('EventEditForm — the reminder field', () {
    int? reminderValue(WidgetTester tester) =>
        tester.widget<DropdownButton<int?>>(find.byType(DropdownButton<int?>))
            .value;

    testWidgets('defaults a new meeting to 15 minutes before the start',
        (tester) async {
      await pumpForm(tester, event: null);
      await tester.pumpAndSettle();

      expect(reminderValue(tester), 15);
    });

    testWidgets('keeps an existing meeting without a reminder', (tester) async {
      // The default is for meetings being created; opening one the organizer
      // deliberately saved with no reminder must not quietly add one.
      await pumpForm(tester, event: _event());
      await settleDebounce(tester);

      expect(reminderValue(tester), isNull);
    });

    testWidgets("keeps an existing meeting's own reminder", (tester) async {
      await pumpForm(tester, event: _event(reminderMinutes: 30));
      await settleDebounce(tester);

      expect(reminderValue(tester), 30);
    });
  });
}
