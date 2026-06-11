import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/meeting_invite.dart';
import '../repositories/calendar_repository.dart';

class RespondToMeetingInvite
    implements UseCase<void, RespondToMeetingInviteParams> {
  const RespondToMeetingInvite(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, void>> call(RespondToMeetingInviteParams params) {
    return _repository.respondToMeetingInvite(
      emailId: params.emailId,
      response: params.response,
      icsData: params.icsData,
    );
  }
}

class RespondToMeetingInviteParams extends Equatable {
  const RespondToMeetingInviteParams({
    required this.emailId,
    required this.response,
    this.icsData,
  });

  final String emailId;
  final MeetingInviteResponseType response;
  final String? icsData;

  @override
  List<Object?> get props => [emailId, response, icsData];
}
