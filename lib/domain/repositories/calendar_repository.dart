import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/calendar_event.dart';
import '../entities/meeting_invite.dart';
import '../usecases/create_calendar_event.dart';
import '../usecases/update_calendar_event.dart';

abstract interface class CalendarRepository {
  Future<Either<Failure, List<CalendarEvent>>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  });

  Future<Either<Failure, CalendarEvent>> createCalendarEvent({
    required CreateCalendarEventParams params,
  });

  Future<Either<Failure, CalendarEvent>> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  });

  Future<Either<Failure, void>> respondToMeetingInvite({
    required String emailId,
    required MeetingInviteResponseType response,
    String? icsData,
    DateTime? meetingStart,
  });

  Future<Either<Failure, void>> cancelCalendarEvent({
    required String eventId,
  });

  Future<Either<Failure, void>> declineCalendarEvent({
    required String eventId,
  });

  Future<Either<Failure, void>> proposeNewTime({
    required String eventId,
    required DateTime newStart,
    required DateTime newEnd,
    String? timezone,
  });
}
