import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/domain/entities/commitment.dart';
import 'package:nightmail/domain/entities/email_address.dart';
import 'package:nightmail/domain/usecases/commitments/suggest_time_block.dart';
import 'package:nightmail/presentation/widgets/commitments/schedule_commitment_dialog.dart';

/// The scheduling dialog in both layouts, driven by a real `SuggestTimeBlock`
/// over a fixed week so the suggestion and the manual moves are deterministic.
void main() {
  const suggester = SuggestTimeBlock();
  // intl renders "9:00 AM" with a narrow no-break space before AM, so expected
  // strings are built with the same formatter the dialog uses.
  final jm = DateFormat.jm();
  String range(DateTime a, DateTime b) => '${jm.format(a)} – ${jm.format(b)}';

  // Tuesday 6 October 2026, 09:00.
  final now = DateTime(2026, 10, 6, 9);
  final tue = DateTime(2026, 10, 6);
  final wed = DateTime(2026, 10, 7);
  final thu = DateTime(2026, 10, 8);

  DateTime at(DateTime day, int hour, [int minute = 0]) =>
      DateTime(day.year, day.month, day.day, hour, minute);

  final commitment = Commitment(
    id: 'iOwe:s1',
    accountId: 'acc',
    emailId: 's1',
    kind: CommitmentKind.iOwe,
    status: CommitmentStatus.open,
    counterpart: const EmailAddress(address: 'sarah@client.com', name: 'Sarah'),
    subject: 'Migration numbers',
    snippet: "I'll send the numbers.",
    due: CommitmentDue.thisWeek,
    urgency: 1,
    confidence: 0.9,
    emailDate: now,
    detectedAt: now,
  );

  final events = [
    CalendarEvent(
      id: 'e1',
      subject: 'Tuesday standup',
      start: at(tue, 9),
      end: at(tue, 12),
      isAllDay: false,
    ),
    CalendarEvent(
      id: 'e2',
      subject: 'Wednesday review',
      start: at(wed, 10),
      end: at(wed, 11),
      isAllDay: false,
    ),
  ];

  final suggestion = suggester(commitment: commitment, events: events, now: now);

  Future<_Harness> pump(
    WidgetTester tester, {
    required bool wide,
    bool accept = true,
  }) async {
    final h = _Harness();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Center(
              child: ElevatedButton(
                onPressed: () async {
                  h.result = await showDialog<bool>(
                    context: context,
                    builder: (_) => ScheduleCommitmentDialog(
                      commitment: commitment,
                      suggestion: suggestion,
                      suggester: suggester,
                      wide: wide,
                      now: () => now,
                      onSchedule: (start, end) async {
                        h.calls.add((start, end));
                        return accept;
                      },
                    ),
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return h;
  }

  group('compact layout', () {
    testWidgets('opens on the suggestion and books it on confirm',
        (tester) async {
      final h = await pump(tester, wide: false);

      expect(find.text('Schedule time'), findsOneWidget);
      // Thursday is the clear day this week.
      expect(suggestion.start, at(thu, 9));
      expect(find.textContaining('Thursday'), findsWidgets);
      expect(find.text('Thursday 8 October · ${range(at(thu, 9), at(thu, 10))}'), findsOneWidget);
      // Every candidate day is listed with its load.
      expect(find.textContaining('Tue 6 Oct'), findsOneWidget);
      expect(find.text('3 h busy'), findsOneWidget);
      expect(find.text('clear'), findsNWidgets(2)); // Thursday, Friday

      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();

      expect(h.calls, [(at(thu, 9), at(thu, 10))]);
      expect(h.result, isTrue);
      expect(find.text('Schedule time'), findsNothing);
    });

    testWidgets('picking another day moves the block to its first free slot',
        (tester) async {
      final h = await pump(tester, wide: false);

      await tester.tap(find.textContaining('Wed 7 Oct'));
      await tester.pumpAndSettle();
      // Wednesday is free at 9:00 (the review is at 10).
      expect(find.text('Wednesday 7 October · ${range(at(wed, 9), at(wed, 10))}'), findsOneWidget);

      // A longer block from 9:00 now runs into the 10:00 review.
      await tester.tap(find.text('1.5 h'));
      await tester.pumpAndSettle();
      expect(find.text('Overlaps a meeting on your calendar.'), findsOneWidget);

      // Move the start past it.
      await tester.tap(find.byType(DropdownButton<DateTime>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(jm.format(at(wed, 11))).last);
      await tester.pumpAndSettle();
      expect(find.text('Overlaps a meeting on your calendar.'), findsNothing);

      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      expect(h.calls, [(at(wed, 11), at(wed, 12, 30))]);
    });

    testWidgets('a refused booking keeps the dialog open with an error',
        (tester) async {
      final h = await pump(tester, wide: false, accept: false);

      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();

      expect(h.calls, hasLength(1));
      expect(find.text('Schedule time'), findsOneWidget);
      expect(find.textContaining('did not accept'), findsOneWidget);
    });
  });

  group('wide layout', () {
    testWidgets('draws the week with meetings and the proposed block, and a '
        'click in a day column moves the block there', (tester) async {
      tester.view.physicalSize = const Size(1400, 900);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final h = await pump(tester, wide: true);

      // Day headers and the meetings drawn to scale.
      expect(find.textContaining('Tue 6 Oct'), findsOneWidget);
      expect(find.textContaining('Wed 7 Oct'), findsOneWidget);
      expect(find.text('Tuesday standup'), findsOneWidget);
      expect(find.text('Wednesday review'), findsOneWidget);
      // The proposed block carries its time range.
      expect(find.text(range(at(thu, 9), at(thu, 10))), findsOneWidget);
      expect(find.text('Click anywhere in a day to move the block there.'),
          findsOneWidget);

      // Tap in Wednesday's column at about mid-afternoon: the block lands
      // on that day, snapped to the slot grid, inside the working window.
      final wedColumn = find.byKey(const ValueKey('schedule-day-2026-10-07'));
      expect(wedColumn, findsOneWidget);
      final rect = tester.getRect(wedColumn);
      await tester.tapAt(Offset(rect.center.dx, rect.top + rect.height * 0.7));
      await tester.pumpAndSettle();

      expect(find.textContaining('Wednesday 7 October'), findsOneWidget);
      await tester.tap(find.text('Schedule'));
      await tester.pumpAndSettle();
      final (start, end) = h.calls.single;
      expect(start.day, 7);
      expect(start.hour, inInclusiveRange(9, 16));
      expect(start.minute % 30, 0);
      expect(end.difference(start), const Duration(hours: 1));
    });
  });
}

/// What the dialog did: the bookings it asked for and how it closed. A class,
/// not a record, because the dialog's result lands after `pump` returns.
class _Harness {
  final calls = <(DateTime, DateTime)>[];
  bool? result;
}
