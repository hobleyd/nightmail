// On a phone the calendar is the day panel pushed as a route, and its toggle
// cycles Day → Week → Full Week → Month → Day, reusing the calendar window's
// week and month views. The docked desktop panel has no such toggle. Pinned
// because the cycle order, the fetch span each step asks for, and the reset
// on leaving the month are all invisible to the analyzer.
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_bloc.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_state.dart';
import 'package:nightmail/presentation/pages/calendar_page.dart';

import 'fake_calendar_bloc.dart';

DateTime _mondayOf(DateTime d) =>
    DateTime(d.year, d.month, d.day - (d.weekday - 1));

void main() {
  late FakeCalendarBloc bloc;
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);

  Future<void> pumpPanel(WidgetTester tester,
      {bool useBackNavigation = true, double width = 400}) async {
    tester.view.physicalSize = Size(width, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // A meeting today, 10am–2pm: half of 9–5.
    bloc = FakeCalendarBloc(CalendarLoaded(
      weekStart: _mondayOf(today),
      events: [
        CalendarEvent(
          id: 'e1',
          subject: 'Planning',
          start: today.add(const Duration(hours: 10)),
          end: today.add(const Duration(hours: 14)),
          isAllDay: false,
        ),
      ],
    ));
    addTearDown(bloc.close);
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<CalendarBloc>.value(
        value: bloc,
        child: Scaffold(
          body: CalendarDayPanel(
            onClose: () {},
            useBackNavigation: useBackNavigation,
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> tapToggle(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the docked desktop panel has no span toggle', (tester) async {
    await pumpPanel(tester, useBackNavigation: false);
    expect(find.textContaining('→'), findsNothing);
  });

  // The test font draws every glyph a full em wide, so a 400px phone is well
  // short of what a single row needs and the controls drop under the title.
  testWidgets('too narrow for one row, the controls take a second row',
      (tester) async {
    await pumpPanel(tester);

    final toggle = tester.getCenter(find.text('Day → Week'));
    final prev = tester.getCenter(find.byTooltip('Previous day'));
    // Below the 48px title row, and on the same row as the nav cluster.
    expect(toggle.dy, greaterThan(48));
    expect(prev.dy, toggle.dy);
  });

  testWidgets('with room for everything the header stays on one row',
      (tester) async {
    await pumpPanel(tester, width: 900);

    final title = tester.getCenter(find.text(DateFormat('EEEE').format(today)));
    final toggle = tester.getCenter(find.text('Day → Week'));
    final prev = tester.getCenter(find.byTooltip('Previous day'));
    // Everything inside the single 48px row.
    expect(toggle.dy, lessThan(48));
    expect(prev.dy, toggle.dy);
    // Left to right: title, nav cluster, toggle.
    expect(title.dx, lessThan(prev.dx));
    expect(prev.dx, lessThan(toggle.dx));
  });

  testWidgets('cycles Day → Week → Full Week → Month → Day', (tester) async {
    await pumpPanel(tester);

    expect(find.text('Day → Week'), findsOneWidget);
    expect(find.text(DateFormat('EEEE').format(today)), findsOneWidget);
    expect(find.byTooltip('Previous day'), findsOneWidget);

    // Week: five columns, the loaded week already covers it — no fetch.
    await tapToggle(tester, 'Day → Week');
    expect(find.text('Week → Full Week'), findsOneWidget);
    expect(find.text('MON'), findsOneWidget);
    expect(find.text('SAT'), findsNothing);
    expect(find.byTooltip('Previous week'), findsOneWidget);
    expect(bloc.navigated, isEmpty);

    await tapToggle(tester, 'Week → Full Week');
    expect(find.text('Full Week → Month'), findsOneWidget);
    expect(find.text('SAT'), findsOneWidget);
    expect(bloc.navigated, isEmpty);

    // Month: asks for the six-week grid around the selected day.
    await tapToggle(tester, 'Full Week → Month');
    expect(find.text('Month → Day'), findsOneWidget);
    expect(find.text(DateFormat('MMMM yyyy').format(today)), findsOneWidget);
    expect(find.byTooltip('Previous month'), findsOneWidget);
    expect(bloc.navigated.single.spanDays, 42);
    expect(bloc.navigated.single.weekStart.weekday, DateTime.monday);
    expect(bloc.navigated.single.weekStart.isAfter(today), isFalse);
    // Today's cell carries the half-day bar.
    expect(find.text('50%'), findsOneWidget);

    // Back to the day, and the bloc is put back on a one-week span so the
    // rest of the app is not left re-fetching six weeks.
    await tapToggle(tester, 'Month → Day');
    expect(find.text('Day → Week'), findsOneWidget);
    expect(find.text(DateFormat('EEEE').format(today)), findsOneWidget);
    expect(bloc.navigated.last.spanDays, 7);
    expect(bloc.navigated.last.weekStart, _mondayOf(today));
  });

  testWidgets('week navigation steps seven days and refetches when it leaves '
      'the loaded week', (tester) async {
    await pumpPanel(tester);
    await tapToggle(tester, 'Day → Week');

    await tester.tap(find.byTooltip('Next week'));
    await tester.pump();
    await tester.pump();

    final nextMonday = _mondayOf(today).add(const Duration(days: 7));
    expect(bloc.navigated.single.weekStart, nextMonday);
    expect(bloc.navigated.single.spanDays, 7);
    expect(find.text('Today'), findsOneWidget);
  });

  testWidgets('closing the panel in the month view resets the span',
      (tester) async {
    await pumpPanel(tester);
    await tapToggle(tester, 'Day → Week');
    await tapToggle(tester, 'Week → Full Week');
    await tapToggle(tester, 'Full Week → Month');
    expect(bloc.state.spanDays, 42);

    await tester.pumpWidget(const SizedBox());
    expect(bloc.state.spanDays, 7);
  });
}
