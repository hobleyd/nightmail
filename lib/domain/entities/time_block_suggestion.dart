import 'package:equatable/equatable.dart';

import 'calendar_event.dart';

/// How full one working day already is, as `SuggestTimeBlock` read it off the
/// calendar: the minutes of the working window that meetings occupy, against
/// the window's length, so a UI can draw a load bar and name the lightest day.
class DayLoad extends Equatable {
  const DayLoad({
    required this.day,
    required this.committedMinutes,
    required this.workingMinutes,
  });

  /// Midnight, local time, of the day this describes.
  final DateTime day;

  /// Minutes of the working window taken by busy meetings (clipped to the
  /// window; overlapping meetings are not double-counted).
  final int committedMinutes;

  /// Length of the working window in minutes.
  final int workingMinutes;

  int get freeMinutes =>
      committedMinutes >= workingMinutes ? 0 : workingMinutes - committedMinutes;

  /// 0–1 share of the working day already committed.
  double get load =>
      workingMinutes == 0 ? 1 : (committedMinutes / workingMinutes).clamp(0, 1);

  @override
  List<Object?> get props => [day, committedMinutes, workingMinutes];
}

/// A proposed time block for a commitment, with the week it was chosen from
/// so the user can see why — and move it.
class TimeBlockSuggestion extends Equatable {
  const TimeBlockSuggestion({
    required this.start,
    required this.end,
    required this.days,
    required this.events,
    required this.hasConflict,
    required this.reason,
  });

  final DateTime start;
  final DateTime end;

  /// The candidate working days, in order, with their load — the whole
  /// horizon the suggestion considered.
  final List<DayLoad> days;

  /// The meetings on those days, so a picker can draw them and check a
  /// manual choice against them.
  final List<CalendarEvent> events;

  /// True when no free slot of the requested length existed anywhere in the
  /// horizon and [start] simply opens the lightest day — the user should
  /// look before confirming.
  final bool hasConflict;

  /// One sentence a UI can show: why this day.
  final String reason;

  Duration get duration => end.difference(start);

  @override
  List<Object?> get props => [start, end, days, events, hasConflict, reason];
}
