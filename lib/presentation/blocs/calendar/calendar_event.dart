import 'package:equatable/equatable.dart';

sealed class CalendarBlocEvent extends Equatable {
  const CalendarBlocEvent();

  @override
  List<Object?> get props => [];
}

final class CalendarWeekLoadRequested extends CalendarBlocEvent {
  const CalendarWeekLoadRequested({required this.weekStart});
  final DateTime weekStart;

  @override
  List<Object?> get props => [weekStart];
}

final class CalendarWeekNavigated extends CalendarBlocEvent {
  const CalendarWeekNavigated({required this.weekStart});
  final DateTime weekStart;

  @override
  List<Object?> get props => [weekStart];
}

final class CalendarEventCancelRequested extends CalendarBlocEvent {
  const CalendarEventCancelRequested({required this.eventId});
  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

final class CalendarEventDeclineRequested extends CalendarBlocEvent {
  const CalendarEventDeclineRequested({required this.eventId});
  final String eventId;

  @override
  List<Object?> get props => [eventId];
}

final class CalendarEventNewTimeProposed extends CalendarBlocEvent {
  const CalendarEventNewTimeProposed({
    required this.eventId,
    required this.newStart,
    required this.newEnd,
    this.timezone,
  });

  final String eventId;
  final DateTime newStart;
  final DateTime newEnd;
  final String? timezone;

  @override
  List<Object?> get props => [eventId, newStart, newEnd, timezone];
}
