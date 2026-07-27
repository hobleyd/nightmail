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
import '../datasources/remote/calendar_remote_datasource.dart';

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
  Future<Either<Failure, CalendarEvent>> getCalendarEvent({
    required String id,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(
            message: 'Calendar is not available for this account type'),
      );
    }

    try {
      final event = await ds.getCalendarEvent(id: id);
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
  Future<Either<Failure, void>> cancelCalendarEventSeries({
    required String eventId,
    String? seriesMasterId,
    required DateTime occurrenceStart,
  }) async {
    final ds = _accountManager.calendarDatasource;
    if (ds == null) {
      return const Left(
        ServerFailure(message: 'Calendar is not available for this account type'),
      );
    }

    try {
      await ds.cancelCalendarEventSeries(
        eventId: eventId,
        seriesMasterId: seriesMasterId,
        occurrenceStart: occurrenceStart,
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
    String? accountId,
  }) async {
    final ds = _availabilityDatasource(accountId);
    if (ds == null) return const Right([]);

    try {
      final results = <AttendeeAvailability>[];

      // Query the whole working day rather than just the meeting window: the
      // schedule pane draws 07:00–20:00 so the organizer can find a free slot,
      // and it can only show blocks that were actually fetched. Widened past
      // those bounds when the meeting itself falls outside them, so a 06:00 or
      // 21:00 meeting still gets its own window covered.
      final dayStart = DateTime(start.year, start.month, start.day, 7);
      final dayEnd = DateTime(start.year, start.month, start.day, 20);
      final windowStart = start.isBefore(dayStart) ? start : dayStart;
      final windowEnd = end.isAfter(dayEnd) ? end : dayEnd;

      // Organiser: fetch full calendar events so subjects are included.
      // getSchedule redacts subjects for most queries; calendarView does not.
      if (organizerEmail != null) {
        final events = await ds.getCalendarEvents(
          startDateTime: windowStart,
          endDateTime: windowEnd,
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
          start: windowStart,
          end: windowEnd,
        );
        results.addAll(schedules.map(_statusForMeetingWindow(start, end)));
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

  /// Narrows a datasource's day-wide summary status down to the meeting itself.
  ///
  /// Datasources derive their status from whatever window they were asked
  /// about, which is now the whole working day (the schedule pane needs those
  /// blocks), so a guest with a busy afternoon would otherwise be flagged as a
  /// clash for a free-morning meeting.
  AttendeeAvailability Function(AttendeeAvailability) _statusForMeetingWindow(
    DateTime start,
    DateTime end,
  ) {
    return (a) {
      // `unknown` means this mailbox's free/busy is not visible to us. Having
      // no blocks for that reason must never be reported as Free.
      if (a.status == AttendeeAvailabilityStatus.unknown) return a;

      // Blocks present — recompute precisely from the ones that overlap.
      if (a.scheduleItems.isNotEmpty) {
        return AttendeeAvailability(
          email: a.email,
          status: _worstOverlap(a.scheduleItems, start, end),
          scheduleItems: a.scheduleItems,
        );
      }

      // No blocks, but a status the provider was willing to state: Exchange
      // discloses free/busy without details for guests who share only that
      // much, so the day-wide status is all we have. Keep it — over-reporting
      // a clash is safer than claiming a guest is free when they are not.
      return a;
    };
  }

  /// Calendar datasource to answer a free/busy query for [accountId].
  ///
  /// The active account's shared datasource is reused whenever it is the one
  /// being asked about, because [AccountManager.buildCalendarDatasourceForAccount]
  /// stands up an independent auth pipeline against the same stored token —
  /// running that alongside the active one races on refresh (see
  /// CalendarReminderService._reconcileAccount for the same trade-off).
  CalendarRemoteDatasource? _availabilityDatasource(String? accountId) {
    if (accountId == null || accountId == _accountManager.activeAccount?.id) {
      return _accountManager.calendarDatasource;
    }
    final account = _accountManager.accountById(accountId);
    if (account == null) return _accountManager.calendarDatasource;
    return _accountManager.buildCalendarDatasourceForAccount(account);
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
