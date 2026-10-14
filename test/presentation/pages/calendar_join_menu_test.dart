// The "Join Meeting" context-menu item used to key off an `https://` location.
// It now reads CalendarEvent.onlineMeetingUrl, and a regression there is silent
// — the menu simply comes up one item short — so it is asserted directly.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_event_attendee.dart';
import 'package:nightmail/presentation/pages/calendar_page.dart';

const _meetUrl = 'https://meet.google.com/abc-defg-hij';

CalendarEvent _event({
  String? location,
  String? onlineMeetingUrl,
  bool isOrganizer = true,
  String? organizerEmail,
  List<CalendarEventAttendee> attendees = const [],
}) =>
    CalendarEvent(
      id: 'e1',
      subject: 'Design review',
      start: DateTime(2026, 6, 10, 10),
      end: DateTime(2026, 6, 10, 11),
      isAllDay: false,
      isOrganizer: isOrganizer,
      location: location,
      onlineMeetingUrl: onlineMeetingUrl,
      organizerEmail: organizerEmail,
      attendees: attendees,
    );

void main() {
  /// Opens the event context menu and settles it.
  ///
  /// The menu only reaches CalendarBloc from its selection handler, so opening
  /// it and reading the items needs no bloc above it.
  Future<void> openMenu(WidgetTester tester, CalendarEvent event) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: ElevatedButton(
              onPressed: () => showEventContextMenuForTesting(
                context,
                event,
                const Offset(100, 100),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  group('as the organizer', () {
    testWidgets('a meeting with a join link offers Join Meeting',
        (tester) async {
      await openMenu(tester, _event(onlineMeetingUrl: _meetUrl));

      expect(find.text('Join Meeting'), findsOneWidget);
    });

    testWidgets('a meeting held in a room, with a link, still offers it — the '
        'two are no longer competing for one field', (tester) async {
      await openMenu(
          tester, _event(location: 'Boardroom', onlineMeetingUrl: _meetUrl));

      expect(find.text('Join Meeting'), findsOneWidget);
    });

    testWidgets('a meeting with only a place does not', (tester) async {
      await openMenu(tester, _event(location: 'Level 3 kitchen'));

      expect(find.text('Join Meeting'), findsNothing);
      // The rest of the menu is unaffected.
      expect(find.text('Cancel Meeting'), findsOneWidget);
    });

    testWidgets('a location that merely looks like a URL is not a join link',
        (tester) async {
      await openMenu(
          tester, _event(location: 'https://maps.google.com/?q=head+office'));

      expect(find.text('Join Meeting'), findsNothing);
    });
  });

  group('as an attendee', () {
    testWidgets('a meeting with a join link offers Join Meeting',
        (tester) async {
      await openMenu(
          tester, _event(onlineMeetingUrl: _meetUrl, isOrganizer: false));

      expect(find.text('Join Meeting'), findsOneWidget);
      expect(find.text('Decline Meeting'), findsOneWidget);
    });

    testWidgets('a meeting without one does not', (tester) async {
      await openMenu(
          tester, _event(location: 'Boardroom', isOrganizer: false));

      expect(find.text('Join Meeting'), findsNothing);
      expect(find.text('Decline Meeting'), findsOneWidget);
    });
  });

  group('Email Attendees', () {
    const guest = CalendarEventAttendee(email: 'kim@example.com');
    const room = CalendarEventAttendee(
        email: 'boardroom@example.com', isResource: true);

    testWidgets('is offered to the organizer of a meeting with guests',
        (tester) async {
      await openMenu(tester, _event(attendees: const [guest]));

      expect(find.text('Email Attendees'), findsOneWidget);
    });

    testWidgets('is offered to an attendee, who can always reach the organizer',
        (tester) async {
      await openMenu(
          tester,
          _event(
              isOrganizer: false, organizerEmail: 'boss@example.com'));

      expect(find.text('Email Attendees'), findsOneWidget);
    });

    testWidgets('is not offered when only a room is booked', (tester) async {
      await openMenu(tester, _event(attendees: const [room]));

      expect(find.text('Email Attendees'), findsNothing);
    });

    test('addresses the organizer and guests, minus rooms, self and repeats',
        () {
      final recipients = meetingEmailRecipients(
        _event(
          organizerEmail: 'boss@example.com',
          attendees: const [
            CalendarEventAttendee(email: 'Boss@example.com'),
            CalendarEventAttendee(email: 'me@example.com'),
            guest,
            room,
          ],
        ),
        'ME@example.com',
      );

      expect(recipients.map((r) => r.address),
          ['boss@example.com', 'kim@example.com']);
    });
  });
}
