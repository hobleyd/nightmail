import 'dart:convert';
import 'dart:typed_data';

import 'package:fpdart/fpdart.dart';
import 'package:intl/intl.dart';

import '../../core/error/exceptions.dart';
import '../../core/error/failures.dart';
import '../../core/utils/ics_counter_builder.dart';
import '../../core/utils/ics_parser.dart';
import '../../domain/entities/attendee_availability.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/local_attachment.dart';
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
      if (!ds.supportsNativeProposeNewTime) {
        await _emailCounterProposal(
          emailId: emailId,
          icsData: icsData,
          newStart: newStart,
          newEnd: newEnd,
          userEmail: userEmail,
          message: message,
        );
      }
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

  /// Emails the organizer the proposed time, for account types whose provider
  /// can only decline (see [CalendarRemoteDatasource.supportsNativeProposeNewTime]).
  ///
  /// The reply carries a `METHOD:COUNTER` iCalendar part — what Outlook itself
  /// sends over SMTP, so Exchange can offer the organizer an "Accept Proposal"
  /// action — and states the proposed time in the message body as well, for
  /// clients that ignore COUNTER. Replying (rather than composing) keeps the
  /// proposal in the invitation's thread.
  ///
  /// Throws when the reply cannot be sent: by this point the invite has already
  /// been declined, and a silent failure would leave the organizer with a bare
  /// decline and no idea a time was proposed.
  Future<void> _emailCounterProposal({
    required String emailId,
    required String? icsData,
    required DateTime newStart,
    required DateTime newEnd,
    required String? userEmail,
    required String? message,
  }) async {
    final event = icsData != null ? IcsParser.parse(icsData) : null;
    final note = message?.trim();

    final body = StringBuffer()
      ..writeln(event != null
          ? 'I\'ve proposed a new time for "${event.summary}".'
          : "I've proposed a new time for this meeting.")
      ..writeln()
      ..writeln('Proposed: ${_formatRange(newStart, newEnd)}');
    if (event != null) {
      body.writeln('Originally: ${_formatRange(event.start, event.end)}');
    }
    if (note != null && note.isNotEmpty) {
      body
        ..writeln()
        ..writeln(note);
    }

    // No ICS (or no address to reply as) means no counter can be built — send
    // the plain-text proposal on its own rather than nothing at all.
    final counter = (icsData != null && userEmail != null)
        ? buildCounterIcs(
            originalIcs: icsData,
            attendeeEmail: userEmail,
            attendeeName: _accountManager.activeAccount?.displayName,
            newStart: newStart,
            newEnd: newEnd,
            comment: note,
          )
        : null;

    try {
      await _accountManager.emailDatasource.replyToEmail(
        messageId: emailId,
        comment: body.toString(),
        // Reply to the ICS organizer when it is known: the address an invite
        // was *sent* from can be a delegate or a room system.
        toAddresses: event?.organizer != null ? [event!.organizer!] : const [],
        newAttachments: counter == null
            ? const []
            : [
                LocalAttachment(
                  name: 'counter.ics',
                  // The `method` parameter is what makes Exchange read the part
                  // as a meeting counter-proposal rather than a file.
                  mimeType: 'text/calendar; method=COUNTER',
                  bytes: Uint8List.fromList(utf8.encode(counter)),
                ),
              ],
      );
      // Each exception is re-thrown as its own type so the caller still maps it
      // to the right Failure — an expired token has to stay an AuthFailure for
      // the re-auth prompt to appear.
    } on AuthException catch (e) {
      throw AuthException(message: _counterFailed(e.message));
    } on NetworkException catch (e) {
      throw NetworkException(message: _counterFailed(e.message));
    } on ServerException catch (e) {
      throw ServerException(
          message: _counterFailed(e.message), statusCode: e.statusCode);
    } catch (e) {
      throw ServerException(message: _counterFailed(e.toString()));
    }
  }

  String _counterFailed(String reason) =>
      'The invitation was declined, but the new time could not be sent to the '
      'organizer: $reason';

  String _formatRange(DateTime start, DateTime end) {
    final localStart = start.toLocal();
    final localEnd = end.toLocal();
    final date = DateFormat('EEE d MMM yyyy').format(localStart);
    final from = DateFormat('h:mm a').format(localStart);
    final to = DateFormat('h:mm a').format(localEnd);
    final sameDay = localStart.year == localEnd.year &&
        localStart.month == localEnd.month &&
        localStart.day == localEnd.day;
    final zone = localStart.timeZoneName;
    if (sameDay) return '$date, $from – $to ($zone)';
    final endDate = DateFormat('EEE d MMM yyyy').format(localEnd);
    return '$date $from – $endDate $to ($zone)';
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
  Future<Either<Failure, void>> acceptProposedTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
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
      await ds.acceptProposedTimeFromEmail(
        emailId: emailId,
        newStart: newStart,
        newEnd: newEnd,
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
    String? excludeEventId,
    DateTime? excludeStart,
    DateTime? excludeEnd,
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
            // The organizer's own copy is matched by id, which is exact — this
            // path fetches whole events, unlike the attendee free/busy below.
            .where((e) => !_isExcludedEvent(e, excludeEventId))
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
        for (final raw in schedules) {
          results.add(_statusForMeetingWindow(
            _withoutExcludedMeeting(raw, excludeStart, excludeEnd),
            start,
            end,
            // Read from the untrimmed response on purpose — see the doc comment.
            hadBlocks: raw.scheduleItems.isNotEmpty,
          ));
        }
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
  ///
  /// [hadBlocks] is whether the provider returned any detail blocks *before*
  /// the meeting being edited was discounted, and cannot be re-derived from
  /// `a.scheduleItems` here: a guest whose only commitment was this very
  /// meeting arrives with an empty list and has to read Free, rather than
  /// falling through to the provider's now-stale day-wide status.
  AttendeeAvailability _statusForMeetingWindow(
    AttendeeAvailability a,
    DateTime start,
    DateTime end, {
    required bool hadBlocks,
  }) {
    // `unknown` means this mailbox's free/busy is not visible to us. Having
    // no blocks for that reason must never be reported as Free.
    if (a.status == AttendeeAvailabilityStatus.unknown) return a;

    // Blocks present — recompute precisely from the ones that overlap.
    if (hadBlocks) {
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
  }

  /// True when [e] is the meeting currently being edited.
  ///
  /// Matches the series master too, so editing a whole recurring series
  /// discounts every occurrence of it rather than just the one that was opened.
  bool _isExcludedEvent(CalendarEvent e, String? excludeEventId) {
    if (excludeEventId == null) return false;
    return e.id == excludeEventId || e.seriesMasterId == excludeEventId;
  }

  /// Drops a guest's own copy of the meeting being edited.
  ///
  /// Free/busy carries no event id — Graph's `getSchedule` and Google's
  /// `freeBusy` both report anonymous intervals — so the meeting's stored slot
  /// is the only thing left to match on. Bounds are compared with a minute of
  /// slack because providers round these times to the second.
  ///
  /// Google merges touching busy intervals, so a guest with something butted up
  /// against this meeting comes back as one wider block that no longer matches
  /// and is therefore kept. That over-reports a clash rather than concealing
  /// one, which is the right direction to be wrong in.
  AttendeeAvailability _withoutExcludedMeeting(
    AttendeeAvailability a,
    DateTime? excludeStart,
    DateTime? excludeEnd,
  ) {
    if (excludeStart == null || excludeEnd == null) return a;
    if (a.scheduleItems.isEmpty) return a;

    final kept = a.scheduleItems
        .where((i) => !_isSameSlot(i, excludeStart, excludeEnd))
        .toList();
    if (kept.length == a.scheduleItems.length) return a;

    return AttendeeAvailability(
      email: a.email,
      status: a.status,
      scheduleItems: kept,
    );
  }

  static const _slotSlack = Duration(seconds: 60);

  bool _isSameSlot(AttendeeScheduleItem i, DateTime start, DateTime end) =>
      i.start.difference(start.toUtc()).abs() <= _slotSlack &&
      i.end.difference(end.toUtc()).abs() <= _slotSlack;

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
