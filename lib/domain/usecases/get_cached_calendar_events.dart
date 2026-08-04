import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/calendar_event.dart';
import '../repositories/calendar_repository.dart';
import 'get_calendar_events.dart';

/// Reads the locally cached events for a range without going near the network,
/// so the calendar can draw a week before the provider has answered.
///
/// Takes [GetCalendarEventsParams] — the same range as the network fetch it
/// precedes, deliberately, so the two can never be asked about different weeks.
class GetCachedCalendarEvents
    implements UseCase<List<CalendarEvent>, GetCalendarEventsParams> {
  const GetCachedCalendarEvents(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, List<CalendarEvent>>> call(
      GetCalendarEventsParams params) {
    return _repository.getCachedCalendarEvents(
      startDateTime: params.startDateTime,
      endDateTime: params.endDateTime,
    );
  }
}
