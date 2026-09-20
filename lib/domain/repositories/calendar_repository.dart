import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../entities/attendee_availability.dart';
import '../entities/calendar_event.dart';
import '../entities/meeting_forward.dart';
import '../entities/meeting_invite.dart';
import '../entities/meeting_room.dart';
import '../usecases/create_calendar_event.dart';
import '../usecases/update_calendar_event.dart';

/// Every method here takes an optional [String] `accountId`. Null (the
/// default on every call site but one) means "whichever account is active
/// elsewhere in the app" — unchanged from before this parameter existed, and
/// still how almost everything in the app calls this repository. Passing an
/// explicit id targets a specific signed-in account instead, independent of
/// which one happens to be active; an id that names no signed-in account
/// fails with a [ServerFailure] rather than silently falling back to the
/// active one.
///
/// `MeetingSweepCubit` (the Out of Office "decline/cancel my meetings"
/// sweep) is the one caller that routinely passes an explicit id: it acts on
/// whichever account Out of Office is being edited for, which the Settings
/// screen lets you pick independently of the account active in the mail
/// list.
///
/// The one thing an [accountId] does *not* steer is outgoing mail sent as a
/// side effect of a mutation (a changed-guest notice, a counter-proposal, a
/// forwarded invitation) — those still go out through the *active* account's
/// mailbox, because there is no per-account email datasource to route them
/// through instead. See the doc comments on [updateCalendarEvent],
/// [proposeNewTimeFromEmail], [forwardMeetingFromEmail] and
/// [forwardCalendarEvent] for where that applies.
abstract interface class CalendarRepository {
  /// Fetches events from the provider and refreshes the local cache for the
  /// same range, so the next launch can paint that range from disk.
  Future<Either<Failure, List<CalendarEvent>>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
    String? accountId,
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
    String? accountId,
  });

  /// Fetches a single event by id. Used to load a recurring series' master
  /// event (its real anchor time and recurrence rule) when editing the whole
  /// series from a clicked occurrence.
  Future<Either<Failure, CalendarEvent>> getCalendarEvent({
    required String id,
    String? accountId,
  });

  Future<Either<Failure, CalendarEvent>> createCalendarEvent({
    required CreateCalendarEventParams params,
    String? accountId,
  });

  /// [accountId] only steers which calendar the update is applied to. A save
  /// that notifies only the changed guests on a provider that cannot do that
  /// natively (see [MeetingNotifyScope.changedAttendeesOnly]) still emails
  /// them through the *active* account's mailbox regardless of [accountId] —
  /// there is no per-account email datasource to send them through instead.
  Future<Either<Failure, CalendarEvent>> updateCalendarEvent({
    required UpdateCalendarEventParams params,
    String? accountId,
  });

  Future<Either<Failure, void>> respondToMeetingInvite({
    required String emailId,
    required MeetingInviteResponseType response,
    String? icsData,
    DateTime? meetingStart,
    String? message,
    String? accountId,
  });

  /// [accountId] steers which calendar this is applied to. The counter
  /// proposal itself, when the provider needs one emailed rather than sent
  /// natively, still goes out through the *active* account's mailbox — see
  /// the class doc.
  Future<Either<Failure, void>> proposeNewTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
    String? message,
    String? accountId,
  });

  Future<Either<Failure, void>> removeMeetingFromCalendar({
    required String emailId,
    String? icsData,
    DateTime? meetingStart,
    String? accountId,
  });

  Future<Either<Failure, void>> cancelMeetingFromEmail({
    required String emailId,
    DateTime? meetingStart,
    String? accountId,
  });

  /// Moves a meeting we organize to the time an attendee proposed, re-issuing
  /// the invitation to every attendee.
  Future<Either<Failure, void>> acceptProposedTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
    String? accountId,
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
  ///
  /// [accountId] steers which calendar/provider forward is attempted first.
  /// The emailed fallback, when it is reached, still goes out through the
  /// *active* account's mailbox — see the class doc.
  Future<Either<Failure, MeetingForwardMode>> forwardMeetingFromEmail({
    required String emailId,
    required List<String> toAddresses,
    String? icsData,
    DateTime? meetingStart,
    String? comment,
    String? accountId,
  });

  /// [forwardMeetingFromEmail] for a meeting opened from the calendar rather
  /// than from its invitation email.
  Future<Either<Failure, MeetingForwardMode>> forwardCalendarEvent({
    required String eventId,
    required List<String> toAddresses,
    String? comment,
    String? accountId,
  });

  Future<Either<Failure, void>> cancelCalendarEvent({
    required String eventId,
    String? accountId,
  });

  Future<Either<Failure, void>> cancelCalendarEventSeries({
    required String eventId,
    String? seriesMasterId,
    required DateTime occurrenceStart,
    String? accountId,
  });

  Future<Either<Failure, void>> declineCalendarEvent({
    required String eventId,
    String? accountId,
  });

  Future<Either<Failure, void>> proposeNewTime({
    required String eventId,
    required DateTime newStart,
    required DateTime newEnd,
    String? timezone,
    String? message,
    String? accountId,
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
