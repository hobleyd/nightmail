import 'package:equatable/equatable.dart';

import '../../../domain/entities/calendar_event.dart';

sealed class CalendarState extends Equatable {
  const CalendarState({required this.weekStart, this.spanDays = 7});

  /// The Monday the loaded range starts on.
  final DateTime weekStart;

  /// How many days from [weekStart] the loaded range covers: 7 for a week view,
  /// 42 (six weeks) for the month grid. A refresh that does not say otherwise
  /// keeps whatever span is showing, so a mutation or a relay from another
  /// window does not collapse a month back to its first week.
  final int spanDays;

  DateTime get rangeEnd => weekStart.add(Duration(days: spanDays));

  @override
  List<Object?> get props => [weekStart, spanDays];
}

final class CalendarInitial extends CalendarState {
  const CalendarInitial({required super.weekStart, super.spanDays});
}

final class CalendarLoading extends CalendarState {
  const CalendarLoading({required super.weekStart, super.spanDays});
}

final class CalendarLoaded extends CalendarState {
  const CalendarLoaded({
    required super.weekStart,
    super.spanDays,
    required this.events,
    this.selectedEventIds = const {},
    this.isSyncing = false,
    this.syncError,
  });

  final List<CalendarEvent> events;
  final Set<String> selectedEventIds;

  /// True while these events came from the local cache and the provider is
  /// still being asked. [CalendarLoading] is for having nothing to show at all;
  /// this is for having something to show that may yet change, and the week
  /// stays drawn rather than being replaced by a spinner.
  final bool isSyncing;

  /// Set when the refresh behind these events failed but the cache had a week to
  /// show anyway. Cached meetings are almost always still right, so they stay on
  /// screen with the reason reported beside them — as opposed to [CalendarError],
  /// which is a failure with nothing to fall back on.
  final String? syncError;

  CalendarLoaded copyWithSelection(Set<String> ids) => CalendarLoaded(
        weekStart: weekStart,
        spanDays: spanDays,
        events: events,
        selectedEventIds: ids,
        isSyncing: isSyncing,
        syncError: syncError,
      );

  @override
  List<Object?> get props =>
      [weekStart, spanDays, events, selectedEventIds, isSyncing, syncError];
}

final class CalendarError extends CalendarState {
  const CalendarError({
    required super.weekStart,
    super.spanDays,
    required this.message,
  });

  final String message;

  @override
  List<Object?> get props => [weekStart, spanDays, message];
}
