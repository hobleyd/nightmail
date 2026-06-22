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
  })  : _createCalendarEvent = createCalendarEvent,
        _updateCalendarEvent = updateCalendarEvent,
        _notificationService = notificationService,
        super(const EventEditInitial()) {
    on<EventEditSubmitted>(_onSubmitted);
  }

  final CreateCalendarEvent _createCalendarEvent;
  final UpdateCalendarEvent _updateCalendarEvent;
  final NotificationService _notificationService;

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
          isTeamsMeeting: event.isTeamsMeeting,
          reminderMinutes: event.reminderMinutes,
        ),
      );
      result.fold(
        (f) => emit(EventEditError(message: f.message)),
        (e) {
          if (event.reminderMinutes != null) {
            _notificationService.scheduleEventReminder(
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
          reminderMinutes: event.reminderMinutes,
        ),
      );
      result.fold(
        (f) => emit(EventEditError(message: f.message)),
        (e) {
          _notificationService.cancelEventReminder(e.id);
          if (event.reminderMinutes != null) {
            _notificationService.scheduleEventReminder(
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
    }
  }
}
