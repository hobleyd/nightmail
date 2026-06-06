import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/calendar_event.dart';

abstract interface class CalendarRepository {
  Future<Either<Failure, List<CalendarEvent>>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  });
}
