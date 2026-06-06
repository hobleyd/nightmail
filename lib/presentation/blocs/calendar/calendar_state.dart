import 'package:equatable/equatable.dart';

import '../../../domain/entities/calendar_event.dart';

sealed class CalendarState extends Equatable {
  const CalendarState({required this.weekStart});
  final DateTime weekStart;

  @override
  List<Object?> get props => [weekStart];
}

final class CalendarInitial extends CalendarState {
  const CalendarInitial({required super.weekStart});
}

final class CalendarLoading extends CalendarState {
  const CalendarLoading({required super.weekStart});
}

final class CalendarLoaded extends CalendarState {
  const CalendarLoaded({
    required super.weekStart,
    required this.events,
  });

  final List<CalendarEvent> events;

  @override
  List<Object?> get props => [weekStart, events];
}

final class CalendarError extends CalendarState {
  const CalendarError({
    required super.weekStart,
    required this.message,
  });

  final String message;

  @override
  List<Object?> get props => [weekStart, message];
}
