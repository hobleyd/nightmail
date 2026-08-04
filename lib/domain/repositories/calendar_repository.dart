import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/attendee_availability.dart';
import '../entities/calendar_event.dart';
import '../entities/meeting_invite.dart';
import '../usecases/create_calendar_event.dart';
import '../usecases/update_calendar_event.dart';

abstract interface class CalendarRepository {
  /// Fetches events from the provider and refreshes the local cache for the
  /// same range, so the next launch can paint that range from disk.
  Future<Either<Failure, List<CalendarEvent>>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  });

  /// Locally cached events overlapping the range, without touching the network.
  ///
  /// The calendar shows this first and then repaints from
  /// [getCalendarEvents] — a range that has never been cached simply comes back
  /// empty. `CalendarCacheSyncService` keeps today through four weeks ahead
  /// populated in the background, so the common case is already on disk.
  Future<Either<Failure, List<CalendarEvent>>> getCachedCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  });

  /// Fetches a single event by id. Used to load a recurring series' master
  /// event (its real anchor time and recurrence rule) when editing the whole
  /// series from a clicked occurrence.
  Future<Either<Failure, CalendarEvent>> getCalendarEvent({
    required String id,
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
    String? message,
  });

  Future<Either<Failure, void>> proposeNewTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
    String? message,
  });

  Future<Either<Failure, void>> removeMeetingFromCalendar({
    required String emailId,
    String? icsData,
    DateTime? meetingStart,
  });

  Future<Either<Failure, void>> cancelMeetingFromEmail({
    required String emailId,
    DateTime? meetingStart,
  });

  /// Moves a meeting we organize to the time an attendee proposed, re-issuing
  /// the invitation to every attendee.
  Future<Either<Failure, void>> acceptProposedTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
  });

  Future<Either<Failure, void>> cancelCalendarEvent({
    required String eventId,
  });

  Future<Either<Failure, void>> cancelCalendarEventSeries({
    required String eventId,
    String? seriesMasterId,
    required DateTime occurrenceStart,
  });

  Future<Either<Failure, void>> declineCalendarEvent({
    required String eventId,
  });

  Future<Either<Failure, void>> proposeNewTime({
    required String eventId,
    required DateTime newStart,
    required DateTime newEnd,
    String? timezone,
    String? message,
  });

  /// Free/busy for [emails] over the day containing [start].
  ///
  /// [excludeEventId] and [excludeStart]/[excludeEnd] identify a meeting that
  /// must not be counted as a clash with itself — set them when checking on
  /// behalf of an existing event, whose guests already hold a copy of it.
  /// Pass the event's stored times, not the ones being edited in the form:
  /// until the change is saved, the guests' copies still sit at the old slot.
  Future<Either<Failure, List<AttendeeAvailability>>> checkAttendeesAvailability({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
    String? organizerEmail,
    String? accountId,
    String? excludeEventId,
    DateTime? excludeStart,
    DateTime? excludeEnd,
  });
}
