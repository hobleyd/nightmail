import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/attendee_availability.dart';
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
import 'package:nightmail/presentation/widgets/event_edit_dialog.dart';

// A *new* meeting seeded from an email — the reading pane's "New meeting
// from this email" — opens with the title, guests and notes it was given,
// and fetches those guests' free/busy straight away as an existing meeting
// would. The organizer is not among the chips even when the seed names them.

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

class _FakeProposeNewTime extends Fake implements ProposeNewTime {}

class _FakeNotificationService extends Fake implements NotificationService {}

class _FakeSystemContacts extends Fake implements SystemContactsRepository {
  @override
  Future<void> warmUp() async {}

  @override
  Future<List<ContactSuggestion>> search(String query) async => const [];
}

class _RecordingCalendarRepository extends Fake implements CalendarRepository {
  final availabilityCalls = <List<String>>[];

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
    availabilityCalls.add(emails);
    return const Right([]);
  }
}

void main() {
  late _RecordingCalendarRepository repository;

  setUp(() {
    repository = _RecordingCalendarRepository();
    sl.registerSingleton<AccountManager>(_FakeAccountManager());
    sl.registerSingleton<SystemContactsRepository>(_FakeSystemContacts());
  });

  tearDown(() => sl.reset());

  final titles = <String>[];

  Future<void> pumpForm(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlocProvider<EventEditBloc>(
          create: (_) => EventEditBloc(
            createCalendarEvent: _FakeCreateCalendarEvent(),
            updateCalendarEvent: _FakeUpdateCalendarEvent(),
            proposeNewTime: _FakeProposeNewTime(),
            notificationService: _FakeNotificationService(),
            accountId: 'acct-1',
          ),
          child: Center(
            child: SizedBox(
              width: 1000,
              height: 800,
              child: EventEditForm(
                accountId: 'acct-1',
                onTitleChanged: titles.add,
                initialSubject: 'Budget',
                initialAttendees: const [
                  'jane@example.com',
                  'Me@Example.com',
                  'bob@example.com',
                ],
                initialDescription: 'Can we meet about this?',
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

  testWidgets('a seeded new meeting opens with its title, guests and notes',
      (tester) async {
    await pumpForm(tester);
    await tester.pump(const Duration(milliseconds: 700));
    await tester.pumpAndSettle();

    expect(titles.last, 'Budget',
        reason: 'the window is named after the seeded title');
    expect(find.text('Save Event'), findsOneWidget,
        reason: 'a seed is a starting point, not an existing meeting');
    expect(
      tester.widget<TextField>(find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'Event title')),
      isA<TextField>().having((f) => f.controller?.text, 'title', 'Budget'),
    );
    expect(
      tester.widget<TextField>(find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.hintText == 'Add notes')),
      isA<TextField>().having(
          (f) => f.controller?.text, 'notes', 'Can we meet about this?'),
    );
    expect(find.text('jane@example.com'), findsOneWidget);
    expect(find.text('bob@example.com'), findsOneWidget);
    expect(find.text('Me@Example.com'), findsNothing,
        reason: 'the organizer is never one of the Guests chips');

    expect(repository.availabilityCalls.single,
        ['jane@example.com', 'bob@example.com'],
        reason: 'the seeded guests are checked for free/busy on open');
  });
}
