import 'package:fpdart/fpdart.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../domain/entities/attendee_availability.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/meeting_invite.dart';
import '../../domain/repositories/calendar_repository.dart';
import '../../domain/usecases/create_calendar_event.dart';
import '../../domain/usecases/update_calendar_event.dart';
import '../../infrastructure/accounts/account_manager.dart';

class CalendarRepositoryImpl implements CalendarRepository {
  const CalendarRepositoryImpl({required this._accountManager});

  final AccountManager _accountManager;

  @override
  Future<Either<Failure, List<CalendarEvent>>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    try {
      final events = await ds.getCalendarEvents(
        startDateTime: startDateTime,
        endDateTime: endDateTime,
      );
      return Right(events);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, CalendarEvent>> createCalendarEvent({
    required CreateCalendarEventParams params,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    try {
      final event = await ds.createCalendarEvent(params: params);
      return Right(event);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, CalendarEvent>> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    try {
      final event = await ds.updateCalendarEvent(params: params);
      return Right(event);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> respondToMeetingInvite({
    required String emailId,
    required MeetingInviteResponseType response,
    String? icsData,
    DateTime? meetingStart,
    String? message,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    final userEmail = _accountManager.activeAccount?.emailAddress;

    try {
      await ds.respondToMeetingInvite(
        emailId: emailId,
        response: response,
        icsData: icsData,
        meetingStart: meetingStart,
        userEmail: userEmail,
        message: message,
      );
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> proposeNewTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
    String? message,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final userEmail = _accountManager.activeAccount?.emailAddress;

    try {
      await ds.proposeNewTimeFromEmail(
        emailId: emailId,
        newStart: newStart,
        newEnd: newEnd,
        icsData: icsData,
        meetingStart: meetingStart,
        userEmail: userEmail,
        message: message,
      );
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> removeMeetingFromCalendar({
    required String emailId,
    String? icsData,
    DateTime? meetingStart,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    try {
      await ds.removeMeetingFromCalendar(
        emailId: emailId,
        icsData: icsData,
        meetingStart: meetingStart,
      );
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> cancelMeetingFromEmail({
    required String emailId,
    DateTime? meetingStart,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    try {
      await ds.cancelMeetingFromEmail(
        emailId: emailId,
        meetingStart: meetingStart,
      );
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> cancelCalendarEvent({
    required String eventId,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    try {
      await ds.cancelCalendarEvent(eventId: eventId);
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> declineCalendarEvent({
    required String eventId,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final userEmail = _accountManager.activeAccount?.emailAddress;

    try {
      await ds.declineCalendarEvent(eventId: eventId, userEmail: userEmail);
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, void>> proposeNewTime({
    required String eventId,
    required DateTime newStart,
    required DateTime newEnd,
    String? timezone,
    String? message,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    final userEmail = _accountManager.activeAccount?.emailAddress;

    try {
      await ds.proposeNewTime(
        eventId: eventId,
        newStart: newStart,
        newEnd: newEnd,
        timezone: timezone,
        userEmail: userEmail,
        message: message,
      );
      return const Right(null);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  @override
  Future<Either<Failure, List<AttendeeAvailability>>> checkAttendeesAvailability({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
    String? organizerEmail,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) return const Right([]);

    try {
      final results = <AttendeeAvailability>[];

      // Organiser: fetch full calendar events so subjects are included.
      // getSchedule redacts subjects for most queries; calendarView does not.
      if (organizerEmail != null) {
        final dayStart = DateTime(start.year, start.month, start.day, 7);
        final dayEnd = DateTime(start.year, start.month, start.day, 20);
        final events = await ds.getCalendarEvents(
          startDateTime: dayStart,
          endDateTime: dayEnd,
        );
        final items = events
            .where((e) => !e.isAllDay && e.status != CalendarEventStatus.free)
            .map((e) => AttendeeScheduleItem(
                  start: e.start,
                  end: e.end,
                  status: _mapStatus(e.status),
                  subject: e.subject,
                ))
            .toList();
        results.add(AttendeeAvailability(
          email: organizerEmail,
          status: _worstOverlap(items, start, end),
          scheduleItems: items,
        ));
      }

      // Attendees: use getSchedule for free/busy (subjects not reliably returned).
      final attendeeEmails =
          emails.where((e) => e != organizerEmail).toList();
      if (attendeeEmails.isNotEmpty) {
        final schedules = await ds.getAttendeesSchedule(
          emails: attendeeEmails,
          start: start,
          end: end,
        );
        results.addAll(schedules);
      }

      return Right(results);
    } on AuthException catch (e) {
      return Left(AuthFailure(message: e.message));
    } on NetworkException catch (e) {
      return Left(NetworkFailure(message: e.message));
    } on ServerException catch (e) {
      return Left(ServerFailure(message: e.message, statusCode: e.statusCode));
    } catch (e) {
      return Left(ServerFailure(message: e.toString()));
    }
  }

  AttendeeAvailabilityStatus _mapStatus(CalendarEventStatus s) => switch (s) {
        CalendarEventStatus.free => AttendeeAvailabilityStatus.free,
        CalendarEventStatus.tentative => AttendeeAvailabilityStatus.tentative,
        CalendarEventStatus.outOfOffice => AttendeeAvailabilityStatus.outOfOffice,
        CalendarEventStatus.workingElsewhere =>
          AttendeeAvailabilityStatus.workingElsewhere,
        CalendarEventStatus.busy => AttendeeAvailabilityStatus.busy,
      };

  AttendeeAvailabilityStatus _worstOverlap(
      List<AttendeeScheduleItem> items, DateTime start, DateTime end) {
    final overlapping = items.where(
      (i) => i.start.isBefore(end) && i.end.isAfter(start),
    );
    if (overlapping.any((i) =>
        i.status == AttendeeAvailabilityStatus.busy ||
        i.status == AttendeeAvailabilityStatus.outOfOffice)) {
      return AttendeeAvailabilityStatus.busy;
    }
    if (overlapping.any((i) => i.status == AttendeeAvailabilityStatus.tentative)) {
      return AttendeeAvailabilityStatus.tentative;
    }
    if (overlapping.any(
        (i) => i.status == AttendeeAvailabilityStatus.workingElsewhere)) {
      return AttendeeAvailabilityStatus.workingElsewhere;
    }
    return AttendeeAvailabilityStatus.free;
  }
}
