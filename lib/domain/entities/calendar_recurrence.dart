import 'package:equatable/equatable.dart';

enum RecurrenceFrequency { daily, weekly, monthly, yearly }

class CalendarRecurrence extends Equatable {
  const CalendarRecurrence({
    required this.frequency,
    this.interval = 1,
    this.daysOfWeek,
    this.endDate,
    this.count,
  });

  final RecurrenceFrequency frequency;
  final int interval;

  /// Days of week for weekly recurrence: 1=Mon, 2=Tue, ..., 7=Sun.
  final List<int>? daysOfWeek;

  /// End by a specific date (mutually exclusive with [count]).
  final DateTime? endDate;

  /// End after N occurrences (mutually exclusive with [endDate]).
  final int? count;

  @override
  List<Object?> get props => [frequency, interval, daysOfWeek, endDate, count];

  /// Backends (Graph, CalDAV, Google) only support [daysOfWeek] restrictions
  /// on weekly recurrence, so "daily on Mon-Fri" is only representable on
  /// the wire as "weekly on Mon-Fri". Interval is reset to 1 since "every N
  /// days" has no well-defined meaning once expressed as a weekly rule.
  CalendarRecurrence normalizedForSync() {
    if (frequency == RecurrenceFrequency.daily &&
        daysOfWeek != null &&
        daysOfWeek!.isNotEmpty &&
        daysOfWeek!.length < 7) {
      return CalendarRecurrence(
        frequency: RecurrenceFrequency.weekly,
        interval: 1,
        daysOfWeek: daysOfWeek,
        endDate: endDate,
        count: count,
      );
    }
    return this;
  }
}
