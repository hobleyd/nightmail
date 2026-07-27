import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/core/utils/business_days.dart';
import 'package:nightmail/presentation/widgets/flag_icon_button.dart';

void main() {
  late List<DateTime> scheduled;
  late int taps;

  setUp(() {
    scheduled = [];
    taps = 0;
  });

  Future<void> pumpButton(WidgetTester tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: FlagIconButton(
            onTap: () => taps++,
            onSchedule: scheduled.add,
          ),
        ),
      ),
    ));
  }

  /// Right-clicks the flag, which is what opens the due-date menu.
  Future<void> openMenu(WidgetTester tester) async {
    final gesture = await tester.startGesture(
      tester.getCenter(find.byType(FlagIconButton)),
      buttons: kSecondaryButton,
    );
    await gesture.up();
    await tester.pumpAndSettle();
  }

  Future<void> choose(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
  }

  group('FlagIconButton', () {
    testWidgets('a plain click flags without opening the menu', (tester) async {
      await pumpButton(tester);

      await tester.tap(find.byType(IconButton));
      await tester.pumpAndSettle();

      expect(taps, 1);
      expect(find.text('Today'), findsNothing);
      expect(scheduled, isEmpty);
    });

    testWidgets('a right-click offers the due-date options', (tester) async {
      await pumpButton(tester);

      await openMenu(tester);

      expect(find.text('Today'), findsOneWidget);
      expect(find.text('Tomorrow'), findsOneWidget);
      expect(find.text('3 Days'), findsOneWidget);
      expect(find.text('This Week'), findsOneWidget);
      expect(find.text('Next Week'), findsOneWidget);
      expect(find.text('Custom…'), findsOneWidget);
      expect(taps, 0, reason: 'a right-click must not also flag');
    });

    testWidgets('dismissing the menu schedules nothing', (tester) async {
      await pumpButton(tester);
      await openMenu(tester);

      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      expect(scheduled, isEmpty);
      expect(taps, 0);
    });

    testWidgets('Today resolves to midnight today', (tester) async {
      await pumpButton(tester);
      await openMenu(tester);

      await choose(tester, 'Today');

      final now = DateTime.now();
      expect(scheduled.single, DateTime(now.year, now.month, now.day));
    });

    testWidgets('Tomorrow resolves to the next business day', (tester) async {
      await pumpButton(tester);
      await openMenu(tester);

      await choose(tester, 'Tomorrow');

      expect(scheduled.single, addBusinessDays(DateTime.now(), 1));
    });

    testWidgets('3 Days resolves three business days out', (tester) async {
      await pumpButton(tester);
      await openMenu(tester);

      await choose(tester, '3 Days');

      expect(scheduled.single, addBusinessDays(DateTime.now(), 3));
    });

    testWidgets('This Week resolves to an upcoming Friday morning',
        (tester) async {
      await pumpButton(tester);
      await openMenu(tester);

      await choose(tester, 'This Week');

      final due = scheduled.single;
      expect(due.weekday, DateTime.friday);
      expect(due.hour, followUpMorningHour);
      // Friday afternoon onwards (and the weekend) rolls to the week after,
      // so this is always still ahead of us.
      expect(due.isAfter(DateTime.now()), isTrue);
    });

    testWidgets('Next Week resolves to a Friday morning no earlier than This '
        'Week', (tester) async {
      await pumpButton(tester);

      await openMenu(tester);
      await choose(tester, 'This Week');
      await openMenu(tester);
      await choose(tester, 'Next Week');

      final [thisWeek, nextWeek] = scheduled;
      expect(nextWeek.weekday, DateTime.friday);
      expect(nextWeek.hour, followUpMorningHour);
      // Equal once this week's Friday morning has passed, since This Week has
      // rolled forward to the same day by then.
      expect(nextWeek.difference(thisWeek).inDays, anyOf(0, 7));
    });

    testWidgets('Custom… opens a date picker rather than scheduling directly',
        (tester) async {
      await pumpButton(tester);
      await openMenu(tester);

      await choose(tester, 'Custom…');

      expect(find.byType(DatePickerDialog), findsOneWidget);
      expect(scheduled, isEmpty);

      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      expect(scheduled, isEmpty, reason: 'a cancelled picker schedules nothing');
    });

    testWidgets('a date picked in Custom… is scheduled', (tester) async {
      await pumpButton(tester);
      await openMenu(tester);
      await choose(tester, 'Custom…');

      await tester.tap(find.text('OK'));
      await tester.pumpAndSettle();

      // The picker opens on today, so confirming it schedules today.
      final now = DateTime.now();
      expect(scheduled.single, DateTime(now.year, now.month, now.day));
    });
  });
}
