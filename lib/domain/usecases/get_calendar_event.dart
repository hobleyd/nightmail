import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/calendar_event.dart';
import '../repositories/calendar_repository.dart';

/// Fetches a single calendar event by id — used to load a recurring series'
/// master event when the user chooses to edit the whole series.
class GetCalendarEvent implements UseCase<CalendarEvent, GetCalendarEventParams> {
  const GetCalendarEvent(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, CalendarEvent>> call(GetCalendarEventParams params) {
    return _repository.getCalendarEvent(id: params.id);
  }
}

class GetCalendarEventParams extends Equatable {
  const GetCalendarEventParams({required this.id});

  final String id;

  @override
  List<Object?> get props => [id];
}
