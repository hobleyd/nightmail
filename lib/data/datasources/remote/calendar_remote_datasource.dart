import '../../../domain/entities/attendee_availability.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/entities/meeting_room.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../models/calendar_event_model.dart';

abstract interface class CalendarRemoteDatasource {
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  });

  /// Fetches a single event by id (e.g. a recurring series' master).
  Future<CalendarEventModel> getCalendarEvent({required String id});

  Future<CalendarEventModel> createCalendarEvent({
    required CreateCalendarEventParams params,
  });

  Future<CalendarEventModel> updateCalendarEvent({
    required UpdateCalendarEventParams params,
  });

  Future<void> respondToMeetingInvite({
    required String emailId,
    required MeetingInviteResponseType response,
    String? icsData,
    DateTime? meetingStart,
    String? userEmail,
    String? message,
  });

  /// Whether the provider itself delivers a propose-new-time to the organizer.
  ///
  /// Only Graph does (`/decline` with `proposedNewTime`). The others can only
  /// decline, so [CalendarRepositoryImpl] follows their
  /// [proposeNewTimeFromEmail] with an emailed `METHOD:COUNTER` reply —
  /// without which the organizer receives a bare decline and never learns the
  /// proposed time.
  bool get supportsNativeProposeNewTime;

  Future<void> proposeNewTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
    String? userEmail,
    String? message,
  });

  Future<void> removeMeetingFromCalendar({
    required String emailId,
    String? icsData,
    DateTime? meetingStart,
  });

  Future<void> cancelMeetingFromEmail({
    required String emailId,
    DateTime? meetingStart,
  });

  /// Moves the meeting we organize to a time an attendee proposed, and sends
  /// the revised invitation to every attendee.
  ///
  /// [emailId] is the proposal message; [icsData] its `METHOD:COUNTER` part,
  /// whose `UID` is how providers without message→event navigation find the
  /// event. [meetingStart] is the meeting's *current* start, used as a
  /// last-resort locator.
  ///
  /// Throws when the event cannot be found or the caller does not organize it —
  /// only the organizer can move a meeting.
  Future<void> acceptProposedTimeFromEmail({
    required String emailId,
    required DateTime newStart,
    required DateTime newEnd,
    String? icsData,
    DateTime? meetingStart,
  });

  /// Forwards a meeting to [toAddresses] so they become real attendees on the
  /// **organizer's own copy** — their RSVP goes back to the organizer, and the
  /// organizer's guest list shows them.
  ///
  /// Only the provider can do that; nothing the app could send from this
  /// account has the same standing. Graph forwards natively
  /// (`/events/{id}/forward`), and Google is asked to add the guest to the
  /// event, which it allows when the organizer left `guestsCanInviteOthers` on.
  ///
  /// Throws [MeetingForwardUnsupportedException] when the answer is a settled
  /// no — this account type has no such API, or the organizer's policy forbids
  /// it. That is not a failure: [CalendarRepositoryImpl] answers it by emailing
  /// the invitation from this account instead.
  Future<void> forwardCalendarEvent({
    required String eventId,
    required List<String> toAddresses,
    String? comment,
  });

  /// [forwardCalendarEvent] addressed by the invitation email rather than an
  /// event id, for the banner in the reading pane.
  ///
  /// [icsData] and [meetingStart] are the same locators the RSVP methods take:
  /// the implementation has to find the user's *own* copy of the meeting first,
  /// which — unlike every other invitation path here — is explicitly the copy
  /// they did **not** organize.
  Future<void> forwardMeetingFromEmail({
    required String emailId,
    required List<String> toAddresses,
    String? icsData,
    DateTime? meetingStart,
    String? comment,
  });

  Future<void> cancelCalendarEvent({required String eventId});

  Future<void> cancelCalendarEventSeries({
    required String eventId,
    String? seriesMasterId,
    required DateTime occurrenceStart,
  });

  Future<void> declineCalendarEvent({
    required String eventId,
    String? userEmail,
  });

  Future<void> proposeNewTime({
    required String eventId,
    required DateTime newStart,
    required DateTime newEnd,
    String? timezone,
    String? userEmail,
    String? message,
  });

  Future<List<AttendeeAvailability>> getAttendeesSchedule({
    required List<String> emails,
    required DateTime start,
    required DateTime end,
  });

  /// The bookable rooms this account's directory offers.
  ///
  /// Returns an empty list — never throws — when the provider has no room
  /// directory, or when this account is not allowed to read the one it has.
  /// Listing rooms is an optional enrichment of the Location field, so a
  /// tenant that will not answer must not break saving an event.
  Future<List<MeetingRoom>> getMeetingRooms();
}
