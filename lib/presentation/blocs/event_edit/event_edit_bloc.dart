import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import 'event_edit_event.dart';
import 'event_edit_state.dart';

class EventEditBloc extends Bloc<EventEditBlocEvent, EventEditState> {
  EventEditBloc({
    required this._createCalendarEvent,
    required this._updateCalendarEvent,
  }) : super(const EventEditInitial()) {
    on<EventEditSubmitted>(_onSubmitted);
  }

  final CreateCalendarEvent _createCalendarEvent;
  final UpdateCalendarEvent _updateCalendarEvent;

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
        ),
      );
      result.fold(
        (f) => emit(EventEditError(message: f.message)),
        (e) => emit(EventEditSaved(event: e)),
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
        ),
      );
      result.fold(
        (f) => emit(EventEditError(message: f.message)),
        (e) => emit(EventEditSaved(event: e)),
      );
    }
  }
}
