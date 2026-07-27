import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/calendar_event.dart';
import '../entities/calendar_recurrence.dart';
import '../entities/meeting_notify_scope.dart';
import '../repositories/calendar_repository.dart';

class UpdateCalendarEvent
    implements UseCase<CalendarEvent, UpdateCalendarEventParams> {
  const UpdateCalendarEvent(this._repository);

  final CalendarRepository _repository;

  @override
  Future<Either<Failure, CalendarEvent>> call(
      UpdateCalendarEventParams params) {
    return _repository.updateCalendarEvent(params: params);
  }
}

class UpdateCalendarEventParams extends Equatable {
  const UpdateCalendarEventParams({
    required this.id,
    required this.subject,
    required this.start,
    required this.end,
    required this.isAllDay,
    required this.timezone,
    this.location,
    this.description,
    this.attendeeEmails = const [],
    this.recurrence,
    this.isOnlineMeeting = false,
    this.reminderMinutes,
    this.notifyScope = MeetingNotifyScope.all,
  });

  final String id;
  final String subject;
  final DateTime start;
  final DateTime end;
  final bool isAllDay;

  /// IANA timezone identifier (e.g. "America/New_York").
  final String timezone;
  final String? location;
  final String? description;
  final List<String> attendeeEmails;
  final CalendarRecurrence? recurrence;

  /// Whether to attach a provider-native online meeting (Teams for Microsoft,
  /// Google Meet for Gmail). The datasource decides how to realize it.
  final bool isOnlineMeeting;

  /// Minutes before start to fire a reminder. Null means no reminder.
  final int? reminderMinutes;

  /// Which attendees to email about this save. Defaults to [MeetingNotifyScope.all]
  /// so callers that don't diff (e.g. drag-to-reschedule) keep notifying everyone.
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
        recurrence,
        isOnlineMeeting,
        reminderMinutes,
        notifyScope,
      ];
}
