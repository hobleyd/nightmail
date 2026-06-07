import 'package:equatable/equatable.dart';

import '../../../domain/entities/calendar_event.dart';

sealed class EventEditState extends Equatable {
  const EventEditState();

  @override
  List<Object?> get props => [];
}

final class EventEditInitial extends EventEditState {
  const EventEditInitial();
}

final class EventEditSaving extends EventEditState {
  const EventEditSaving();
}

final class EventEditSaved extends EventEditState {
  const EventEditSaved({required this.event});
  final CalendarEvent event;

  @override
  List<Object?> get props => [event];
}

final class EventEditError extends EventEditState {
  const EventEditError({required this.message});
  final String message;

  @override
  List<Object?> get props => [message];
}
