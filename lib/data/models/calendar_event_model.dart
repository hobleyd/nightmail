import '../../core/utils/online_meeting_url.dart';
import '../../domain/entities/calendar_event.dart';
import '../../domain/entities/calendar_event_attendee.dart';
import '../../domain/entities/calendar_recurrence.dart';

class CalendarEventModel extends CalendarEvent {
  const CalendarEventModel({
    required super.id,
    required super.subject,
    required super.start,
    required super.end,
    required super.isAllDay,
    super.iCalUid,
    super.location,
    super.onlineMeetingUrl,
    super.bodyPreview,
    super.status,
    super.participation,
    super.isOrganizer,
    super.organizerEmail,
    super.organizerName,
    super.timezone,
    super.attendees,
    super.recurrence,
    super.reminderMinutes,
    super.seriesMasterId,
  });

  factory CalendarEventModel.fromJson(Map<String, dynamic> json) {
    final split = splitMeetingLocation(
      rawLocation:
          (json['location'] as Map<String, dynamic>?)?['displayName'] as String?,
      onlineMeetingUrl:
          (json['onlineMeeting'] as Map<String, dynamic>?)?['joinUrl']
                  as String? ??
              json['onlineMeetingUrl'] as String?,
    );
    return CalendarEventModel(
      id: json['id'] as String,
      subject: json['subject'] as String? ?? '(No title)',
      start: _parseDateTime(json['start'] as Map<String, dynamic>?),
      end: _parseDateTime(json['end'] as Map<String, dynamic>?),
      isAllDay: json['isAllDay'] as bool? ?? false,
      iCalUid: json['iCalUId'] as String?,
      location: split.location,
      onlineMeetingUrl: split.onlineMeetingUrl,
      bodyPreview: json['bodyPreview'] as String?,
      status: _parseStatus(json['showAs'] as String?),
      participation: _parseParticipation(
        isOrganizer: json['isOrganizer'] as bool? ?? false,
        response:
            (json['responseStatus'] as Map<String, dynamic>?)?['response']
                as String?,
      ),
      isOrganizer: json['isOrganizer'] as bool? ?? false,
      organizerEmail: _organizerField(json, 'address'),
      organizerName: _organizerField(json, 'name'),
      timezone: (json['start'] as Map<String, dynamic>?)?['timeZone'] as String?,
      attendees: _parseAttendees(json['attendees'] as List<dynamic>?),
      recurrence: _parseRecurrence(json['recurrence'] as Map<String, dynamic>?),
      reminderMinutes: (json['isReminderOn'] as bool? ?? false)
          ? json['reminderMinutesBeforeStart'] as int?
          : null,
      seriesMasterId: json['seriesMasterId'] as String?,
    );
  }

  /// Reads `organizer.emailAddress.{address,name}`, which Graph omits entirely
  /// on an event with no organizer rather than sending an empty object.
  static String? _organizerField(Map<String, dynamic> json, String field) {
    final emailAddress = (json['organizer'] as Map<String, dynamic>?)?[
        'emailAddress'] as Map<String, dynamic>?;
    final value = (emailAddress?[field] as String?)?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  static DateTime _parseDateTime(Map<String, dynamic>? map) {
    if (map == null) return DateTime.now().toUtc();
    final dt = map['dateTime'] as String? ?? '';
    final tz = (map['timeZone'] as String? ?? '').toUpperCase();
    final normalized =
        (tz == 'UTC' && !dt.endsWith('Z')) ? '${dt}Z' : dt;
    return DateTime.tryParse(normalized)?.toUtc() ?? DateTime.now().toUtc();
  }

  static CalendarEventStatus _parseStatus(String? value) {
    return switch (value?.toLowerCase()) {
      'free' => CalendarEventStatus.free,
      'tentative' => CalendarEventStatus.tentative,
      'oof' => CalendarEventStatus.outOfOffice,
      'workingelsewhere' => CalendarEventStatus.workingElsewhere,
      _ => CalendarEventStatus.busy,
    };
  }

  /// Maps Graph's `isOrganizer` + `responseStatus.response`
  /// (organizer/accepted/tentativelyAccepted/notResponded/declined/none) onto
  /// the shared [MeetingParticipation] enum. `isOrganizer` wins so a meeting
  /// you own is always [MeetingParticipation.organizer] even if Exchange also
  /// auto-set your response to accepted.
  static MeetingParticipation _parseParticipation({
    required bool isOrganizer,
    String? response,
  }) {
    if (isOrganizer) return MeetingParticipation.organizer;
    return switch (response?.toLowerCase()) {
      'organizer' => MeetingParticipation.organizer,
      'accepted' => MeetingParticipation.accepted,
      'tentativelyaccepted' => MeetingParticipation.tentative,
      'notresponded' => MeetingParticipation.needsAction,
      'declined' => MeetingParticipation.declined,
      _ => MeetingParticipation.none,
    };
  }

  static List<CalendarEventAttendee> _parseAttendees(List<dynamic>? raw) {
    if (raw == null) return const [];
    return raw.cast<Map<String, dynamic>>().map((a) {
      final emailMap = a['emailAddress'] as Map<String, dynamic>? ?? {};
      return CalendarEventAttendee(
        email: emailMap['address'] as String? ?? '',
        displayName: emailMap['name'] as String?,
        responseStatus: _parseAttendeeStatus(a['status'] as Map<String, dynamic>?),
        // Graph reports a booked room as attendee type "resource". "optional"
        // and "required" are both people.
        isResource:
            (a['type'] as String?)?.toLowerCase() == 'resource',
      );
    }).where((a) => a.email.isNotEmpty).toList();
  }

  static AttendeeResponseStatus _parseAttendeeStatus(Map<String, dynamic>? map) {
    final response = map?['response'] as String?;
    return switch (response?.toLowerCase()) {
      'accepted' => AttendeeResponseStatus.accepted,
      'tentativelyaccepted' => AttendeeResponseStatus.tentative,
      'declined' => AttendeeResponseStatus.declined,
      _ => AttendeeResponseStatus.none,
    };
  }

  static CalendarRecurrence? _parseRecurrence(Map<String, dynamic>? map) {
    if (map == null) return null;
    final pattern = map['pattern'] as Map<String, dynamic>?;
    final range = map['range'] as Map<String, dynamic>?;
    if (pattern == null) return null;

    final type = pattern['type'] as String? ?? '';
    final frequency = switch (type.toLowerCase()) {
      'daily' => RecurrenceFrequency.daily,
      'weekly' => RecurrenceFrequency.weekly,
      'absolutemonthly' || 'relativemonthly' => RecurrenceFrequency.monthly,
      'absoluteyearly' || 'relativeyearly' => RecurrenceFrequency.yearly,
      _ => RecurrenceFrequency.daily,
    };

    final interval = pattern['interval'] as int? ?? 1;

    final rawDays = pattern['daysOfWeek'] as List<dynamic>?;
    final daysOfWeek = rawDays
        ?.cast<String>()
        .map(_parseDayOfWeek)
        .whereType<int>()
        .toList();

    DateTime? endDate;
    int? count;
    final rangeType = range?['type'] as String? ?? '';
    if (rangeType == 'endDate') {
      final s = range?['endDate'] as String?;
      endDate = s != null ? DateTime.tryParse(s) : null;
    } else if (rangeType == 'numbered') {
      count = range?['numberOfOccurrences'] as int?;
    }

    return CalendarRecurrence(
      frequency: frequency,
      interval: interval,
      daysOfWeek: daysOfWeek?.isNotEmpty == true ? daysOfWeek : null,
      endDate: endDate,
      count: count,
    );
  }

  static int? _parseDayOfWeek(String name) {
    return switch (name.toLowerCase()) {
      'monday' => 1,
      'tuesday' => 2,
      'wednesday' => 3,
      'thursday' => 4,
      'friday' => 5,
      'saturday' => 6,
      'sunday' => 7,
      _ => null,
    };
  }
}
