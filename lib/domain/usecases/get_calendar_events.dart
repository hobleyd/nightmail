import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/calendar_event.dart';
import '../repositories/calendar_repository.dart';

class GetCalendarEvents
    implements UseCase<List<CalendarEvent>, GetCalendarEventsParams> {
  const GetCalendarEvents(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, List<CalendarEvent>>> call(
      GetCalendarEventsParams params) {
    return _repository.getCalendarEvents(
      startDateTime: params.startDateTime,
      endDateTime: params.endDateTime,
    );
  }
}

class GetCalendarEventsParams extends Equatable {
  const GetCalendarEventsParams({
    required this.startDateTime,
    required this.endDateTime,
  });

  final DateTime startDateTime;
  final DateTime endDateTime;

  @override
  List<Object> get props => [startDateTime, endDateTime];
}
