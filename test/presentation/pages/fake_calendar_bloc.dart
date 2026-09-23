import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_bloc.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_event.dart';
import 'package:nightmail/presentation/blocs/calendar/calendar_state.dart';

/// A CalendarBloc that answers every navigation the way the real one would
/// once the fetch lands: the same events, re-keyed to the requested range.
///
/// `context.read<CalendarBloc>()` needs a bloc in the tree, and the real one
/// wants a service locator full of use cases.
class FakeCalendarBloc extends Fake implements CalendarBloc {
  FakeCalendarBloc(this._state);

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
