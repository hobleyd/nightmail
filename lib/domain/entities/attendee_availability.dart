enum AttendeeAvailabilityStatus {
  free,
  tentative,
  busy,
  outOfOffice,
  workingElsewhere,
  unknown,
}

class AttendeeAvailability {
  const AttendeeAvailability({required this.email, required this.status});

  final String email;
  final AttendeeAvailabilityStatus status;
}
