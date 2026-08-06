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
