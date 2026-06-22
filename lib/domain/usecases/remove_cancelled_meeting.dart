import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../repositories/calendar_repository.dart';

class RemoveCancelledMeeting
    implements UseCase<void, RemoveCancelledMeetingParams> {
  const RemoveCancelledMeeting(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(RemoveCancelledMeetingParams params) {
    return _repository.removeMeetingFromCalendar(
      emailId: params.emailId,
      icsData: params.icsData,
      meetingStart: params.meetingStart,
    );
  }
}

class RemoveCancelledMeetingParams extends Equatable {
  const RemoveCancelledMeetingParams({
    required this.emailId,
    this.icsData,
    this.meetingStart,
  });

  final String emailId;
  final String? icsData;
  final DateTime? meetingStart;

  @override
  List<Object?> get props => [emailId, icsData, meetingStart];
}
