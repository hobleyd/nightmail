import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../../infrastructure/notifications/notification_service.dart';
import 'event_edit_event.dart';
import 'event_edit_state.dart';

class EventEditBloc extends Bloc<EventEditBlocEvent, EventEditState> {
  EventEditBloc({
    required CreateCalendarEvent createCalendarEvent,
    required UpdateCalendarEvent updateCalendarEvent,
    required NotificationService notificationService,
    this.accountId,
  })  : _createCalendarEvent = createCalendarEvent,
        _updateCalendarEvent = updateCalendarEvent,
        _notificationService = notificationService,
        super(const EventEditInitial()) {
    on<EventEditSubmitted>(_onSubmitted);
  }

  final CreateCalendarEvent _createCalendarEvent;
  final UpdateCalendarEvent _updateCalendarEvent;
  final NotificationService _notificationService;

  /// The account this event belongs to. Needed to namespace scheduled
  /// reminder notification ids; reminder scheduling is skipped if null.
  final String? accountId;

  Future<void> _onSubmitted(
    EventEditSubmitted event,
    Emitter<EventEditState> emit,
  ) async {
    emit(const EventEditSaving());

    if (event.id == null) {
      final result = await _createCalendarEvent(
        CreateCalendarEventParams(
          subject: event.subject,
          start: event.start,
          end: event.end,
          isAllDay: event.isAllDay,
          timezone: event.timezone,
          location: event.location,
          description: event.description,
          attendeeEmails: event.attendeeEmails,
          recurrence: event.recurrence,
          isOnlineMeeting: event.isOnlineMeeting,
          reminderMinutes: event.reminderMinutes,
        ),
      );
      result.fold(
        (f) => emit(EventEditError(message: f.message)),
        (e) {
          final id = accountId;
          if (id != null && event.reminderMinutes != null) {
            _notificationService.scheduleEventReminder(
              accountId: id,
              eventId: e.id,
              eventTitle: e.subject,
              startUtc: e.start,
              reminderMinutes: event.reminderMinutes!,
              startIso: e.start.toIso8601String(),
            );
          }
          emit(EventEditSaved(event: e));
        },
      );
    } else {
      final result = await _updateCalendarEvent(
        UpdateCalendarEventParams(
          id: event.id!,
          subject: event.subject,
          start: event.start,
          end: event.end,
          isAllDay: event.isAllDay,
          timezone: event.timezone,
          location: event.location,
          description: event.description,
          attendeeEmails: event.attendeeEmails,
          recurrence: event.recurrence,
          isOnlineMeeting: event.isOnlineMeeting,
          reminderMinutes: event.reminderMinutes,
        ),
      );
      result.fold(
        (f) => emit(EventEditError(message: f.message)),
        (e) {
          final id = accountId;
          if (id != null) {
            _notificationService.cancelEventReminder(
                accountId: id, eventId: e.id);
            if (event.reminderMinutes != null) {
              _notificationService.scheduleEventReminder(
                accountId: id,
                eventId: e.id,
                eventTitle: e.subject,
                startUtc: e.start,
                reminderMinutes: event.reminderMinutes!,
                startIso: e.start.toIso8601String(),
              );
            }
          }
          emit(EventEditSaved(event: e));
        },
      );
    }
  }
}
