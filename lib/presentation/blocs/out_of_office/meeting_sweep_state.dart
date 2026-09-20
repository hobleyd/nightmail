import 'package:equatable/equatable.dart';

import '../../../domain/entities/calendar_event.dart';

enum MeetingSweepStatus {
  /// Nothing requested yet.
  idle,

  /// Fetching events in the window.
  loading,

  /// [MeetingSweepState.accepted]/[MeetingSweepState.organized] are ready and
  /// the user is choosing which to act on.
  ready,

  /// Nothing in the window needs a decision — the window is genuinely clear,
  /// not an error.
  empty,

  /// Applying the chosen declines/cancellations.
  applying,

  /// [MeetingSweepState.results] holds a per-meeting outcome.
  done,

  error,
}

/// Whether a meeting was declined (an accepted invite) or cancelled (one the
/// user organizes, which emails every attendee). Two different providers-side
/// calls and two different blast radii — see [MeetingSweepCubit].
enum MeetingSweepAction { decline, cancel }

/// The outcome of applying [MeetingSweepAction] to one meeting.
class MeetingSweepResult extends Equatable {
  const MeetingSweepResult({
    required this.eventId,
    required this.subject,
    required this.action,
    required this.succeeded,
    this.errorMessage,
  });

  final String eventId;
  final String subject;
  final MeetingSweepAction action;
  final bool succeeded;
  final String? errorMessage;

  @override
  List<Object?> get props => [eventId, subject, action, succeeded, errorMessage];
}

class MeetingSweepState extends Equatable {
  const MeetingSweepState({
    this.status = MeetingSweepStatus.idle,
    this.windowStart,
    this.windowEnd,
    this.accepted = const [],
    this.organized = const [],
    this.selectedIds = const {},
    this.results = const [],
    this.errorMessage,
  });

  final MeetingSweepStatus status;

  /// The Out of Office window this sweep was run for.
  final DateTime? windowStart;
  final DateTime? windowEnd;

  /// Meetings the user accepted as an attendee — [MeetingSweepAction.decline].
  final List<CalendarEvent> accepted;

  /// Meetings the user organizes — [MeetingSweepAction.cancel]. Listed
  /// separately because cancelling emails every attendee, which is not the
  /// same act as declining and must never be pre-selected.
  final List<CalendarEvent> organized;

  /// Which event ids the user has ticked to act on. Every accepted meeting
  /// starts ticked; every organized meeting starts unticked — see
  /// [MeetingSweepCubit.load].
  final Set<String> selectedIds;

  final List<MeetingSweepResult> results;
  final String? errorMessage;

  int get selectedAcceptedCount =>
      accepted.where((e) => selectedIds.contains(e.id)).length;

  int get selectedOrganizedCount =>
      organized.where((e) => selectedIds.contains(e.id)).length;

  int get selectedTotal => selectedIds.length;

  int get failedCount => results.where((r) => !r.succeeded).length;

  MeetingSweepState copyWith({
    MeetingSweepStatus? status,
    DateTime? windowStart,
    DateTime? windowEnd,
    List<CalendarEvent>? accepted,
    List<CalendarEvent>? organized,
    Set<String>? selectedIds,
    List<MeetingSweepResult>? results,
    String? errorMessage,
    bool clearError = false,
  }) {
    return MeetingSweepState(
      status: status ?? this.status,
      windowStart: windowStart ?? this.windowStart,
      windowEnd: windowEnd ?? this.windowEnd,
      accepted: accepted ?? this.accepted,
      organized: organized ?? this.organized,
      selectedIds: selectedIds ?? this.selectedIds,
      results: results ?? this.results,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
    );
  }

  @override
  List<Object?> get props => [
    status,
    windowStart,
    windowEnd,
    accepted,
    organized,
    selectedIds,
    results,
    errorMessage,
  ];
}
