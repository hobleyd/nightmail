import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/calendar_repository.dart';

class DeclineCalendarEvent implements UseCase<void, DeclineCalendarEventParams> {
  const DeclineCalendarEvent(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(DeclineCalendarEventParams params) {
    return _repository.declineCalendarEvent(eventId: params.eventId);
  }
}

class DeclineCalendarEventParams extends Equatable {
  const DeclineCalendarEventParams({required this.eventId});

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}
