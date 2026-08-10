import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fpdart/fpdart.dart';
import 'package:mockito/mockito.dart';
import 'package:nightmail/core/error/failures.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/email.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/entities/meeting_invite.dart';
import 'package:nightmail/domain/usecases/create_calendar_event.dart';
import 'package:nightmail/domain/usecases/get_calendar_events.dart';
import 'package:nightmail/injection_container.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_bloc.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_event.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_state.dart';
import 'package:nightmail/presentation/widgets/add_to_calendar_banner.dart';

/// The banner shown for a `METHOD:PUBLISH` calendar part.
///
/// It is the one meeting banner that *creates* something rather than answering
/// something, which makes two of its rules worth pinning down: it must not
/// offer to add an event that is already there, and it must not decline to add
/// one just because it could not check.

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeGetCalendarEvents extends Fake implements GetCalendarEvents {
  List<CalendarEvent> events = const [];
  Failure? failure;
  final calls = <GetCalendarEventsParams>[];

  @override
  Future<Either<Failure, List<CalendarEvent>>> call(
      GetCalendarEventsParams params) async {
    calls.add(params);
    final f = failure;
    return f != null ? Left(f) : Right(events);
  }
}

class _FakeCreateCalendarEvent extends Fake implements CreateCalendarEvent {
  final calls = <CreateCalendarEventParams>[];
  Failure? failure;

  /// When set, the call parks here until the test completes it — the only way
  /// to observe the in-flight state.
  Completer<void>? gate;

  @override
  Future<Either<Failure, CalendarEvent>> call(
      CreateCalendarEventParams params) async {
    calls.add(params);
    await gate?.future;
    final f = failure;
    return f != null
        ? Left(f)
        : Right(CalendarEvent(
            id: 'created-1',
            subject: params.subject,
            start: params.start,
            end: params.end,
            isAllDay: params.isAllDay,
          ));
  }
}

/// `context.read<CalendarBloc>()` needs a CalendarBloc in the tree, and the
/// real one wants a service locator full of use cases. The banner only reads
/// `state.weekStart` and adds a refresh event, but `BlocProvider` subscribes to
/// [stream] on the first read regardless — hence the empty one.
class _FakeCalendarBloc extends Fake implements CalendarBloc {
  final added = <CalendarBlocEvent>[];

  @override
  CalendarState get state => CalendarInitial(weekStart: DateTime(2026, 8, 3));

  @override
  Stream<CalendarState> get stream => const Stream<CalendarState>.empty();

  @override
  void add(CalendarBlocEvent event) => added.add(event);
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

final _start = DateTime.utc(2026, 8, 5, 1, 30);
final _end = DateTime.utc(2026, 8, 5, 2, 30);

Email _email({
  String subject = 'Your booking is confirmed',
  String? summary = 'Rehearsal',
  String? description = 'Bring a music stand.',
  String? location = 'Hall B',
  String? uid = 'pub-1@example.com',
  DateTime? start,
}) =>
    Email(
      id: 'msg-1',
      subject: subject,
      from: const EmailAddress(address: 'tickets@example.com'),
      toRecipients: const [],
      ccRecipients: const [],
      bodyPreview: '',
      body: '',
      bodyType: EmailBodyType.text,
      isRead: true,
      receivedDateTime: DateTime.utc(2026, 8, 1),
      importance: EmailImportance.normal,
      meetingInvite: MeetingInvite(
        type: MeetingEmailType.publishedEvent,
        uid: uid,
        summary: summary,
        description: description,
        location: location,
        meetingStart: start ?? _start,
        meetingEnd: _end,
      ),
    );

CalendarEvent _existing({String? iCalUid}) => CalendarEvent(
      id: 'evt-1',
      subject: 'Rehearsal',
      start: _start,
      end: _end,
      isAllDay: false,
      iCalUid: iCalUid,
    );

void main() {
  late _FakeGetCalendarEvents getEvents;
  late _FakeCreateCalendarEvent createEvent;
  late _FakeCalendarBloc calendarBloc;

  setUp(() {
    getEvents = _FakeGetCalendarEvents();
    createEvent = _FakeCreateCalendarEvent();
    calendarBloc = _FakeCalendarBloc();
    sl.registerSingleton<GetCalendarEvents>(getEvents);
    sl.registerSingleton<CreateCalendarEvent>(createEvent);
  });

  tearDown(() => sl.reset());

  Future<void> pumpBanner(WidgetTester tester, {Email? email}) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: BlocProvider<CalendarBloc>.value(
          value: calendarBloc,
          child: AddToCalendarBanner(email: email ?? _email()),
        ),
      ),
    ));
    // Let the already-on-the-calendar lookup settle.
    await tester.pumpAndSettle();
  }

  group('AddToCalendarBanner — what it shows', () {
    testWidgets('offers the button, with the event read off the ICS',
        (tester) async {
      await pumpBanner(tester);

      expect(find.text('Add to calendar'), findsOneWidget);
      // The ICS title, not the covering email's subject.
      expect(find.text('Rehearsal'), findsOneWidget);
      expect(find.text('Your booking is confirmed'), findsNothing);
      expect(find.text('Hall B'), findsOneWidget);
    });

    testWidgets('falls back to the message subject when the ICS has no title',
        (tester) async {
      await pumpBanner(tester, email: _email(summary: null));

      await tester.tap(find.text('Add to calendar'));
      await tester.pumpAndSettle();

      expect(createEvent.calls.single.subject, 'Your booking is confirmed');
    });
  });

  group('AddToCalendarBanner — adding', () {
    testWidgets('creates the event from the ICS, not from the email',
        (tester) async {
      await pumpBanner(tester);
      await tester.tap(find.text('Add to calendar'));
      await tester.pumpAndSettle();

      final params = createEvent.calls.single;
      expect(params.subject, 'Rehearsal');
      expect(params.start, _start);
      expect(params.end, _end);
      expect(params.location, 'Hall B');
      expect(params.description, 'Bring a music stand.');
      // A published event invites nobody and books nothing.
      expect(params.attendeeEmails, isEmpty);
      expect(params.roomEmails, isEmpty);
      expect(params.isOnlineMeeting, isFalse);
    });

    testWidgets('reports success and refreshes the calendar week',
        (tester) async {
      await pumpBanner(tester);
      await tester.tap(find.text('Add to calendar'));
      await tester.pumpAndSettle();

      expect(find.text('Added to calendar'), findsOneWidget);
      expect(find.text('Add to calendar'), findsNothing);
      expect(calendarBloc.added.single, isA<CalendarWeekLoadRequested>());
    });

    testWidgets('shows a spinner while the create is in flight, and the button '
        'cannot be pressed twice', (tester) async {
      createEvent.gate = Completer<void>();
      await pumpBanner(tester);

      await tester.tap(find.text('Add to calendar'));
      await tester.pump();

      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(find.text('Add to calendar'), findsNothing);

      createEvent.gate!.complete();
      await tester.pumpAndSettle();
      expect(createEvent.calls, hasLength(1));
    });

    testWidgets('a failure shows the reason and a Retry that restores the '
        'button', (tester) async {
      createEvent.failure = const ServerFailure(message: 'Calendar is read-only');
      await pumpBanner(tester);

      await tester.tap(find.text('Add to calendar'));
      await tester.pumpAndSettle();

      expect(find.text('Calendar is read-only'), findsOneWidget);
      // No refresh: nothing changed on the calendar to repaint.
      expect(calendarBloc.added, isEmpty);

      await tester.tap(find.text('Retry'));
      await tester.pumpAndSettle();
      expect(find.text('Add to calendar'), findsOneWidget);
    });
  });

  group('AddToCalendarBanner — the event may already be there', () {
    testWidgets('withholds the button when the UID is already on the calendar',
        (tester) async {
      // Nothing else adds a published event, so a second press would make a
      // second event — unlike an invitation, whose copy the provider owns.
      getEvents.events = [_existing(iCalUid: 'pub-1@example.com')];
      await pumpBanner(tester);

      expect(find.text('Already on your calendar'), findsOneWidget);
      expect(find.text('Add to calendar'), findsNothing);
    });

    testWidgets('matches the UID across the mangling Google applies',
        (tester) async {
      getEvents.events = [
        _existing(iCalUid: 'pub-1_20260805T013000Z@google.com'),
      ];
      await pumpBanner(tester);

      expect(find.text('Already on your calendar'), findsOneWidget);
    });

    testWidgets('an event in the same slot with a different UID is not it',
        (tester) async {
      getEvents.events = [_existing(iCalUid: 'something-else@example.com')];
      await pumpBanner(tester);

      expect(find.text('Add to calendar'), findsOneWidget);
    });

    testWidgets('still offers the button when the lookup fails',
        (tester) async {
      // Refusing to add an event the user asked for is worse than a duplicate
      // they can delete.
      getEvents.failure = const ServerFailure(message: 'offline');
      await pumpBanner(tester);

      expect(find.text('Add to calendar'), findsOneWidget);
    });

    testWidgets('does not even look when the ICS carries no UID to match on',
        (tester) async {
      // An unknown UID matches nothing; querying would only cost a round trip
      // whose answer could not be used.
      await pumpBanner(tester, email: _email(uid: null));

      expect(getEvents.calls, isEmpty);
      expect(find.text('Add to calendar'), findsOneWidget);
    });
  });
}
