import 'dart:convert';

import 'package:fpdart/fpdart.dart';

import '../../../../core/error/failures.dart';
import '../../../entities/calendar_event.dart';
import '../../../entities/commitment.dart';
import '../../../entities/workload_forecast.dart';
import '../../../repositories/commitment_repository.dart';
import '../../ai/agent/agent_tool.dart';
import '../forecast_workload.dart';
import '../schedule_commitment.dart';
import '../suggest_time_block.dart';

/// What the commitments agent knows at the start of a turn: the ledger, the
/// calendar ahead and the task due dates, as the pane already holds them.
class CommitmentsAgentSnapshot {
  const CommitmentsAgentSnapshot({
    required this.accountId,
    required this.commitments,
    required this.events,
    required this.taskDueDates,
    required this.now,
  });

  final String accountId;
  final List<Commitment> commitments;
  final List<CalendarEvent> events;
  final List<DateTime> taskDueDates;
  final DateTime now;

  List<Commitment> get open => [for (final c in commitments) if (c.isOpen) c];

  Commitment? byId(String id) {
    for (final c in commitments) {
      if (c.id == id) return c;
    }
    return null;
  }
}

/// Everything a commitment tool needs: the snapshot plus the actions that
/// change the ledger and the pure planners.
class CommitmentToolContext {
  const CommitmentToolContext({
    required this.snapshot,
    required this.scheduler,
    required this.ledger,
    required this.suggester,
    required this.forecaster,
  });

  final CommitmentsAgentSnapshot snapshot;
  final ScheduleCommitment scheduler;
  final CommitmentRepository ledger;
  final SuggestTimeBlock suggester;
  final ForecastWorkload forecaster;
}

/// The tool set for one agent turn.
List<AgentTool> buildCommitmentTools(CommitmentToolContext ctx) => [
      ListCommitmentsTool(ctx),
      GetForecastTool(ctx),
      FindFreeSlotTool(ctx),
      SuggestBlockTool(ctx),
      ScheduleBlockTool(ctx),
      MarkDoneTool(ctx),
      DismissTool(ctx),
    ];

// ---------------------------------------------------------------------------
// Reading
// ---------------------------------------------------------------------------

/// `list_commitments` — the open ledger with ids the other tools accept.
class ListCommitmentsTool implements AgentTool {
  const ListCommitmentsTool(this._ctx);

  final CommitmentToolContext _ctx;

  @override
  String get name => 'list_commitments';

  @override
  String get description =>
      'List the user\'s open commitments: things they owe (kind i_owe), '
      'things others owe them (they_owe_me) and received mail that needs a '
      'decision (needs_action). Each has an id to pass to the other tools, '
      'who it involves, the subject, how urgent it is (0 none, 1 soon, 2 '
      'blocking), when it is due, whether it is overdue, and the time block '
      'scheduled for it, if any. Call this first.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'kind': {
            'type': 'string',
            'enum': ['i_owe', 'they_owe_me', 'needs_action'],
            'description': 'Only this kind. Omit for all.',
          },
          'scheduled': {
            'type': 'boolean',
            'description':
                'true: only commitments that already have a time block; '
                'false: only ones without. Omit for both.',
          },
        },
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final kind = _kindFrom(args['kind']);
    final scheduled = args['scheduled'];
    final now = _ctx.snapshot.now;
    final items = [
      for (final c in _ctx.snapshot.open)
        if ((kind == null || c.kind == kind) &&
            (scheduled is! bool || c.isScheduled == scheduled))
          encodeCommitment(c, now),
    ];
    return Right(jsonEncode({
      'now': _iso(now),
      'count': items.length,
      'commitments': items,
    }));
  }
}

/// `get_forecast` — the week ahead as the pane computes it.
class GetForecastTool implements AgentTool {
  const GetForecastTool(this._ctx);

  final CommitmentToolContext _ctx;

  @override
  String get name => 'get_forecast';

  @override
  String get description =>
      'The week ahead, per working day: meeting minutes, minutes already '
      'blocked for commitments, free capacity, demand, whether the day is '
      'overloaded, which commitment ids land on it and how many tasks are '
      'due. Also the free gaps left in today. Use it to pick light days and '
      'to explain workload.';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': <String, dynamic>{},
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final s = _ctx.snapshot;
    final f = _ctx.forecaster(
      commitments: s.commitments,
      events: s.events,
      taskDueDates: s.taskDueDates,
      now: s.now,
    );
    return Right(jsonEncode(encodeForecast(f, _ctx.suggester)));
  }
}

/// `find_free_slot` — the first free run on a day.
class FindFreeSlotTool implements AgentTool {
  const FindFreeSlotTool(this._ctx);

  final CommitmentToolContext _ctx;

  @override
  String get name => 'find_free_slot';

  @override
  String get description =>
      'Find the first free run of the given length on a day, inside working '
      'hours and clear of meetings and existing blocks. Returns start/end to '
      'pass to schedule_block, or found=false.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'day': {
            'type': 'string',
            'description': '"today", "tomorrow", a weekday name (next such '
                'day, today included), or YYYY-MM-DD.',
          },
          'duration_minutes': {
            'type': 'integer',
            'description': 'Length of the block (default 60).',
          },
        },
        'required': ['day'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final day = resolveDay(args['day'], _ctx.snapshot.now);
    if (day == null) {
      return Right(jsonEncode({
        'error': 'Could not read the day "${args['day']}". Use today, '
            'tomorrow, a weekday name or YYYY-MM-DD.',
      }));
    }
    final minutes = (_asInt(args['duration_minutes']) ?? 60).clamp(15, 480);
    final slot = _ctx.suggester.firstFreeSlot(
      day: day,
      events: _ctx.snapshot.events,
      now: _ctx.snapshot.now,
      duration: Duration(minutes: minutes),
    );
    if (slot == null) {
      return Right(jsonEncode({
        'found': false,
        'day': _date(day),
        'message': 'No free $minutes-minute run on ${_weekday(day)} '
            '${_date(day)} inside working hours.',
      }));
    }
    return Right(jsonEncode({
      'found': true,
      'day': _date(day),
      'start': _iso(slot),
      'end': _iso(slot.add(Duration(minutes: minutes))),
    }));
  }
}

/// `suggest_block` — the planner's own pick for a commitment.
class SuggestBlockTool implements AgentTool {
  const SuggestBlockTool(this._ctx);

  final CommitmentToolContext _ctx;

  @override
  String get name => 'suggest_block';

  @override
  String get description =>
      'Where the planner would put a time block for a commitment: the '
      'lightest day in its horizon and the first free run there, with the '
      'reason. Use when the user leaves the day to you.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'commitment_id': {'type': 'string'},
          'duration_minutes': {
            'type': 'integer',
            'description': 'Length of the block (default 60).',
          },
        },
        'required': ['commitment_id'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final c = _ctx.snapshot.byId(_asString(args['commitment_id']) ?? '');
    if (c == null) return Right(_unknownId(args['commitment_id']));
    final minutes = (_asInt(args['duration_minutes']) ?? 60).clamp(15, 480);
    final s = _ctx.suggester(
      commitment: c,
      events: _ctx.snapshot.events,
      now: _ctx.snapshot.now,
      duration: Duration(minutes: minutes),
    );
    return Right(jsonEncode({
      'commitment_id': c.id,
      'start': _iso(s.start),
      'end': _iso(s.end),
      'has_conflict': s.hasConflict,
      'reason': s.reason,
    }));
  }
}

// ---------------------------------------------------------------------------
// Acting
// ---------------------------------------------------------------------------

/// `schedule_block` — books, or moves, a commitment's time block.
class ScheduleBlockTool implements AgentTool {
  const ScheduleBlockTool(this._ctx);

  final CommitmentToolContext _ctx;

  @override
  String get name => 'schedule_block';

  @override
  String get description =>
      'Block time on the calendar for a commitment at a given start. If the '
      'commitment already has a block, this moves it. Use find_free_slot or '
      'suggest_block to choose the start; the booking goes ahead even if it '
      'overlaps a meeting, and the result says so.';

  @override
  Map<String, dynamic> get parametersSchema => {
        'type': 'object',
        'properties': {
          'commitment_id': {'type': 'string'},
          'start': {
            'type': 'string',
            'description':
                'Local start time, e.g. 2026-10-08T14:00 (ISO 8601).',
          },
          'duration_minutes': {
            'type': 'integer',
            'description': 'Length of the block (default 60).',
          },
        },
        'required': ['commitment_id', 'start'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) async {
    final c = _ctx.snapshot.byId(_asString(args['commitment_id']) ?? '');
    if (c == null) return Right(_unknownId(args['commitment_id']));
    if (!c.isOpen) {
      return Right(jsonEncode({
        'error': 'Commitment ${c.id} is ${c.status.name}; reopen it before '
            'scheduling.',
      }));
    }
    final start = parseLocalDateTime(args['start']);
    if (start == null) {
      return Right(jsonEncode({
        'error': 'Could not read the start "${args['start']}". Use ISO 8601 '
            'local time such as 2026-10-08T14:00.',
      }));
    }
    final minutes = (_asInt(args['duration_minutes']) ?? 60).clamp(15, 480);
    final end = start.add(Duration(minutes: minutes));
    final wasScheduled = c.isScheduled;
    final overlaps = _ctx.suggester.conflicts(start, end, [
      for (final e in _ctx.snapshot.events)
        if (e.id != c.scheduledEventId) e,
    ]);

    final result = await _ctx.scheduler(c, start: start, end: end);
    return result.map((updated) => jsonEncode({
          'ok': true,
          'commitment_id': updated.id,
          'moved': wasScheduled,
          'start': _iso(start),
          'end': _iso(end),
          'overlaps_meeting': overlaps,
          'calendar_subject': ScheduleCommitment.subjectFor(updated),
        }));
  }
}

/// `mark_done` — closes a commitment as done.
class MarkDoneTool implements AgentTool {
  const MarkDoneTool(this._ctx);

  final CommitmentToolContext _ctx;

  @override
  String get name => 'mark_done';

  @override
  String get description =>
      'Mark a commitment done — the promise was kept, the reply sent, the '
      'thing received. Removes it from the open ledger.';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'commitment_id': {'type': 'string'},
        },
        'required': ['commitment_id'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) =>
      _setStatus(_ctx, args['commitment_id'], CommitmentStatus.done);
}

/// `dismiss` — drops a commitment the model detected wrongly or that no
/// longer matters.
class DismissTool implements AgentTool {
  const DismissTool(this._ctx);

  final CommitmentToolContext _ctx;

  @override
  String get name => 'dismiss';

  @override
  String get description =>
      'Dismiss a commitment that should not be tracked (detected wrongly, or '
      'no longer relevant). Removes it from the open ledger without calling '
      'it done.';

  @override
  Map<String, dynamic> get parametersSchema => const {
        'type': 'object',
        'properties': {
          'commitment_id': {'type': 'string'},
        },
        'required': ['commitment_id'],
      };

  @override
  Future<Either<Failure, String>> invoke(
    Map<String, dynamic> args, {
    String? currentFolderId,
  }) =>
      _setStatus(_ctx, args['commitment_id'], CommitmentStatus.dismissed);
}

Future<Either<Failure, String>> _setStatus(
  CommitmentToolContext ctx,
  Object? rawId,
  CommitmentStatus status,
) async {
  final c = ctx.snapshot.byId(_asString(rawId) ?? '');
  if (c == null) return Right(_unknownId(rawId));
  final result = await ctx.ledger.setStatus(
    accountId: ctx.snapshot.accountId,
    id: c.id,
    status: status,
    now: ctx.snapshot.now,
  );
  return result.map((_) => jsonEncode({
        'ok': true,
        'commitment_id': c.id,
        'status': status.name,
      }));
}

// ---------------------------------------------------------------------------
// Encoding
// ---------------------------------------------------------------------------

Map<String, dynamic> encodeCommitment(Commitment c, DateTime now) => {
      'id': c.id,
      'kind': _kindName(c.kind),
      'who': c.counterpart.displayName,
      'email': c.counterpart.address,
      'subject': c.subject,
      'excerpt': c.snippet.length <= 140
          ? c.snippet
          : '${c.snippet.substring(0, 137)}…',
      'due': c.due.name,
      'urgency': c.urgency,
      'overdue': c.isOverdueAt(now),
      'age_days': now.difference(c.emailDate).inDays,
      'scheduled': c.isScheduled
          ? {'start': _iso(c.scheduledStart!), 'end': _iso(c.scheduledEnd!)}
          : null,
    };

Map<String, dynamic> encodeForecast(
  WorkloadForecast f,
  SuggestTimeBlock suggester,
) =>
    {
      'now': _iso(f.computedAt),
      'working_hours':
          '${suggester.workingDayStartHour}:00-${suggester.workingDayEndHour}:00',
      'days': [
        for (final d in f.days)
          {
            'date': _date(d.day),
            'weekday': _weekday(d.day),
            'meeting_minutes': d.meetingMinutes,
            'blocked_minutes': d.blockedMinutes,
            'capacity_minutes': d.capacityMinutes,
            'demand_minutes': d.demandMinutes,
            'free_minutes': d.freeMinutes,
            'overloaded': d.isOverloaded,
            'tight': d.isTight,
            'landing_commitment_ids': [for (final c in d.landing) c.id],
            'tasks_due': d.tasksDue,
          },
      ],
      'overloaded_days': [for (final d in f.overloaded) _date(d.day)],
      'open_slots_today': [
        for (final s in f.openSlots)
          {
            'start': _iso(s.start),
            'end': _iso(s.end),
            'minutes': s.length.inMinutes,
            'suggested_commitment_id': s.suggestion?.id,
            'just_freed': s.freed,
          },
      ],
    };

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// "today", "tomorrow", a weekday name (the next such day, today included)
/// or `YYYY-MM-DD` → that day at midnight, local. Null when unreadable.
DateTime? resolveDay(Object? raw, DateTime now) {
  final text = _asString(raw)?.trim().toLowerCase();
  if (text == null || text.isEmpty) return null;
  final today = DateTime(now.year, now.month, now.day);
  if (text == 'today') return today;
  if (text == 'tomorrow') return today.add(const Duration(days: 1));
  const names = [
    'monday',
    'tuesday',
    'wednesday',
    'thursday',
    'friday',
    'saturday',
    'sunday',
  ];
  for (var i = 0; i < names.length; i++) {
    if (names[i].startsWith(text) && text.length >= 3) {
      var d = today;
      while (d.weekday != i + 1) {
        d = d.add(const Duration(days: 1));
      }
      return d;
    }
  }
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  final local = parsed.isUtc ? parsed.toLocal() : parsed;
  return DateTime(local.year, local.month, local.day);
}

/// An ISO 8601 date-time read as local time (a trailing `Z` is converted).
DateTime? parseLocalDateTime(Object? raw) {
  final text = _asString(raw)?.trim();
  if (text == null || text.isEmpty) return null;
  final parsed = DateTime.tryParse(text);
  if (parsed == null) return null;
  return parsed.isUtc ? parsed.toLocal() : parsed;
}

CommitmentKind? _kindFrom(Object? raw) {
  switch (_asString(raw)) {
    case 'i_owe':
      return CommitmentKind.iOwe;
    case 'they_owe_me':
      return CommitmentKind.theyOweMe;
    case 'needs_action':
      return CommitmentKind.needsAction;
    default:
      return null;
  }
}

String _kindName(CommitmentKind k) => switch (k) {
      CommitmentKind.iOwe => 'i_owe',
      CommitmentKind.theyOweMe => 'they_owe_me',
      CommitmentKind.needsAction => 'needs_action',
    };

String _unknownId(Object? raw) => jsonEncode({
      'error': 'No open commitment with id "$raw". Call list_commitments to '
          'get current ids.',
    });

String _iso(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}T${two(t.hour)}:${two(t.minute)}';
}

String _date(DateTime t) {
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)}';
}

String _weekday(DateTime t) => const [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
      'Saturday',
      'Sunday',
    ][t.weekday - 1];

String? _asString(Object? v) => v is String ? v : v?.toString();

int? _asInt(Object? v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  if (v is String) return int.tryParse(v);
  return null;
}
