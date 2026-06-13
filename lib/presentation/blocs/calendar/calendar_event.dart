import 'package:equatable/equatable.dart';

import '../../../domain/entities/calendar_event.dart';

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
    this.message,
  });

  final String eventId;
  final DateTime newStart;
  final DateTime newEnd;
  final String? timezone;
  final String? message;

  @override
  List<Object?> get props => [eventId, newStart, newEnd, timezone, message];
}

final class CalendarEventRescheduleRequested extends CalendarBlocEvent {
  const CalendarEventRescheduleRequested({
    required this.event,
    required this.newStart,
    required this.newEnd,
  });

  final CalendarEvent event;
  final DateTime newStart;
  final DateTime newEnd;

  @override
  List<Object?> get props => [event, newStart, newEnd];
}

final class CalendarEventSelectionToggled extends CalendarBlocEvent {
  const CalendarEventSelectionToggled({
    required this.eventId,
    this.addToSelection = false,
  });

  final String eventId;
  final bool addToSelection;

  @override
  List<Object?> get props => [eventId, addToSelection];
}

final class CalendarSelectionCleared extends CalendarBlocEvent {
  const CalendarSelectionCleared();
}

final class CalendarSelectedEventsDeleteRequested extends CalendarBlocEvent {
  const CalendarSelectedEventsDeleteRequested();
}
