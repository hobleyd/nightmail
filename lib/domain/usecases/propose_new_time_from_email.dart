import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/calendar_repository.dart';

class ProposeNewTimeFromEmail
    implements UseCase<void, ProposeNewTimeFromEmailParams> {
  const ProposeNewTimeFromEmail(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(ProposeNewTimeFromEmailParams params) {
    return _repository.proposeNewTimeFromEmail(
      emailId: params.emailId,
      newStart: params.newStart,
      newEnd: params.newEnd,
      icsData: params.icsData,
      meetingStart: params.meetingStart,
      message: params.message,
    );
  }
}

class ProposeNewTimeFromEmailParams extends Equatable {
  const ProposeNewTimeFromEmailParams({
    required this.emailId,
    required this.newStart,
    required this.newEnd,
    this.icsData,
    this.meetingStart,
    this.message,
  });

  final String emailId;
  final DateTime newStart;
  final DateTime newEnd;
  final String? icsData;
  final DateTime? meetingStart;
  final String? message;

  @override
  List<Object?> get props =>
      [emailId, newStart, newEnd, icsData, meetingStart, message];
}
