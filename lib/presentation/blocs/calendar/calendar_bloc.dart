import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/cancel_calendar_event.dart';
import '../../../domain/usecases/decline_calendar_event.dart';
import '../../../domain/usecases/get_calendar_events.dart';
import '../../../domain/usecases/propose_new_time.dart';
import 'calendar_event.dart';
import 'calendar_state.dart';

class CalendarBloc extends Bloc<CalendarBlocEvent, CalendarState> {
  CalendarBloc({
    required GetCalendarEvents getCalendarEvents,
    required CancelCalendarEvent cancelCalendarEvent,
    required DeclineCalendarEvent declineCalendarEvent,
    required ProposeNewTime proposeNewTime,
  })  : _getCalendarEvents = getCalendarEvents,
        _cancelCalendarEvent = cancelCalendarEvent,
        _declineCalendarEvent = declineCalendarEvent,
        _proposeNewTime = proposeNewTime,
        super(CalendarInitial(weekStart: _mondayOfWeek(DateTime.now()))) {
    on<CalendarWeekLoadRequested>(_onLoadRequested);
    on<CalendarWeekNavigated>(_onWeekNavigated);
    on<CalendarEventCancelRequested>(_onCancelRequested);
    on<CalendarEventDeclineRequested>(_onDeclineRequested);
    on<CalendarEventNewTimeProposed>(_onNewTimeProposed);
  }

  final GetCalendarEvents _getCalendarEvents;
  final CancelCalendarEvent _cancelCalendarEvent;
  final DeclineCalendarEvent _declineCalendarEvent;
  final ProposeNewTime _proposeNewTime;

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

  Future<void> _onCancelRequested(
    CalendarEventCancelRequested event,
    Emitter<CalendarState> emit,
  ) async {
    final weekStart = state.weekStart;
    final result = await _cancelCalendarEvent(
      CancelCalendarEventParams(eventId: event.eventId),
    );
    result.fold(
      (failure) => emit(CalendarError(weekStart: weekStart, message: failure.message)),
      (_) {},
    );
    if (result.isRight()) await _fetchWeek(weekStart, emit);
  }

  Future<void> _onDeclineRequested(
    CalendarEventDeclineRequested event,
    Emitter<CalendarState> emit,
  ) async {
    final weekStart = state.weekStart;
    final result = await _declineCalendarEvent(
      DeclineCalendarEventParams(eventId: event.eventId),
    );
    result.fold(
      (failure) => emit(CalendarError(weekStart: weekStart, message: failure.message)),
      (_) {},
    );
    if (result.isRight()) await _fetchWeek(weekStart, emit);
  }

  Future<void> _onNewTimeProposed(
    CalendarEventNewTimeProposed event,
    Emitter<CalendarState> emit,
  ) async {
    final weekStart = state.weekStart;
    final result = await _proposeNewTime(
      ProposeNewTimeParams(
        eventId: event.eventId,
        newStart: event.newStart,
        newEnd: event.newEnd,
        timezone: event.timezone,
      ),
    );
    result.fold(
      (failure) => emit(CalendarError(weekStart: weekStart, message: failure.message)),
      (_) {},
    );
    if (result.isRight()) await _fetchWeek(weekStart, emit);
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
