enum AttendeeAvailabilityStatus {
  free,
  tentative,
  busy,
  outOfOffice,
  workingElsewhere,
  unknown,
}

class AttendeeScheduleItem {
  const AttendeeScheduleItem({
    required this.start,
    required this.end,
    required this.status,
    this.subject,
    this.isPrivate = false,
  });

  final DateTime start; // UTC
  final DateTime end;   // UTC
  final AttendeeAvailabilityStatus status;
  final String? subject;
  final bool isPrivate;
}

class AttendeeAvailability {
  const AttendeeAvailability({
    required this.email,
    required this.status,
    this.scheduleItems = const [],
  });

  final String email;
  final AttendeeAvailabilityStatus status;
  final List<AttendeeScheduleItem> scheduleItems;
}
