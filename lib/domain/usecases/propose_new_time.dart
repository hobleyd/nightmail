import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/calendar_repository.dart';

class ProposeNewTime implements UseCase<void, ProposeNewTimeParams> {
  const ProposeNewTime(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(ProposeNewTimeParams params) {
    return _repository.proposeNewTime(
      eventId: params.eventId,
      newStart: params.newStart,
      newEnd: params.newEnd,
      timezone: params.timezone,
      message: params.message,
    );
  }
}

class ProposeNewTimeParams extends Equatable {
  const ProposeNewTimeParams({
    required this.eventId,
    required this.newStart,
    required this.newEnd,
    this.timezone,
    this.message,
  });

  final String eventId;
  final DateTime newStart;
  final DateTime newEnd;
  final String? timezone;
  final String? message;

  @override
  List<Object?> get props => [eventId, newStart, newEnd, timezone, message];
}
