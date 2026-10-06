import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/meeting_invite.dart';
import '../entities/meeting_response.dart';
import '../repositories/calendar_repository.dart';

class RespondToMeetingInvite
    implements UseCase<MeetingResponseMode, RespondToMeetingInviteParams> {
  const RespondToMeetingInvite(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, MeetingResponseMode>> call(
      RespondToMeetingInviteParams params) {
    return _repository.respondToMeetingInvite(
      emailId: params.emailId,
      response: params.response,
      icsData: params.icsData,
      meetingStart: params.meetingStart,
      message: params.message,
    );
  }
}

class RespondToMeetingInviteParams extends Equatable {
  const RespondToMeetingInviteParams({
    required this.emailId,
    required this.response,
    this.icsData,
    this.meetingStart,
    this.message,
  });

  final String emailId;
  final MeetingInviteResponseType response;
  final String? icsData;
  final DateTime? meetingStart;
  final String? message;

  @override
  List<Object?> get props => [emailId, response, icsData, meetingStart, message];
}
