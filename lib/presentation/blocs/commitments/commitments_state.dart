import 'package:equatable/equatable.dart';

import '../../../domain/entities/calendar_event.dart';
import '../../../domain/entities/commitment.dart';
import '../../../domain/entities/workload_forecast.dart';

/// Lifecycle of the Commitments pane.
///
/// [scanning] is *loaded with a scan in flight*: the ledger already on disk is
/// shown while the model works through new mail, so a refresh never blanks
/// the pane.
enum CommitmentsStatus { initial, loading, scanning, loaded, error }

class CommitmentsState extends Equatable {
  const CommitmentsState({
    this.status = CommitmentsStatus.initial,
    this.accountId,
    this.commitments = const [],
    this.todayEvents = const [],
    this.tasksDueToday = 0,
    this.inboxScanned = 0,
    this.lastScanAt,
    this.lastClassified = 0,
    this.remaining = 0,
    this.message,
    this.needsTriageRoute = false,
    this.forecast,
  });

  final CommitmentsStatus status;

  /// The account the ledger belongs to.
  final String? accountId;

  /// The whole ledger, all statuses, newest message first.
  final List<Commitment> commitments;

  /// Today's calendar events for the account, from the local cache.
  final List<CalendarEvent> todayEvents;

  /// Open tasks due today, across every list of the account.
  final int tasksDueToday;

  /// How many of the Inbox messages on hand the model has looked at — the
  /// denominator behind "N emails need action · M don't".
  final int inboxScanned;

  final DateTime? lastScanAt;

  /// Messages shown to the model on the last scan.
  final int lastClassified;

  /// Unscanned messages still waiting for a later scan.
  final int remaining;

  /// An error (when [status] is [CommitmentsStatus.error]) or a warning from
  /// a scan that was cut short.
  final String? message;

  /// Triage has no System One provider routed, so nothing can be detected —
  /// the pane points at Settings › AI instead of showing an empty ledger.
  final bool needsTriageRoute;

  /// The week ahead: per-day load, overloaded days with a plan to lighten
  /// them, and gaps in today worth filling. Recomputed whenever the ledger
  /// or today's context is refreshed; null until the first load.
  final WorkloadForecast? forecast;

  List<Commitment> _open(CommitmentKind kind) => [
        for (final c in commitments)
          if (c.isOpen && c.kind == kind) c,
      ]..sort(_byUrgencyThenAge);

  /// "You owe": open promises I made, most urgent first.
  List<Commitment> get iOwe => _open(CommitmentKind.iOwe);

  /// "Waiting on": open items others owe me, most urgent first.
  List<Commitment> get waitingOn => _open(CommitmentKind.theyOweMe);

  /// "Needs a decision": received mail still awaiting my action.
  List<Commitment> get needsAction => _open(CommitmentKind.needsAction);

  /// Scanned Inbox messages that produced no *needs action* row — the "don't"
  /// half of the decision count. Never negative, even if the ledger holds
  /// rows for messages that have since left the Inbox listing.
  int get inboxNoActionCount {
    final needing = commitments
        .where((c) => c.kind == CommitmentKind.needsAction)
        .map((c) => c.emailId)
        .toSet()
        .length;
    final n = inboxScanned - needing;
    return n < 0 ? 0 : n;
  }

  /// Open commitments that belong in a Today view (due today or overdue).
  List<Commitment> dueTodayAt(DateTime now) => [
        for (final c in commitments)
          if (c.isDueTodayAt(now)) c,
      ]..sort(_byUrgencyThenAge);

  bool get hasAnyOpen => commitments.any((c) => c.isOpen);

  static int _byUrgencyThenAge(Commitment a, Commitment b) {
    final u = b.urgency.compareTo(a.urgency);
    if (u != 0) return u;
    return a.emailDate.compareTo(b.emailDate);
  }

  CommitmentsState copyWith({
    CommitmentsStatus? status,
    String? accountId,
    List<Commitment>? commitments,
    List<CalendarEvent>? todayEvents,
    int? tasksDueToday,
    int? inboxScanned,
    DateTime? lastScanAt,
    int? lastClassified,
    int? remaining,
    Object? message = _unset,
    bool? needsTriageRoute,
    WorkloadForecast? forecast,
  }) {
    return CommitmentsState(
      status: status ?? this.status,
      accountId: accountId ?? this.accountId,
      commitments: commitments ?? this.commitments,
      todayEvents: todayEvents ?? this.todayEvents,
      tasksDueToday: tasksDueToday ?? this.tasksDueToday,
      inboxScanned: inboxScanned ?? this.inboxScanned,
      lastScanAt: lastScanAt ?? this.lastScanAt,
      lastClassified: lastClassified ?? this.lastClassified,
      remaining: remaining ?? this.remaining,
      message: message == _unset ? this.message : message as String?,
      needsTriageRoute: needsTriageRoute ?? this.needsTriageRoute,
      forecast: forecast ?? this.forecast,
    );
  }

  @override
  List<Object?> get props => [
        status,
        accountId,
        commitments,
        todayEvents,
        tasksDueToday,
        inboxScanned,
        lastScanAt,
        lastClassified,
        remaining,
        message,
        needsTriageRoute,
        forecast,
      ];
}

const _unset = Object();
