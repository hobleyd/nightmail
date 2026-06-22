import '../../../domain/entities/attendee_availability.dart';
import '../../../domain/entities/meeting_invite.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../models/calendar_event_model.dart';

abstract interface class CalendarRemoteDatasource {
  Future<List<CalendarEventModel>> getCalendarEvents({
    required DateTime startDateTime,
    required DateTime endDateTime,
  });

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

  Future<void> cancelCalendarEvent({required String eventId});

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
}
