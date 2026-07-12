import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/cancel_calendar_event.dart'
    show
        CancelCalendarEvent,
        CancelCalendarEventParams,
        CancelCalendarEventSeries,
        CancelCalendarEventSeriesParams;
import '../../../domain/usecases/decline_calendar_event.dart';
import '../../../domain/usecases/get_calendar_events.dart';
import '../../../domain/usecases/propose_new_time.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import '../../../infrastructure/notifications/notification_service.dart';
import 'calendar_event.dart';
import 'calendar_state.dart';

class CalendarBloc extends Bloc<CalendarBlocEvent, CalendarState> {
  CalendarBloc({
    required GetCalendarEvents getCalendarEvents,
    required CancelCalendarEvent cancelCalendarEvent,
    required CancelCalendarEventSeries cancelCalendarEventSeries,
    required DeclineCalendarEvent declineCalendarEvent,
    required ProposeNewTime proposeNewTime,
    required UpdateCalendarEvent updateCalendarEvent,
    required NotificationService notificationService,
    required AccountManager accountManager,
  })  : _getCalendarEvents = getCalendarEvents,
        _cancelCalendarEvent = cancelCalendarEvent,
        _cancelCalendarEventSeries = cancelCalendarEventSeries,
        _declineCalendarEvent = declineCalendarEvent,
        _proposeNewTime = proposeNewTime,
        _updateCalendarEvent = updateCalendarEvent,
        _notificationService = notificationService,
        _accountManager = accountManager,
        super(CalendarInitial(weekStart: _mondayOfWeek(DateTime.now()))) {
    on<CalendarWeekLoadRequested>(_onLoadRequested);
    on<CalendarWeekNavigated>(_onWeekNavigated);
    on<CalendarEventCancelRequested>(_onCancelRequested);
    on<CalendarEventCancelSeriesRequested>(_onCancelSeriesRequested);
    on<CalendarEventDeclineRequested>(_onDeclineRequested);
    on<CalendarEventNewTimeProposed>(_onNewTimeProposed);
    on<CalendarEventRescheduleRequested>(_onRescheduleRequested);
    on<CalendarEventSelectionToggled>(_onSelectionToggled);
    on<CalendarSelectionCleared>(_onSelectionCleared);
    on<CalendarSelectedEventsDeleteRequested>(_onSelectedEventsDeleteRequested);
    on<CalendarCleared>(_onCleared);
  }

  final GetCalendarEvents _getCalendarEvents;
  final CancelCalendarEvent _cancelCalendarEvent;
  final CancelCalendarEventSeries _cancelCalendarEventSeries;
  final DeclineCalendarEvent _declineCalendarEvent;
  final ProposeNewTime _proposeNewTime;
  final UpdateCalendarEvent _updateCalendarEvent;
  final NotificationService _notificationService;
  final AccountManager _accountManager;

  static const _calendarRefreshChannel =
      MethodChannel('au.com.sharpblue.nightmail/calendar_refresh');

  Future<void> _notifyOtherWindows() async {
    await _calendarRefreshChannel.invokeMethod('notifyEventSaved');
  }

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
    if (result.isRight()) {
      await _cancelReminder(event.eventId);
      await _notifyOtherWindows();
      await _fetchWeek(weekStart, emit);
    }
  }

  Future<void> _onCancelSeriesRequested(
    CalendarEventCancelSeriesRequested event,
    Emitter<CalendarState> emit,
  ) async {
    final weekStart = state.weekStart;
    final result = await _cancelCalendarEventSeries(
      CancelCalendarEventSeriesParams(
        eventId: event.eventId,
        seriesMasterId: event.seriesMasterId,
        occurrenceStart: event.occurrenceStart,
      ),
    );
    result.fold(
      (failure) => emit(CalendarError(weekStart: weekStart, message: failure.message)),
      (_) {},
    );
    if (result.isRight()) {
      await _cancelReminder(event.eventId);
      await _notifyOtherWindows();
      await _fetchWeek(weekStart, emit);
    }
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
    if (result.isRight()) {
      await _cancelReminder(event.eventId);
      await _notifyOtherWindows();
      await _fetchWeek(weekStart, emit);
    }
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
        message: event.message,
      ),
    );
    result.fold(
      (failure) => emit(CalendarError(weekStart: weekStart, message: failure.message)),
      (_) {},
    );
    if (result.isRight()) {
      await _notifyOtherWindows();
      await _fetchWeek(weekStart, emit);
    }
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
      reminderMinutes: e.reminderMinutes,
    ));
    if (result.isRight() && e.reminderMinutes != null) {
      await _cancelReminder(e.id);
      await _scheduleReminder(
        eventId: e.id,
        eventTitle: e.subject,
        startUtc: blocEvent.newStart,
        reminderMinutes: e.reminderMinutes!,
      );
    }
    result.fold(
      (failure) => emit(CalendarError(weekStart: weekStart, message: failure.message)),
      (_) {},
    );
    if (result.isRight()) {
      await _notifyOtherWindows();
      await _fetchWeek(weekStart, emit);
    }
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
      await _cancelReminder(e.id);
    }
    await _notifyOtherWindows();
    await _fetchWeek(weekStart, emit);
  }

  void _onCleared(CalendarCleared event, Emitter<CalendarState> emit) {
    emit(CalendarInitial(weekStart: _mondayOfWeek(DateTime.now())));
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

  // Fast-path cancellation for the app's own cancel/decline/delete/reschedule
  // actions — the periodic CalendarReminderService reconciliation is the
  // safety net that also catches changes made from other clients, but it
  // runs on a ~15min cadence, which would otherwise let a just-cancelled
  // meeting's reminder fire before the next cycle catches it.
  Future<void> _cancelReminder(String eventId) async {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    await _notificationService.cancelEventReminder(
      accountId: accountId,
      eventId: eventId,
    );
  }

  Future<void> _scheduleReminder({
    required String eventId,
    required String eventTitle,
    required DateTime startUtc,
    required int reminderMinutes,
  }) async {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    await _notificationService.scheduleEventReminder(
      accountId: accountId,
      eventId: eventId,
      eventTitle: eventTitle,
      startUtc: startUtc,
      reminderMinutes: reminderMinutes,
      startIso: startUtc.toIso8601String(),
    );
  }
}
