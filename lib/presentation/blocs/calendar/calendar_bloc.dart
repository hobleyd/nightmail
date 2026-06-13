import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/cancel_calendar_event.dart';
import '../../../domain/usecases/decline_calendar_event.dart';
import '../../../domain/usecases/get_calendar_events.dart';
import '../../../domain/usecases/propose_new_time.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import 'calendar_event.dart';
import 'calendar_state.dart';

class CalendarBloc extends Bloc<CalendarBlocEvent, CalendarState> {
  CalendarBloc({
    required GetCalendarEvents getCalendarEvents,
    required CancelCalendarEvent cancelCalendarEvent,
    required DeclineCalendarEvent declineCalendarEvent,
    required ProposeNewTime proposeNewTime,
    required UpdateCalendarEvent updateCalendarEvent,
  })  : _getCalendarEvents = getCalendarEvents,
        _cancelCalendarEvent = cancelCalendarEvent,
        _declineCalendarEvent = declineCalendarEvent,
        _proposeNewTime = proposeNewTime,
        _updateCalendarEvent = updateCalendarEvent,
        super(CalendarInitial(weekStart: _mondayOfWeek(DateTime.now()))) {
    on<CalendarWeekLoadRequested>(_onLoadRequested);
    on<CalendarWeekNavigated>(_onWeekNavigated);
    on<CalendarEventCancelRequested>(_onCancelRequested);
    on<CalendarEventDeclineRequested>(_onDeclineRequested);
    on<CalendarEventNewTimeProposed>(_onNewTimeProposed);
    on<CalendarEventRescheduleRequested>(_onRescheduleRequested);
    on<CalendarEventSelectionToggled>(_onSelectionToggled);
    on<CalendarSelectionCleared>(_onSelectionCleared);
    on<CalendarSelectedEventsDeleteRequested>(_onSelectedEventsDeleteRequested);
  }

  final GetCalendarEvents _getCalendarEvents;
  final CancelCalendarEvent _cancelCalendarEvent;
  final DeclineCalendarEvent _declineCalendarEvent;
  final ProposeNewTime _proposeNewTime;
  final UpdateCalendarEvent _updateCalendarEvent;

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

  Future<void> _onRescheduleRequested(
    CalendarEventRescheduleRequested blocEvent,
    Emitter<CalendarState> emit,
  ) async {
    final weekStart = state.weekStart;
    final e = blocEvent.event;
    final result = await _updateCalendarEvent(UpdateCalendarEventParams(
      id: e.id,
      subject: e.subject,
      start: blocEvent.newStart,
      end: blocEvent.newEnd,
      isAllDay: e.isAllDay,
      timezone: e.timezone ?? 'UTC',
      location: e.location,
      description: e.bodyPreview,
      attendeeEmails: e.attendees.map((a) => a.email).toList(),
      recurrence: e.recurrence,
    ));
    result.fold(
      (failure) => emit(CalendarError(weekStart: weekStart, message: failure.message)),
      (_) {},
    );
    if (result.isRight()) await _fetchWeek(weekStart, emit);
  }

  void _onSelectionToggled(
    CalendarEventSelectionToggled event,
    Emitter<CalendarState> emit,
  ) {
    if (state is! CalendarLoaded) return;
    final loaded = state as CalendarLoaded;
    final current = Set<String>.of(loaded.selectedEventIds);
    if (event.addToSelection) {
      if (!current.remove(event.eventId)) current.add(event.eventId);
    } else {
      if (current.length == 1 && current.contains(event.eventId)) {
        current.clear();
      } else {
        current
          ..clear()
          ..add(event.eventId);
      }
    }
    emit(loaded.copyWithSelection(current));
  }

  void _onSelectionCleared(
    CalendarSelectionCleared event,
    Emitter<CalendarState> emit,
  ) {
    if (state is! CalendarLoaded) return;
    final loaded = state as CalendarLoaded;
    if (loaded.selectedEventIds.isEmpty) return;
    emit(loaded.copyWithSelection(const {}));
  }

  Future<void> _onSelectedEventsDeleteRequested(
    CalendarSelectedEventsDeleteRequested event,
    Emitter<CalendarState> emit,
  ) async {
    if (state is! CalendarLoaded) return;
    final loaded = state as CalendarLoaded;
    final weekStart = loaded.weekStart;
    final selected = loaded.events
        .where((e) => loaded.selectedEventIds.contains(e.id))
        .toList();
    for (final e in selected) {
      if (e.isOrganizer) {
        await _cancelCalendarEvent(CancelCalendarEventParams(eventId: e.id));
      } else {
        await _declineCalendarEvent(DeclineCalendarEventParams(eventId: e.id));
      }
    }
    await _fetchWeek(weekStart, emit);
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
