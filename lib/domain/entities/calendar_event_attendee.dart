import 'package:equatable/equatable.dart';

enum AttendeeResponseStatus { accepted, tentative, declined, none }

class CalendarEventAttendee extends Equatable {
  const CalendarEventAttendee({
    required this.email,
    this.displayName,
    this.responseStatus = AttendeeResponseStatus.none,
    this.isResource = false,
  });

  final String email;
  final String? displayName;
  final AttendeeResponseStatus responseStatus;

  /// True for a room or equipment mailbox rather than a person (Graph
  /// `type: resource`, Google `resource: true`). Reopening a meeting relies on
  /// this to sort the roster back into the Location field's room chips and the
  /// Guests field, so a booked room is never mistaken for an invited colleague.
  final bool isResource;

  String get displayLabel => displayName ?? email;

  @override
  List<Object?> get props => [email, responseStatus, isResource];
}
