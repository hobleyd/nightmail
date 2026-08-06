import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/meeting_room.dart';
import '../repositories/calendar_repository.dart';

class GetMeetingRooms {
  const GetMeetingRooms(this._repository);

  final CalendarRepository _repository;

  /// [accountId] is the account whose directory should answer — the account the
  /// meeting is being created on, which is not necessarily the active one.
  Future<Either<Failure, List<MeetingRoom>>> call({String? accountId}) {
    return _repository.getMeetingRooms(accountId: accountId);
  }
}
