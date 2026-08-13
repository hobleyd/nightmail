import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/attendee_availability.dart';
import '../entities/calendar_event.dart';
import '../entities/meeting_forward.dart';
import '../entities/meeting_invite.dart';
import '../entities/meeting_room.dart';
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

  /// Forwards a meeting the user was invited to on to [toAddresses].
  ///
  /// Tries to have the provider do it, so the recipient becomes a real attendee
  /// on the organizer's copy, and falls back to emailing the invitation from
  /// this account when it will not — the returned [MeetingForwardMode] says
  /// which happened, because the two leave the recipient in materially
  /// different positions.
  ///
  /// Network-first and never queued: it emails people, and a blind replay would
  /// invite them twice. Offline it fails rather than waiting, like every other
  /// mutation here that sends mail.
  Future<Either<Failure, MeetingForwardMode>> forwardMeetingFromEmail({
    required String emailId,
    required List<String> toAddresses,
    String? icsData,
    DateTime? meetingStart,
    String? comment,
  });

  /// [forwardMeetingFromEmail] for a meeting opened from the calendar rather
  /// than from its invitation email.
  Future<Either<Failure, MeetingForwardMode>> forwardCalendarEvent({
    required String eventId,
    required List<String> toAddresses,
    String? comment,
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

  /// The bookable rooms [accountId]'s directory offers, for the event form's
  /// Location field.
  ///
  /// Cached in memory for the process' lifetime — a room directory changes on
  /// the timescale of an office fit-out, and the picker must not pay a
  /// round-trip every time the field is focused. Free/busy for these rooms is
  /// *not* cached; it comes from [checkAttendeesAvailability] per slot.
  ///
  /// Returns an empty list rather than a failure for providers and accounts
  /// with no room directory to read (IMAP/CalDAV always; a Google account whose
  /// token lacks the Admin SDK scope, or whose user is not a Workspace admin).
  /// An empty dropdown is the honest answer there — there is nothing to pick.
  Future<Either<Failure, List<MeetingRoom>>> getMeetingRooms({
    String? accountId,
  });
}
