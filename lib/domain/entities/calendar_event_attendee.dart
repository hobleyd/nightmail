import 'package:equatable/equatable.dart';

enum AttendeeResponseStatus { accepted, tentative, declined, none }

class CalendarEventAttendee extends Equatable {
  const CalendarEventAttendee({
    required this.email,
    this.displayName,
    this.responseStatus = AttendeeResponseStatus.none,
  });

  final String email;
  final String? displayName;
  final AttendeeResponseStatus responseStatus;

  String get displayLabel => displayName ?? email;

  @override
  List<Object?> get props => [email, responseStatus];
}
