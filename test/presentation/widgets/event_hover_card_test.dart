import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/calendar_event_attendee.dart';
import 'package:nightmail/domain/entities/calendar_recurrence.dart';
import 'package:nightmail/presentation/widgets/event_hover_card.dart';

CalendarEvent _event({
  String subject = 'Sprint review',
  DateTime? start,
  DateTime? end,
  bool isAllDay = false,
  String? location,
  String? bodyPreview,
  CalendarEventStatus status = CalendarEventStatus.busy,
  MeetingParticipation participation = MeetingParticipation.none,
  List<CalendarEventAttendee> attendees = const [],
  CalendarRecurrence? recurrence,
  int? reminderMinutes,
  String? seriesMasterId,
}) {
  // Local times: the card formats in local time, as the grid positions tiles.
  final s = start ?? DateTime(2026, 8, 4, 9);
  return CalendarEvent(
    id: 'evt-1',
    subject: subject,
    start: s,
    end: end ?? s.add(const Duration(minutes: 30)),
    isAllDay: isAllDay,
    location: location,
    bodyPreview: bodyPreview,
    status: status,
    participation: participation,
    attendees: attendees,
    recurrence: recurrence,
    reminderMinutes: reminderMinutes,
    seriesMasterId: seriesMasterId,
  );
}

void main() {
  group('formatEventWhen', () {
    test('gives the day, the time range and the length', () {
      expect(
        formatEventWhen(_event(
          start: DateTime(2026, 8, 4, 9),
          end: DateTime(2026, 8, 4, 9, 30),
        )),
        'Tue, 4 Aug · 9:00 AM – 9:30 AM · 30 min',
      );
    });

    test('names both days when a meeting runs past midnight', () {
      expect(
        formatEventWhen(_event(
          start: DateTime(2026, 8, 4, 23),
          end: DateTime(2026, 8, 5, 1),
        )),
        'Tue, 4 Aug 11:00 PM – Wed, 5 Aug 1:00 AM · 2 hr',
      );
    });

    test('reports a single all-day event as one day', () {
      // Providers give the exclusive next midnight as the end.
      expect(
        formatEventWhen(_event(
          start: DateTime(2026, 8, 4),
          end: DateTime(2026, 8, 5),
          isAllDay: true,
        )),
        'All day · Tue, 4 Aug',
      );
    });

    test('spans a multi-day all-day event to its last real day', () {
      expect(
        formatEventWhen(_event(
          start: DateTime(2026, 8, 4),
          end: DateTime(2026, 8, 7),
          isAllDay: true,
        )),
        'All day · Tue, 4 Aug – Thu, 6 Aug',
      );
    });
  });

  group('formatEventDuration', () {
    test('formats minutes, hours and both together', () {
      expect(formatEventDuration(const Duration(minutes: 45)), '45 min');
      expect(formatEventDuration(const Duration(hours: 1)), '1 hr');
      expect(
          formatEventDuration(const Duration(hours: 1, minutes: 30)), '1 hr 30 min');
      expect(formatEventDuration(const Duration(days: 2, hours: 3)), '2 days 3 hr');
    });

    test('does not render a negative or zero length', () {
      expect(formatEventDuration(Duration.zero), '0 min');
      expect(formatEventDuration(const Duration(minutes: -30)), '0 min');
    });
  });

  group('describeEventRecurrence', () {
    test('is null for a one-off', () {
      expect(describeEventRecurrence(_event()), isNull);
    });

    test('names the frequency', () {
      expect(
        describeEventRecurrence(_event(
            recurrence: const CalendarRecurrence(
                frequency: RecurrenceFrequency.weekly))),
        'Weekly',
      );
    });

    test('spells out an interval and the weekdays', () {
      expect(
        describeEventRecurrence(_event(
          recurrence: const CalendarRecurrence(
            frequency: RecurrenceFrequency.weekly,
            interval: 2,
            daysOfWeek: [3, 1],
          ),
        )),
        'Every 2 weeks on Mon, Wed',
      );
    });

    test('adds an end date or an occurrence count', () {
      expect(
        describeEventRecurrence(_event(
          recurrence: CalendarRecurrence(
            frequency: RecurrenceFrequency.daily,
            endDate: DateTime(2026, 9, 30),
          ),
        )),
        'Daily until 30 Sep 2026',
      );
      expect(
        describeEventRecurrence(_event(
          recurrence: const CalendarRecurrence(
            frequency: RecurrenceFrequency.monthly,
            count: 10,
          ),
        )),
        'Monthly · 10 times',
      );
    });

    test('still says an occurrence repeats when the pattern is unresolved', () {
      // Occurrences don't carry the rule; resolving it from the series master
      // can fail, and "it repeats" is still worth showing.
      expect(describeEventRecurrence(_event(seriesMasterId: 'series-1')),
          'Repeating');
    });

    test('drops a weekday list that covers the whole week', () {
      expect(
        describeEventRecurrence(_event(
          recurrence: const CalendarRecurrence(
            frequency: RecurrenceFrequency.weekly,
            daysOfWeek: [1, 2, 3, 4, 5, 6, 7],
          ),
        )),
        'Weekly',
      );
    });
  });

  group('describeEventReminder', () {
    test('is null when the meeting has no reminder', () {
      expect(describeEventReminder(_event()), isNull);
    });

    test('scales the unit to the lead time', () {
      expect(describeEventReminder(_event(reminderMinutes: 0)),
          'Reminder at start');
      expect(describeEventReminder(_event(reminderMinutes: 15)),
          'Reminder 15 min before');
      expect(describeEventReminder(_event(reminderMinutes: 60)),
          'Reminder 1 hr before');
      expect(describeEventReminder(_event(reminderMinutes: 120)),
          'Reminder 2 hr before');
      expect(describeEventReminder(_event(reminderMinutes: 1440)),
          'Reminder 1 day before');
      expect(describeEventReminder(_event(reminderMinutes: 90)),
          'Reminder 90 min before');
    });
  });

  group('describeEventParticipation', () {
    test('reports the RSVP', () {
      expect(
        describeEventParticipation(
            _event(participation: MeetingParticipation.organizer)),
        'You organised this',
      );
      expect(
        describeEventParticipation(
            _event(participation: MeetingParticipation.needsAction)),
        'Not responded',
      );
      expect(
        describeEventParticipation(
            _event(participation: MeetingParticipation.declined)),
        'Declined',
      );
    });

    test('free/busy states outrank the RSVP', () {
      expect(
        describeEventParticipation(_event(
          status: CalendarEventStatus.outOfOffice,
          participation: MeetingParticipation.accepted,
        )),
        'Out of office',
      );
      expect(
        describeEventParticipation(
            _event(status: CalendarEventStatus.workingElsewhere)),
        'Working elsewhere',
      );
    });

    test('says nothing about a plain event with no participation signal', () {
      expect(describeEventParticipation(_event()), isNull);
    });
  });

  group('eventPreviewText', () {
    test('is empty when there is no body', () {
      expect(eventPreviewText(null), '');
      expect(eventPreviewText(''), '');
    });

    test('strips the HTML Google returns in description', () {
      expect(
        eventPreviewText('<p>Agenda</p><b>one</b><br>two'),
        'Agenda\none\ntwo',
      );
    });

    test('decodes entities without turning them back into markup', () {
      expect(eventPreviewText('Ben &amp; Jerry &lt;b&gt;'), 'Ben & Jerry <b>');
    });

    test('collapses blank lines and trims', () {
      expect(eventPreviewText('  one  \n\n\n   \ntwo\n'), 'one\ntwo');
    });

    test('leaves plain text alone', () {
      expect(eventPreviewText('Standing sync'), 'Standing sync');
    });
  });

  group('displayEventLocation', () {
    test('shortens a Teams join URL to something readable', () {
      expect(
        displayEventLocation(
            'https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc/0?context=%7b%22Tid%22%3a%22x%22%7d'),
        'https://teams.microsoft.com/join-meeting',
      );
    });

    test('passes any other location through', () {
      expect(displayEventLocation('Level 3, Room 2'), 'Level 3, Room 2');
    });
  });

  group('EventDetailsCard', () {
    Future<void> pumpCard(WidgetTester tester, CalendarEvent event) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(child: EventDetailsCard(event: event)),
        ),
      ));
    }

    testWidgets('shows what the tile is too small to show', (tester) async {
      await pumpCard(
        tester,
        _event(
          subject: 'Quarterly planning',
          location: 'Level 3, Room 2',
          bodyPreview: 'Bring the roadmap',
          reminderMinutes: 15,
          participation: MeetingParticipation.accepted,
          recurrence:
              const CalendarRecurrence(frequency: RecurrenceFrequency.weekly),
          attendees: const [
            CalendarEventAttendee(
              email: 'ada@example.com',
              displayName: 'Ada Lovelace',
              responseStatus: AttendeeResponseStatus.accepted,
            ),
          ],
        ),
      );

      expect(find.text('Quarterly planning'), findsOneWidget);
      expect(find.text('Tue, 4 Aug · 9:00 AM – 9:30 AM · 30 min'), findsOneWidget);
      expect(find.text('Level 3, Room 2'), findsOneWidget);
      expect(find.text('Weekly'), findsOneWidget);
      expect(find.text('Reminder 15 min before'), findsOneWidget);
      expect(find.text('Accepted'), findsOneWidget);
      expect(find.text('Attendees (1)'), findsOneWidget);
      expect(find.text('Ada Lovelace'), findsOneWidget);
      expect(find.text('Bring the roadmap'), findsOneWidget);
    });

    testWidgets('omits the rows a meeting has nothing for', (tester) async {
      await pumpCard(tester, _event(subject: 'Focus time'));

      expect(find.text('Focus time'), findsOneWidget);
      expect(find.textContaining('Attendees'), findsNothing);
      expect(find.textContaining('Reminder'), findsNothing);
    });

    testWidgets('falls back to the address for a guest with no name',
        (tester) async {
      await pumpCard(
        tester,
        _event(attendees: const [
          CalendarEventAttendee(email: 'bob@example.com'),
        ]),
      );

      expect(find.text('bob@example.com'), findsOneWidget);
    });

    testWidgets('counts off the guests it does not list', (tester) async {
      // A card that listed every guest of a 40-person invite would be taller
      // than the window.
      await pumpCard(
        tester,
        _event(
          attendees: List.generate(
            12,
            (i) => CalendarEventAttendee(email: 'guest$i@example.com'),
          ),
        ),
      );

      expect(find.text('Attendees (12)'), findsOneWidget);
      expect(find.text('guest0@example.com'), findsOneWidget);
      expect(find.text('guest7@example.com'), findsOneWidget);
      expect(find.text('guest8@example.com'), findsNothing);
      expect(find.text('+4 more'), findsOneWidget);
    });
  });

  group('EventHoverTarget', () {
    Future<void> pumpTarget(
      WidgetTester tester, {
      CalendarEvent? event,
      bool enabled = true,
    }) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: EventHoverTarget(
              event: event ?? _event(subject: 'Sprint review'),
              enabled: enabled,
              child: const SizedBox(
                width: 40,
                height: 14,
                child: Text('Sprint', maxLines: 1),
              ),
            ),
          ),
        ),
      ));
    }

    /// A mouse parked away from the tile, ready to move onto it.
    Future<TestGesture> mouse(WidgetTester tester) async {
      final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
      await gesture.addPointer(location: Offset.zero);
      addTearDown(gesture.removePointer);
      await tester.pump();
      return gesture;
    }

    Future<void> hoverTile(WidgetTester tester, TestGesture gesture) async {
      await gesture.moveTo(tester.getCenter(find.text('Sprint')));
      await tester.pump();
    }

    Finder card() => find.byType(EventDetailsCard);

    testWidgets('shows nothing until hovered', (tester) async {
      await pumpTarget(tester);
      expect(card(), findsNothing);
    });

    testWidgets('waits out the hover delay before opening', (tester) async {
      await pumpTarget(tester);
      final gesture = await mouse(tester);

      await hoverTile(tester, gesture);
      await tester.pump(const Duration(milliseconds: 250));
      expect(card(), findsNothing, reason: 'brushing past should show nothing');

      await tester.pump(const Duration(milliseconds: 200));
      expect(card(), findsOneWidget);
      expect(find.text('Sprint review'), findsOneWidget);
    });

    testWidgets('closes once the pointer leaves', (tester) async {
      await pumpTarget(tester);
      final gesture = await mouse(tester);
      await hoverTile(tester, gesture);
      await tester.pump(const Duration(milliseconds: 400));
      expect(card(), findsOneWidget);

      await gesture.moveTo(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 150));

      expect(card(), findsNothing);
    });

    testWidgets('leaving before the delay cancels the card', (tester) async {
      await pumpTarget(tester);
      final gesture = await mouse(tester);

      await hoverTile(tester, gesture);
      await tester.pump(const Duration(milliseconds: 200));
      await gesture.moveTo(const Offset(5, 5));
      await tester.pump(const Duration(milliseconds: 600));

      expect(card(), findsNothing);
    });

    testWidgets('does not open while the tile is being dragged',
        (tester) async {
      await pumpTarget(tester, enabled: false);
      final gesture = await mouse(tester);

      await hoverTile(tester, gesture);
      await tester.pump(const Duration(milliseconds: 600));

      expect(card(), findsNothing);
    });

    testWidgets('a drag starting under the pointer takes the card down',
        (tester) async {
      // Nothing else would: the pointer stays on the tile for the whole drag.
      await pumpTarget(tester);
      final gesture = await mouse(tester);
      await hoverTile(tester, gesture);
      await tester.pump(const Duration(milliseconds: 400));
      expect(card(), findsOneWidget);

      await pumpTarget(tester, enabled: false);
      await tester.pump();

      expect(card(), findsNothing);
    });

    testWidgets('the card does not intercept the hover holding it open',
        (tester) async {
      // The card is laid out over the tile, so if it took part in hit testing
      // it would trigger the tile's exit and flicker itself off.
      await pumpTarget(tester);
      final gesture = await mouse(tester);
      await hoverTile(tester, gesture);
      await tester.pump(const Duration(milliseconds: 400));

      await tester.pump(const Duration(milliseconds: 500));
      expect(card(), findsOneWidget);

      final ignoring = find.ancestor(
        of: card(),
        matching: find.byType(IgnorePointer),
      );
      expect(ignoring, findsWidgets);
    });

    testWidgets('a control on the tile keeps the card away', (tester) async {
      // The Join pill: the pointer is still inside the tile's own MouseRegion,
      // so only an explicit suppressor can take the card down.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Center(
            child: EventHoverTarget(
              event: _event(subject: 'Sprint review'),
              child: const SizedBox(
                width: 120,
                height: 40,
                child: Row(
                  children: [
                    SizedBox(width: 40, height: 14, child: Text('Sprint')),
                    EventHoverSuppressor(
                      child: SizedBox(
                        width: 40,
                        height: 14,
                        child: Text('Join'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ));

      final gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Join')));
      await tester.pump(const Duration(milliseconds: 600));
      expect(card(), findsNothing);

      // Back onto the tile proper: nothing else would reopen it, since the
      // pointer never left the tile.
      await hoverTile(tester, gesture);
      await tester.pump(const Duration(milliseconds: 600));
      expect(card(), findsOneWidget);

      // And an open card is taken down on the way in.
      await gesture.moveTo(tester.getCenter(find.text('Join')));
      await tester.pump(const Duration(milliseconds: 200));
      expect(card(), findsNothing);
    });

    testWidgets('keeps the card inside the window for a tile at the edge',
        (tester) async {
      tester.view.physicalSize = const Size(400, 300);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              // Bottom-right corner: the card can't go right of it or below it.
              Positioned(
                right: 0,
                bottom: 0,
                child: EventHoverTarget(
                  event: _event(subject: 'Sprint review'),
                  child: const SizedBox(
                    width: 40,
                    height: 14,
                    child: Text('Sprint', maxLines: 1),
                  ),
                ),
              ),
            ],
          ),
        ),
      ));

      final gesture = await mouse(tester);
      await gesture.moveTo(tester.getCenter(find.text('Sprint')));
      await tester.pump(const Duration(milliseconds: 400));

      expect(card(), findsOneWidget);
      final rect = tester.getRect(card());
      expect(rect.left, greaterThanOrEqualTo(0));
      expect(rect.top, greaterThanOrEqualTo(0));
      expect(rect.right, lessThanOrEqualTo(400));
      expect(rect.bottom, lessThanOrEqualTo(300));
    });
  });
}
