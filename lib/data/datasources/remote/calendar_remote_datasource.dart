import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../models/calendar_event_model.dart';

abstract interface class CalendarRemoteDatasource {
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  });

  Future<CalendarEventModel> createCalendarEvent({
    required CreateCalendarEventParams params,
  });

  Future<CalendarEventModel> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  });
}
