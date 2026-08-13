import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/meeting_forward.dart';
import '../repositories/calendar_repository.dart';

/// Forwards a meeting from its invitation email in the reading pane.
class ForwardMeetingFromEmail
    implements UseCase<MeetingForwardMode, ForwardMeetingFromEmailParams> {
  const ForwardMeetingFromEmail(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, MeetingForwardMode>> call(
    ForwardMeetingFromEmailParams params,
  ) {
    return _repository.forwardMeetingFromEmail(
      emailId: params.emailId,
      toAddresses: params.toAddresses,
      icsData: params.icsData,
      meetingStart: params.meetingStart,
      comment: params.comment,
    );
  }
}

class ForwardMeetingFromEmailParams extends Equatable {
  const ForwardMeetingFromEmailParams({
    required this.emailId,
    required this.toAddresses,
    this.icsData,
    this.meetingStart,
    this.comment,
  });

  final String emailId;
  final List<String> toAddresses;
  final String? icsData;
  final DateTime? meetingStart;
  final String? comment;

  @override
  List<Object?> get props =>
      [emailId, toAddresses, icsData, meetingStart, comment];
}
