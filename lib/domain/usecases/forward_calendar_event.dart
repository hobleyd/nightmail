import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/meeting_forward.dart';
import '../repositories/calendar_repository.dart';

/// Forwards a meeting opened from the calendar rather than from its invitation
/// email — the read-only "View Event" form for somebody else's meeting.
class ForwardCalendarEvent
    implements UseCase<MeetingForwardMode, ForwardCalendarEventParams> {
  const ForwardCalendarEvent(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, MeetingForwardMode>> call(
    ForwardCalendarEventParams params,
  ) {
    return _repository.forwardCalendarEvent(
      eventId: params.eventId,
      toAddresses: params.toAddresses,
      comment: params.comment,
    );
  }
}

class ForwardCalendarEventParams extends Equatable {
  const ForwardCalendarEventParams({
    required this.eventId,
    required this.toAddresses,
    this.comment,
  });

  final String eventId;
  final List<String> toAddresses;
  final String? comment;

  @override
  List<Object?> get props => [eventId, toAddresses, comment];
}
