import 'package:equatable/equatable.dart';
import 'package:fpdart/fpdart.dart';

import '../../core/error/failures.dart';
import '../../core/usecases/usecase.dart';
import '../entities/calendar_event.dart';
import '../entities/calendar_recurrence.dart';
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
    this.reminderMinutes,
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
        reminderMinutes,
      ];
}
