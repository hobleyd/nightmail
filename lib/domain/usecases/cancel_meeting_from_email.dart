import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/calendar_repository.dart';

class CancelMeetingFromEmail
    implements UseCase<void, CancelMeetingFromEmailParams> {
  const CancelMeetingFromEmail(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(CancelMeetingFromEmailParams params) {
    return _repository.cancelMeetingFromEmail(
      emailId: params.emailId,
      meetingStart: params.meetingStart,
    );
  }
}

class CancelMeetingFromEmailParams extends Equatable {
  const CancelMeetingFromEmailParams({
    required this.emailId,
    this.meetingStart,
  });

  final String emailId;
  final DateTime? meetingStart;

  @override
  List<Object?> get props => [emailId, meetingStart];
}
