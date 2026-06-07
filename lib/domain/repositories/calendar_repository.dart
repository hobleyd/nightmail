import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/calendar_event.dart';
import '../usecases/create_calendar_event.dart';
import '../usecases/update_calendar_event.dart';

abstract interface class CalendarRepository {
  Future<Either<Failure, List<CalendarEvent>>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  });

  Future<Either<Failure, CalendarEvent>> createCalendarEvent({
    required CreateCalendarEventParams params,
  });

  Future<Either<Failure, CalendarEvent>> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  });
}
