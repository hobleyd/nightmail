import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/attendee_availability.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_event_attendee.dart';
import 'package:nightmail/domain/entities/contact_suggestion.dart';
import 'package:nightmail/domain/entities/meeting_room.dart';
import 'package:nightmail/domain/repositories/calendar_repository.dart';
import 'package:nightmail/domain/repositories/system_contacts_repository.dart';
import 'package:nightmail/domain/usecases/check_attendees_availability.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';
import 'package:nightmail/domain/usecases/get_meeting_rooms.dart';
import 'package:nightmail/domain/usecases/update_calendar_event.dart';
import 'package:nightmail/infrastructure/accounts/account.dart';
import 'package:nightmail/infrastructure/accounts/account_manager.dart';
import 'package:nightmail/infrastructure/notifications/notification_service.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/event_edit/event_edit_bloc.dart';
import 'package:nightmail/presentation/widgets/event_edit_dialog.dart';
import 'package:nightmail/presentation/widgets/room_location_field.dart';

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

class _FakeCalendarRepository extends Fake implements CalendarRepository {
  List<MeetingRoom> rooms = const [];
  int roomFetches = 0;

  /// Free/busy answers, keyed by lower-cased address. Anything absent answers
  /// `free`.
  Map<String, AttendeeAvailabilityStatus> statuses = const {};

  /// Every room free/busy query, so a test can assert what was asked about.
  final availabilityCalls = <List<String>>[];

  @override
  Future<Either<Failure, List<MeetingRoom>>> getMeetingRooms({
    String? accountId,
  }) async {
    roomFetches++;
    return Right(rooms);
  }

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
    // Only the room queries are of interest; the guest query passes an organizer.
    if (organizerEmail == null) availabilityCalls.add(emails);
    return Right([
      for (final e in emails)
        AttendeeAvailability(
          email: e,
          status: statuses[e.toLowerCase()] ?? AttendeeAvailabilityStatus.free,
        ),
    ]);
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _boardroom = MeetingRoom(
  email: 'boardroom@example.com',
  displayName: 'Boardroom',
  capacity: 14,
  building: 'SYD',
  floorLabel: '3',
);
const _huddle = MeetingRoom(
  email: 'huddle@example.com',
  displayName: 'Huddle Space',
  capacity: 4,
);
const _annex = MeetingRoom(
  email: 'annex@example.com',
  displayName: 'Annex',
);

final _start = DateTime(2026, 6, 10, 10);
final _end = DateTime(2026, 6, 10, 11);

/// An existing meeting with a plain typed-in location and no room — the state
/// someone is in when they open a meeting *to* add a room.
CalendarEvent _eventWithLocationText() => CalendarEvent(
      id: 'event-2',
      subject: 'Design review',
      start: _start,
      end: _end,
      isAllDay: false,
      isOrganizer: true,
      location: 'Level 3 kitchen',
    );

CalendarEvent _eventWithRoom() => CalendarEvent(
      id: 'event-1',
      subject: 'Design review',
      start: _start,
      end: _end,
      isAllDay: false,
      isOrganizer: true,
      // What a provider hands back: the room named in `location` *and* present as
      // a resource attendee.
      location: 'Boardroom, Bring laptops',
      attendees: const [
        CalendarEventAttendee(email: 'guest@example.com'),
        CalendarEventAttendee(
          email: 'boardroom@example.com',
          displayName: 'Boardroom',
          isResource: true,
        ),
      ],
    );

void main() {
  late _FakeCalendarRepository repository;

  setUp(() {
    repository = _FakeCalendarRepository();
    sl.registerSingleton<AccountManager>(_FakeAccountManager());
    sl.registerSingleton<SystemContactsRepository>(_FakeSystemContacts());
  });

  tearDown(() => sl.reset());

  Future<void> pumpForm(
    WidgetTester tester, {
    CalendarEvent? event,
    bool withRoomLoader = true,
  }) async {
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlocProvider<EventEditBloc>(
          create: (_) => _stubBloc(),
          child: Center(
            child: SizedBox(
              width: 900,
              height: 850,
              child: EventEditForm(
                event: event,
                accountId: 'acct-1',
                onClose: () {},
                checkAttendeesAvailability:
                    CheckAttendeesAvailability(repository),
                getMeetingRooms:
                    withRoomLoader ? GetMeetingRooms(repository) : null,
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
  }

  /// The Location field's text box. Found structurally rather than by hint text
  /// because the hint is dropped once a room chip is present.
  Finder locationInput() => find.descendant(
        of: find.byType(RoomLocationField),
        matching: find.byType(TextField),
      );

  Future<void> typeInLocation(WidgetTester tester, String text) async {
    await tester.tap(locationInput());
    await tester.pump();
    await tester.enterText(locationInput(), text);
    await tester.pumpAndSettle();
  }

  group('room dropdown', () {
    testWidgets('typing filters the directory and shows matching rooms',
        (tester) async {
      repository.rooms = const [_boardroom, _huddle, _annex];
      await pumpForm(tester);

      await typeInLocation(tester, 'hud');

      expect(find.text('Huddle Space'), findsOneWidget);
      expect(find.text('Boardroom'), findsNothing);
    });

    testWidgets('shows capacity and building as the row subtitle',
        (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester);

      await typeInLocation(tester, 'board');

      expect(find.text('SYD · Level 3 · 14 seats'), findsOneWidget);
    });

    testWidgets('shows a free/busy label per room', (tester) async {
      repository.rooms = const [_boardroom, _huddle];
      repository.statuses = const {
        'boardroom@example.com': AttendeeAvailabilityStatus.busy,
        'huddle@example.com': AttendeeAvailabilityStatus.free,
      };
      await pumpForm(tester);

      // A substring both rooms share, so both are listed and both get a lookup.
      await typeInLocation(tester, 'd');
      // Past the room debounce.
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(find.text('Booked'), findsOneWidget);
      expect(find.text('Available'), findsOneWidget);
    });

    testWidgets('only asks about the rooms it is showing', (tester) async {
      repository.rooms = const [_boardroom, _huddle, _annex];
      await pumpForm(tester);

      await typeInLocation(tester, 'annex');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(repository.availabilityCalls, isNotEmpty);
      expect(repository.availabilityCalls.expand((c) => c),
          ['annex@example.com']);
    });

    testWidgets('does not ask twice for the same room at the same slot',
        (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester);

      await typeInLocation(tester, 'board');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();
      final afterFirst = repository.availabilityCalls.length;

      // Retype the same query — the answer is already held for this slot.
      await typeInLocation(tester, 'boardr');
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(repository.availabilityCalls, hasLength(afterFirst));
    });

    testWidgets('is absent when the account has no room directory',
        (tester) async {
      repository.rooms = const [];
      await pumpForm(tester);

      // The field falls back to being a plain text box — no room-search hint.
      final input = tester.widget<TextField>(locationInput());
      expect(input.decoration?.hintText, 'Add location');

      await typeInLocation(tester, 'anything');
      expect(find.byType(ListTile), findsNothing);
    });
  });

  group('selecting a room', () {
    testWidgets('adds a chip and clears the query it was found with',
        (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester);
      await typeInLocation(tester, 'board');

      await tester.tap(find.text('Boardroom').last);
      await tester.pumpAndSettle();

      // The chip is the only 'Boardroom' left — the dropdown is gone.
      expect(find.text('Boardroom'), findsOneWidget);
      final input = tester.widget<TextField>(locationInput());
      expect(input.controller!.text, isEmpty);
    });

    testWidgets('a picked room drops out of the dropdown', (tester) async {
      repository.rooms = const [_boardroom, _huddle];
      await pumpForm(tester);
      await typeInLocation(tester, 'board');
      await tester.tap(find.text('Boardroom').last);
      await tester.pumpAndSettle();

      await typeInLocation(tester, 'board');

      // Only the chip; the room cannot be booked twice.
      expect(find.text('Boardroom'), findsOneWidget);
    });

    testWidgets('more than one room can be booked', (tester) async {
      repository.rooms = const [_boardroom, _huddle];
      await pumpForm(tester);

      await typeInLocation(tester, 'board');
      await tester.tap(find.text('Boardroom').last);
      await tester.pumpAndSettle();
      await typeInLocation(tester, 'huddle');
      await tester.tap(find.text('Huddle Space').last);
      await tester.pumpAndSettle();

      expect(find.text('Boardroom'), findsOneWidget);
      expect(find.text('Huddle Space'), findsOneWidget);
    });
  });

  // The bug this group exists for: opening an existing meeting to add a room.
  // Such a meeting arrives with the provider's text already in Location, and
  // both ways of reaching the dropdown were broken by it — typing appended to
  // that text and matched nothing, and the browse button filtered the full list
  // by it and so listed nothing either.
  group('adding a room to a meeting that already has a location', () {
    Finder browseButton() => find.descendant(
          of: find.byType(RoomLocationField),
          matching: find.byIcon(Icons.meeting_room_outlined),
        );

    testWidgets('the browse button lists every room, ignoring the text already '
        'in the field', (tester) async {
      repository.rooms = const [_boardroom, _huddle];
      await pumpForm(tester, event: _eventWithLocationText());

      await tester.tap(browseButton());
      await tester.pumpAndSettle();

      expect(find.text('Boardroom'), findsOneWidget);
      expect(find.text('Huddle Space'), findsOneWidget);
    });

    testWidgets('the browse button works on a new event too — showing the '
        'dropdown from a tap needs more than OverlayPortalController.show()',
        (tester) async {
      repository.rooms = const [_boardroom, _huddle];
      await pumpForm(tester);

      await tester.tap(browseButton());
      await tester.pumpAndSettle();

      expect(find.byType(ListTile), findsNWidgets(2));
    });

    testWidgets('picking a browsed room keeps the location that was already '
        'typed — it was never a search query', (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester, event: _eventWithLocationText());

      await tester.tap(browseButton());
      await tester.pumpAndSettle();
      await tester.tap(find.text('Boardroom').last);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(locationInput()).controller!.text,
          'Level 3 kitchen');
      expect(find.text('Boardroom'), findsOneWidget); // now a chip
    });

    testWidgets('typing a room name after the existing location still finds it',
        (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester, event: _eventWithLocationText());

      // What the user actually does: click at the end and type.
      await typeInLocation(tester, 'Level 3 kitchen board');

      expect(find.text('Boardroom'), findsOneWidget);
    });

    testWidgets('picking that room drops only the word searched with',
        (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester, event: _eventWithLocationText());
      await typeInLocation(tester, 'Level 3 kitchen board');

      await tester.tap(find.text('Boardroom').last);
      await tester.pumpAndSettle();

      expect(tester.widget<TextField>(locationInput()).controller!.text,
          'Level 3 kitchen');
    });

    testWidgets('a multi-word room name is still matched on the whole text',
        (tester) async {
      repository.rooms = const [_huddle];
      await pumpForm(tester);

      await typeInLocation(tester, 'huddle sp');

      expect(find.text('Huddle Space'), findsOneWidget);
    });
  });

  group('reopening a meeting that has a room', () {
    testWidgets('shows the room as a chip, not as a guest', (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester, event: _eventWithRoom());

      // The room is a chip in Location. It must not also be in Guests, or saving
      // would re-invite it as a person and lose the resource booking.
      expect(find.text('Boardroom'), findsOneWidget);
      expect(find.text('guest@example.com'), findsOneWidget);
      expect(find.text('boardroom@example.com'), findsNothing);
    });

    testWidgets('strips the room name from the free-text location so it is not '
        'shown — or saved — twice', (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester, event: _eventWithRoom());

      final input = tester.widget<TextField>(locationInput());
      expect(input.controller!.text, 'Bring laptops');
    });

    testWidgets('queries the booked room\'s free/busy on open, excluding this '
        'meeting so the room is not a clash with itself', (tester) async {
      repository.rooms = const [_boardroom];
      await pumpForm(tester, event: _eventWithRoom());
      await tester.pump(const Duration(milliseconds: 400));
      await tester.pumpAndSettle();

      expect(repository.availabilityCalls.expand((c) => c),
          contains('boardroom@example.com'));
    });
  });
}
