import 'package:equatable/equatable.dart';

import 'commitment.dart';

/// One working day of the week ahead, as `ForecastWorkload` expects it to go:
/// what the calendar already takes, what the user has blocked for
/// commitments, and what else lands on the day.
class DayForecast extends Equatable {
  const DayForecast({
    required this.day,
    required this.workingMinutes,
    required this.meetingMinutes,
    required this.blockedMinutes,
    required this.landing,
    required this.tasksDue,
    required this.minutesPerCommitment,
    required this.minutesPerTask,
  });

  /// Midnight, local time.
  final DateTime day;

  final int workingMinutes;

  /// Meetings inside the working window (merged), excluding the user's own
  /// commitment blocks.
  final int meetingMinutes;

  /// Time the user has already blocked for commitments on this day.
  final int blockedMinutes;

  /// Open commitments that land on this day: scheduled ones by their block,
  /// unscheduled ones by their due reading (today or overdue → today; this
  /// week → the week's last working day).
  final List<Commitment> landing;

  /// Open tasks due this day.
  final int tasksDue;

  /// Fallback estimate for an unscheduled commitment the model has not
  /// sized, and the flat estimate per task, in minutes.
  final int minutesPerCommitment;
  final int minutesPerTask;

  /// What is left of the working day once meetings are taken out.
  int get capacityMinutes =>
      meetingMinutes >= workingMinutes ? 0 : workingMinutes - meetingMinutes;

  /// Unscheduled commitments landing here — the ones still needing time.
  List<Commitment> get unscheduledLanding =>
      [for (final c in landing) if (!c.isScheduled) c];

  /// Time the day's commitments and tasks want: blocks as booked, each
  /// unscheduled commitment at its own estimate (or the fallback), tasks
  /// flat.
  int get demandMinutes =>
      blockedMinutes + unscheduledMinutes + tasksDue * minutesPerTask;

  /// What the unscheduled commitments landing here would take.
  int get unscheduledMinutes {
    var total = 0;
    for (final c in unscheduledLanding) {
      total += c.estimatedMinutes ?? minutesPerCommitment;
    }
    return total;
  }

  /// Capacity left after demand; negative when overloaded.
  int get freeMinutes => capacityMinutes - demandMinutes;

  bool get isOverloaded => demandMinutes > capacityMinutes;

  /// Not overloaded, but more than three quarters spoken for.
  bool get isTight =>
      !isOverloaded && capacityMinutes > 0 && demandMinutes / capacityMinutes > 0.75;

  /// Demand against capacity, 0 when there is nothing to do.
  double get pressure =>
      capacityMinutes == 0 ? (demandMinutes > 0 ? 2 : 0) : demandMinutes / capacityMinutes;

  @override
  List<Object?> get props => [
        day,
        workingMinutes,
        meetingMinutes,
        blockedMinutes,
        landing,
        tasksDue,
        minutesPerCommitment,
        minutesPerTask,
      ];
}

/// A gap in today's calendar large enough to work in, with the commitment
/// best placed to take it.
class OpenSlot extends Equatable {
  const OpenSlot({
    required this.start,
    required this.end,
    this.suggestion,
    this.freed = false,
  });

  final DateTime start;
  final DateTime end;

  /// The open, unscheduled commitment that should take the slot — the most
  /// pressing one that fits — or null when nothing is waiting.
  final Commitment? suggestion;

  /// True when a meeting occupied this time at the previous look and is gone
  /// now: the gap just opened, which is the moment to fill it.
  final bool freed;

  Duration get length => end.difference(start);

  @override
  List<Object?> get props => [start, end, suggestion, freed];
}

/// One proposed change to the schedule: a block moved, or a commitment given
/// a block it did not have.
class ScheduleMove extends Equatable {
  const ScheduleMove({
    required this.commitment,
    required this.from,
    required this.toStart,
    required this.toEnd,
  });

  final Commitment commitment;

  /// The block's current start, or null when the commitment had none.
  final DateTime? from;

  final DateTime toStart;
  final DateTime toEnd;

  bool get isNewBlock => from == null;

  Duration get length => toEnd.difference(toStart);

  @override
  List<Object?> get props => [commitment, from, toStart, toEnd];
}

/// How an overloaded day could be lightened: which blocks and commitments to
/// move to lighter days, and how much that relieves.
class RebalancePlan extends Equatable {
  const RebalancePlan({
    required this.day,
    required this.moves,
    required this.relievedMinutes,
  });

  final DayForecast day;
  final List<ScheduleMove> moves;

  /// Demand the moves take off [day].
  final int relievedMinutes;

  /// Whether the moves bring the day back within capacity.
  bool get resolves => day.demandMinutes - relievedMinutes <= day.capacityMinutes;

  @override
  List<Object?> get props => [day, moves, relievedMinutes];
}

/// The week ahead, read once from the calendar, the ledger and the task
/// reminders: per-day load, the days that are overloaded with a plan for
/// each, and the gaps in today worth filling.
class WorkloadForecast extends Equatable {
  const WorkloadForecast({
    required this.days,
    required this.plans,
    required this.openSlots,
    required this.computedAt,
  });

  final List<DayForecast> days;

  /// One plan per overloaded day, in day order. A plan may hold no moves
  /// when nothing on the day can be moved.
  final List<RebalancePlan> plans;

  /// Gaps left in today, soonest first.
  final List<OpenSlot> openSlots;

  final DateTime computedAt;

  List<DayForecast> get overloaded =>
      [for (final d in days) if (d.isOverloaded) d];

  bool get hasWarnings => overloaded.isNotEmpty;

  /// The first gap today that has something to put in it.
  OpenSlot? get fillableSlot {
    for (final s in openSlots) {
      if (s.suggestion != null) return s;
    }
    return null;
  }

  @override
  List<Object?> get props => [days, plans, openSlots, computedAt];
}
