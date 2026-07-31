import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/calendar_repository.dart';

class AcceptProposedTimeFromEmail
    implements UseCase<void, AcceptProposedTimeFromEmailParams> {
  const AcceptProposedTimeFromEmail(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(AcceptProposedTimeFromEmailParams params) {
    return _repository.acceptProposedTimeFromEmail(
      emailId: params.emailId,
      newStart: params.newStart,
      newEnd: params.newEnd,
      icsData: params.icsData,
      meetingStart: params.meetingStart,
    );
  }
}

class AcceptProposedTimeFromEmailParams extends Equatable {
  const AcceptProposedTimeFromEmailParams({
    required this.emailId,
    required this.newStart,
    required this.newEnd,
    this.icsData,
    this.meetingStart,
  });

  final String emailId;
  final DateTime newStart;
  final DateTime newEnd;
  final String? icsData;

  /// The meeting's current start, used to locate the event when the provider
  /// cannot navigate from the message to it.
  final DateTime? meetingStart;

  @override
  List<Object?> get props =>
      [emailId, newStart, newEnd, icsData, meetingStart];
}
