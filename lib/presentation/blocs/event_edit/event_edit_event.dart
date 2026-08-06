import 'package:equatable/equatable.dart';

import '../../../domain/entities/calendar_recurrence.dart';
import '../../../domain/entities/meeting_notify_scope.dart';

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
    this.roomEmails = const [],
    this.recurrence,
    this.isOnlineMeeting = false,
    this.reminderMinutes,
    this.notifyScope = MeetingNotifyScope.all,
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

  /// Rooms to book, as mailbox addresses. Kept apart from [attendeeEmails]
  /// because they are invited as resources rather than people; see
  /// `CreateCalendarEventParams.roomEmails`.
  final List<String> roomEmails;

  final CalendarRecurrence? recurrence;

  /// Whether to attach a provider-native online meeting (Teams or Google Meet).
  final bool isOnlineMeeting;

  /// Minutes before start to fire a reminder. Null means no reminder.
  final int? reminderMinutes;

  /// Which attendees to email about this save (updates only; ignored on create,
  /// where every attendee is always invited).
  final MeetingNotifyScope notifyScope;

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
        roomEmails,
        recurrence,
        isOnlineMeeting,
        reminderMinutes,
        notifyScope,
      ];
}
