import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/calendar_repository.dart';

class CancelCalendarEvent implements UseCase<void, CancelCalendarEventParams> {
  const CancelCalendarEvent(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(CancelCalendarEventParams params) {
    return _repository.cancelCalendarEvent(eventId: params.eventId);
  }
}

class CancelCalendarEventParams extends Equatable {
  const CancelCalendarEventParams({required this.eventId});

  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

class CancelCalendarEventSeries
    implements UseCase<void, CancelCalendarEventSeriesParams> {
  const CancelCalendarEventSeries(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(CancelCalendarEventSeriesParams params) {
    return _repository.cancelCalendarEventSeries(
      eventId: params.eventId,
      seriesMasterId: params.seriesMasterId,
      occurrenceStart: params.occurrenceStart,
    );
  }
}

class CancelCalendarEventSeriesParams extends Equatable {
  const CancelCalendarEventSeriesParams({
    required this.eventId,
    this.seriesMasterId,
    required this.occurrenceStart,
  });

  final String eventId;
  final String? seriesMasterId;
  final DateTime occurrenceStart;

  @override
  List<Object?> get props => [eventId, seriesMasterId, occurrenceStart];
}
