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
