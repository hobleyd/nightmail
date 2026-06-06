import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/get_calendar_events.dart';
import 'calendar_event.dart';
import 'calendar_state.dart';

class CalendarBloc extends Bloc<CalendarBlocEvent, CalendarState> {
  CalendarBloc({required GetCalendarEvents getCalendarEvents})
      : _getCalendarEvents = getCalendarEvents,
        super(CalendarInitial(weekStart: _mondayOfWeek(DateTime.now()))) {
    on<CalendarWeekLoadRequested>(_onLoadRequested);
    on<CalendarWeekNavigated>(_onWeekNavigated);
  }

  final GetCalendarEvents _getCalendarEvents;

  Future<void> _onLoadRequested(
    CalendarWeekLoadRequested event,
    Emitter<CalendarState> emit,
  ) async {
    emit(CalendarLoading(weekStart: event.weekStart));
    await _fetchWeek(event.weekStart, emit);
  }

  Future<void> _onWeekNavigated(
    CalendarWeekNavigated event,
    Emitter<CalendarState> emit,
  ) async {
    emit(CalendarLoading(weekStart: event.weekStart));
    await _fetchWeek(event.weekStart, emit);
  }

  Future<void> _fetchWeek(
    DateTime weekStart,
    Emitter<CalendarState> emit,
  ) async {
    final start = weekStart.toUtc();
    final end = start.add(const Duration(days: 7));

    final result = await _getCalendarEvents(
      GetCalendarEventsParams(startDateTime: start, endDateTime: end),
    );

    result.fold(
      (failure) => emit(CalendarError(weekStart: weekStart, message: failure.message)),
      (events) => emit(CalendarLoaded(weekStart: weekStart, events: events)),
    );
  }

  static DateTime _mondayOfWeek(DateTime date) {
    final local = date.toLocal();
    final daysFromMonday = (local.weekday - 1) % 7;
    return DateTime(local.year, local.month, local.day - daysFromMonday);
  }
}
