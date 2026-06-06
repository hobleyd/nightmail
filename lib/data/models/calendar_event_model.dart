import '../../domain/entities/calendar_event.dart';

class CalendarEventModel extends CalendarEvent {
  const CalendarEventModel({
    required super.id,
    required super.subject,
    required super.start,
    required super.end,
    required super.isAllDay,
    super.location,
    super.bodyPreview,
    super.status,
    super.isOrganizer,
  });

  factory CalendarEventModel.fromJson(Map<String, dynamic> json) {
    return CalendarEventModel(
      id: json['id'] as String,
      subject: json['subject'] as String? ?? '(No title)',
      start: _parseDateTime(json['start'] as Map<String, dynamic>?),
      end: _parseDateTime(json['end'] as Map<String, dynamic>?),
      isAllDay: json['isAllDay'] as bool? ?? false,
      location: _parseLocation(json['location'] as Map<String, dynamic>?),
      bodyPreview: json['bodyPreview'] as String?,
      status: _parseStatus(json['showAs'] as String?),
      isOrganizer: json['isOrganizer'] as bool? ?? false,
    );
  }

  static DateTime _parseDateTime(Map<String, dynamic>? map) {
    if (map == null) return DateTime.now().toUtc();
    final dt = map['dateTime'] as String? ?? '';
    final tz = (map['timeZone'] as String? ?? '').toUpperCase();
    // When Prefer: outlook.timezone="UTC" is set, Graph returns UTC times
    // without the Z suffix — append it so Dart parses as UTC.
    final normalized =
        (tz == 'UTC' && !dt.endsWith('Z')) ? '${dt}Z' : dt;
    return DateTime.tryParse(normalized)?.toUtc() ?? DateTime.now().toUtc();
  }

  static String? _parseLocation(Map<String, dynamic>? map) {
    if (map == null) return null;
    final name = map['displayName'] as String?;
    return (name == null || name.isEmpty) ? null : name;
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
}
