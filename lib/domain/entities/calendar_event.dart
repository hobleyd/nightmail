import 'package:equatable/equatable.dart';

enum CalendarEventStatus { free, busy, tentative, outOfOffice, workingElsewhere }

class CalendarEvent extends Equatable {
  const CalendarEvent({
    required this.id,
    required this.subject,
    required this.start,
    required this.end,
    required this.isAllDay,
    this.location,
    this.bodyPreview,
    this.status = CalendarEventStatus.busy,
    this.isOrganizer = false,
  });

  final String id;
  final String subject;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String? location;
  final String? bodyPreview;
  final CalendarEventStatus status;
  final bool isOrganizer;

  Duration get duration => end.difference(start);

  @override
  List<Object?> get props => [id];
}
