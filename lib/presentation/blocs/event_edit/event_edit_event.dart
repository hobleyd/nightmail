import 'package:equatable/equatable.dart';

import '../../../domain/entities/calendar_recurrence.dart';

sealed class EventEditBlocEvent extends Equatable {
  const EventEditBlocEvent();

  @override
  List<Object?> get props => [];
}

final class EventEditSubmitted extends EventEditBlocEvent {
  const EventEditSubmitted({
    this.id,
    required this.subject,
    required this.start,
    required this.end,
    required this.isAllDay,
    required this.timezone,
    this.location,
    this.description,
    this.attendeeEmails = const [],
    this.recurrence,
    this.isTeamsMeeting = false,
    this.reminderMinutes,
  });

  /// Null for create, non-null for update.
  final String? id;
  final String subject;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;
  final String timezone;
  final String? location;
  final String? description;
  final List<String> attendeeEmails;
  final CalendarRecurrence? recurrence;
  final bool isTeamsMeeting;

  /// Minutes before start to fire a reminder. Null means no reminder.
  final int? reminderMinutes;

  @override
  List<Object?> get props => [
        id,
        subject,
        start,
        end,
        isAllDay,
        timezone,
        location,
        description,
        attendeeEmails,
        recurrence,
        isTeamsMeeting,
        reminderMinutes,
      ];
}
