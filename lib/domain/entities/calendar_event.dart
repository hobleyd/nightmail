import 'package:equatable/equatable.dart';

import 'calendar_event_attendee.dart';
import 'calendar_recurrence.dart';

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
    this.timezone,
    this.attendees = const [],
    this.recurrence,
    this.reminderMinutes,
    this.seriesMasterId,
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

  /// IANA timezone string (e.g. "America/New_York"). Null means UTC.
  final String? timezone;

  final List<CalendarEventAttendee> attendees;
  final CalendarRecurrence? recurrence;

  /// Minutes before the event start to fire a reminder. Null means no reminder.
  final int? reminderMinutes;

  /// Non-null when this event is an occurrence within a recurring series.
  /// Holds the ID of the series master event (Graph: seriesMasterId, Google: recurringEventId).
  final String? seriesMasterId;

  bool get isRecurringOccurrence => seriesMasterId != null;

  Duration get duration => end.difference(start);

  @override
  List<Object?> get props => [id];
}
