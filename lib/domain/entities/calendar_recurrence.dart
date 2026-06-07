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
}
