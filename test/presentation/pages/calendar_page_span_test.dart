// The calendar window's span toggle cycles Working Week → Full Week → Month →
// Working Week, and the month step asks the bloc for a six-week range while
// the week steps ask for one. The month grid draws a 9–5 meeting-load bar per
// day. Pinned here because a slip in the cycle order or the fetch span is
// invisible to the analyzer and the bloc tests alone.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/domain/entities/calendar_event.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_bloc.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_event.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_state.dart';
import 'package:nightmail/presentation/pages/calendar_page.dart';

/// Answers a navigation the way the real bloc would once the fetch lands: the
/// same events, re-keyed to the requested range.
class _FakeCalendarBloc extends Fake implements CalendarBloc {
  _FakeCalendarBloc(this._state);

  CalendarLoaded _state;
  final _controller = StreamController<CalendarState>.broadcast();
  final navigated = <CalendarWeekNavigated>[];

  @override
  CalendarState get state => _state;

  @override
  Stream<CalendarState> get stream => _controller.stream;

  @override
  void add(CalendarBlocEvent event) {
    if (event is CalendarWeekNavigated) {
      navigated.add(event);
      _state = CalendarLoaded(
        weekStart: event.weekStart,
        spanDays: event.spanDays ?? _state.spanDays,
        events: _state.events,
      );
      _controller.add(_state);
    }
  }

  @override
  Future<void> close() async => _controller.close();
}

final _monday = DateTime(2026, 9, 21);

/// Wednesday 23 September, 10am–2pm: four of the eight working hours.
final _events = [
  CalendarEvent(
    id: 'e1',
    subject: 'Planning',
    start: DateTime(2026, 9, 23, 10),
    end: DateTime(2026, 9, 23, 14),
    isAllDay: false,
  ),
];

void main() {
  late _FakeCalendarBloc bloc;

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    bloc = _FakeCalendarBloc(
        CalendarLoaded(weekStart: _monday, events: _events));
    addTearDown(bloc.close);
    await tester.pumpWidget(MaterialApp(
      home: BlocProvider<CalendarBloc>.value(
        value: bloc,
        child: const Scaffold(body: CalendarPage()),
      ),
    ));
    await tester.pump();
  }

  Future<void> tapToggle(WidgetTester tester, String label) async {
    await tester.tap(find.text(label));
    await tester.pump();
    await tester.pump();
  }

  testWidgets('the arrows bracket the range label on the left of the header',
      (tester) async {
    await pumpPage(tester);

    final prev = tester.getCenter(find.byTooltip('Previous week'));
    final label = tester.getCenter(find.text('September 21 – 25, 2026'));
    final next = tester.getCenter(find.byTooltip('Next week'));
    final newEvent = tester.getCenter(find.text('New Event'));

    expect(prev.dx, lessThan(label.dx));
    expect(label.dx, lessThan(next.dx));
    expect(next.dx, lessThan(newEvent.dx));
    // Left of centre: this is the leading group, not the trailing one.
    expect(next.dx, lessThan(700));
  });

  testWidgets('the toggle cycles Working Week → Full Week → Month → Working Week',
      (tester) async {
    await pumpPage(tester);

    // Opens on the working week; the button spells out the step it takes.
    expect(find.text('Working Week → Full Week'), findsOneWidget);
    expect(find.text('SAT'), findsNothing);

    await tapToggle(tester, 'Working Week → Full Week');
    expect(find.text('Full Week → Month'), findsOneWidget);
    expect(find.text('SAT'), findsOneWidget);
    expect(find.text('September 21 – 27, 2026'), findsOneWidget);
    // Full week and working week draw from the same seven days.
    expect(bloc.navigated, isEmpty);

    await tapToggle(tester, 'Full Week → Month');
    expect(find.text('Month → Working Week'), findsOneWidget);
    expect(find.text('September 2026'), findsOneWidget);
    expect(bloc.navigated.single.spanDays, 42);
    // The Monday on or before 1 September 2026 (a Tuesday).
    expect(bloc.navigated.single.weekStart, DateTime(2026, 8, 31));
    expect(find.byTooltip('Previous month'), findsOneWidget);

    await tapToggle(tester, 'Month → Working Week');
    expect(find.text('Working Week → Full Week'), findsOneWidget);
    expect(bloc.navigated.last.spanDays, 7);
    expect(bloc.navigated.last.weekStart.weekday, DateTime.monday);
    expect(find.text('SAT'), findsNothing);
  });

  testWidgets('the month grid shows each day\'s share of 9–5 in meetings',
      (tester) async {
    await pumpPage(tester);
    await tapToggle(tester, 'Working Week → Full Week');
    await tapToggle(tester, 'Full Week → Month');

    // 42 cells; the one with the four-hour meeting reads 50%, the rest 0%.
    expect(find.text('50%'), findsOneWidget);
    expect(find.text('0%'), findsNWidgets(41));
    expect(find.byTooltip('50% of 9am–5pm in meetings'), findsOneWidget);
  });

  testWidgets('month navigation steps a whole month and keeps the span',
      (tester) async {
    await pumpPage(tester);
    await tapToggle(tester, 'Working Week → Full Week');
    await tapToggle(tester, 'Full Week → Month');

    await tester.tap(find.byTooltip('Next month'));
    await tester.pump();
    await tester.pump();

    expect(find.text('October 2026'), findsOneWidget);
    final last = bloc.navigated.last;
    expect(last.spanDays, 42);
    // 1 October 2026 is a Thursday; its grid starts on Monday 28 September.
    expect(last.weekStart, DateTime(2026, 9, 28));
  });
}
