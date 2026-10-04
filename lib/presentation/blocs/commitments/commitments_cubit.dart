import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../core/utils/inbox_folder.dart';
import '../../../core/utils/outgoing_folder.dart';
import '../../../core/utils/task_due.dart';
import '../../../data/datasources/local/task_reminder_schedule_local_datasource.dart';
import '../../../domain/entities/calendar_event.dart';
import '../../../domain/entities/commitment.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/entities/time_block_suggestion.dart';
import '../../../domain/entities/workload_forecast.dart';
import '../../../domain/repositories/commitment_repository.dart';
import '../../../domain/repositories/email_repository.dart';
import '../../../domain/usecases/commitments/commitment_ledger_changes.dart';
import '../../../domain/usecases/commitments/detect_commitments.dart';
import '../../../domain/usecases/commitments/agent/commitment_agent_tools.dart';
import '../../../domain/usecases/commitments/forecast_workload.dart';
import '../../../domain/usecases/commitments/schedule_commitment.dart';
import '../../../domain/usecases/commitments/suggest_time_block.dart';
import '../../../domain/usecases/create_calendar_event.dart';
import '../../../domain/usecases/update_calendar_event.dart';
import '../../../domain/usecases/get_cached_calendar_events.dart';
import '../../../domain/usecases/get_calendar_events.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'commitments_state.dart';

/// Drives the Commitments pane for the active account.
///
/// Everything it shows comes from the local cache: the ledger rows, the
/// account's cached Sent and Inbox listings (what the model is asked about),
/// today's cached calendar events and the task-reminder rows. The only
/// network it causes is the model's own calls, made through
/// [DetectCommitments] — one per unscanned message, capped per scan.
///
/// [load] paints the ledger on disk at once and then runs a scan in the
/// background; [scan] is the explicit refresh and what the pane calls when a
/// poll cycle brings new mail.
class CommitmentsCubit extends Cubit<CommitmentsState> {
  CommitmentsCubit({
    required AccountManager accountManager,
    required EmailRepository emailRepository,
    required CommitmentRepository commitmentRepository,
    required DetectCommitments detectCommitments,
    required GetCachedCalendarEvents getCachedCalendarEvents,
    required TaskReminderScheduleLocalDatasource taskReminders,
    required CreateCalendarEvent createCalendarEvent,
    required UpdateCalendarEvent updateCalendarEvent,
    CommitmentLedgerChanges? ledgerChanges,
    this.suggester = const SuggestTimeBlock(),
    this.forecaster = const ForecastWorkload(),
    DateTime Function()? now,
  })  : _accounts = accountManager,
        _emails = emailRepository,
        _ledger = commitmentRepository,
        _detect = detectCommitments,
        _calendar = getCachedCalendarEvents,
        _taskReminders = taskReminders, // ignore: prefer_initializing_formals
        _scheduler = ScheduleCommitment(
          createCalendarEvent: createCalendarEvent,
          updateCalendarEvent: updateCalendarEvent,
          commitmentRepository: commitmentRepository,
        ),
        _now = now ?? DateTime.now,
        super(const CommitmentsState()) {
    // A row written outside this cubit (the reading pane's Track action)
    // for the account on screen: re-read the ledger, no model involved.
    _changesSub = ledgerChanges?.stream.listen((accountId) {
      if (accountId == state.accountId) unawaited(reloadLedger());
    });
  }

  StreamSubscription<String>? _changesSub;

  @override
  Future<void> close() async {
    await _changesSub?.cancel();
    return super.close();
  }

  final AccountManager _accounts;
  final EmailRepository _emails;
  final CommitmentRepository _ledger;
  final DetectCommitments _detect;
  final GetCachedCalendarEvents _calendar;
  final TaskReminderScheduleLocalDatasource _taskReminders;
  final ScheduleCommitment _scheduler;
  final DateTime Function() _now;

  /// The pure time-block logic, exposed so the scheduling UI can re-run its
  /// free-slot and conflict checks against a day the user picked by hand with
  /// the same working hours and slot grid the suggestion used.
  final SuggestTimeBlock suggester;

  /// "Future Me": the week-ahead forecast, recomputed with every refresh.
  final ForecastWorkload forecaster;

  /// The calendar as it was at the previous forecast, so a meeting that has
  /// since disappeared can mark the gap it left as *freed*.
  List<CalendarEvent>? _lastEvents;

  /// Task due dates as of the last context read, for the agent snapshot.
  List<DateTime> _lastTaskDueDates = const [];

  /// Gap starts once recognised as freed. The comparison above only sees the
  /// disappearance at the first refresh after it; this keeps the label on the
  /// slot until it is filled or the time has passed.
  final Set<DateTime> _freedSlotStarts = {};

  /// How far ahead the calendar is read when suggesting a time block — wide
  /// enough for the longest horizon `SuggestTimeBlock` considers.
  static const Duration scheduleLookahead = Duration(days: 14);

  /// Reminder on a scheduled block — see [ScheduleCommitment.reminderMinutes].
  static const int blockReminderMinutes = ScheduleCommitment.reminderMinutes;

  /// How much of each folder's cached listing the scan considers.
  static const int recentMailWindow = 60;

  /// Guards against overlapping scans (a poll cycle landing mid-refresh).
  Future<void>? _inFlightScan;

  /// Paints the cached ledger and today's context for the active account,
  /// then scans new mail in the background.
  Future<void> load() async {
    final account = _accounts.activeAccount;
    if (account == null) {
      emit(const CommitmentsState(
        status: CommitmentsStatus.error,
        message: 'Sign in to an account to track commitments.',
      ));
      return;
    }
    emit(state.copyWith(
      status: CommitmentsStatus.loading,
      accountId: account.id,
      message: null,
    ));

    final ledger = await _ledger.getCommitments(accountId: account.id);
    if (isClosed) return;
    final ctx = await _contextFor(
      account.id,
      ledger.getOrElse((_) => state.commitments),
    );
    if (isClosed) return;

    ledger.fold(
      (failure) => emit(state.copyWith(
        status: CommitmentsStatus.error,
        message: failure.message,
      )),
      (commitments) => emit(state.copyWith(
        status: CommitmentsStatus.loaded,
        commitments: commitments,
        todayEvents: ctx.events,
        tasksDueToday: ctx.tasksDue,
        forecast: ctx.forecast,
      )),
    );
    if (state.status == CommitmentsStatus.loaded) unawaited(scan());
  }

  /// Shows the model whatever Sent/Inbox mail it has not seen, closes what the
  /// mail has since settled, and refreshes today's context. Safe to call
  /// repeatedly; a call during a scan joins it.
  Future<void> scan() {
    return _inFlightScan ??= _doScan().whenComplete(() => _inFlightScan = null);
  }

  Future<void> _doScan() async {
    final account = _accounts.activeAccount;
    if (account == null || isClosed) return;
    if (state.accountId != account.id) {
      // The active account changed under us: start over for the new one.
      await load();
      return;
    }
    emit(state.copyWith(status: CommitmentsStatus.scanning, message: null));

    final mail = await _recentMail(account.id);
    if (isClosed) return;

    final result = await _detect(DetectCommitmentsParams(
      accountId: account.id,
      selfAddresses: {account.emailAddress.toLowerCase()},
      sentEmails: mail.sent,
      inboxEmails: mail.inbox,
      now: _now(),
    ));
    if (isClosed) return;

    final scanned = await _ledger.getScannedEmailIds(accountId: account.id);
    final inboxScanned = scanned.fold(
      (_) => state.inboxScanned,
      (ids) => mail.inbox.where((e) => ids.contains(e.id)).length,
    );
    final nextCommitments =
        result.fold((_) => state.commitments, (r) => r.commitments);
    final ctx = await _contextFor(account.id, nextCommitments);
    if (isClosed) return;

    result.fold(
      (failure) {
        final noRoute = failure is NoProviderConfigured;
        emit(state.copyWith(
          // With a ledger already on screen a failed refresh is a message,
          // not a blank pane.
          status: state.commitments.isEmpty && !noRoute
              ? CommitmentsStatus.error
              : CommitmentsStatus.loaded,
          needsTriageRoute: noRoute,
          message: failure.message,
          todayEvents: ctx.events,
          tasksDueToday: ctx.tasksDue,
          forecast: ctx.forecast,
          inboxScanned: inboxScanned,
        ));
      },
      (r) {
        emit(state.copyWith(
          status: CommitmentsStatus.loaded,
          commitments: r.commitments,
          needsTriageRoute: false,
          message: r.warning,
          lastScanAt: _now(),
          lastClassified: r.classified,
          lastModel: r.model,
          remaining: r.remaining,
          todayEvents: ctx.events,
          tasksDueToday: ctx.tasksDue,
          forecast: ctx.forecast,
          inboxScanned: inboxScanned,
        ));
      },
    );
  }

  Future<void> markDone(String id) => _setStatus(id, CommitmentStatus.done);

  Future<void> dismiss(String id) => _setStatus(id, CommitmentStatus.dismissed);

  Future<void> reopen(String id) => _setStatus(id, CommitmentStatus.open);

  Future<void> _setStatus(String id, CommitmentStatus status) async {
    final accountId = state.accountId;
    if (accountId == null) return;
    final now = _now();
    final result = await _ledger.setStatus(
      accountId: accountId,
      id: id,
      status: status,
      now: now,
    );
    if (isClosed) return;
    result.fold(
      (failure) => emit(state.copyWith(message: failure.message)),
      (_) => emit(state.copyWith(
        commitments: [
          for (final c in state.commitments)
            c.id == id
                ? c.copyWith(
                    status: status,
                    resolvedAt: status == CommitmentStatus.open ? null : now,
                    clearResolvedAt: status == CommitmentStatus.open,
                  )
                : c,
        ],
      )),
    );
  }

  // ---------------------------------------------------------------------------
  // Scheduling
  // ---------------------------------------------------------------------------

  /// Proposes a time block for [commitment] from the cached calendar: the
  /// lightest working day in its horizon and the first free run on it (see
  /// `SuggestTimeBlock`). Also returns the days and meetings it considered so
  /// the picker can show them and let the user move the block. [duration]
  /// defaults to the model's effort estimate for the commitment.
  Future<TimeBlockSuggestion> suggestTimeBlock(
    Commitment commitment, {
    Duration? duration,
  }) async {
    final now = _now();
    final start = DateTime(now.year, now.month, now.day);
    final events = state.accountId == null
        ? const <CalendarEvent>[]
        : (await _calendar(GetCalendarEventsParams(
            startDateTime: start,
            endDateTime: start.add(scheduleLookahead),
            accountId: state.accountId,
          )))
            .getOrElse((_) => const []);
    return suggester(
      commitment: commitment,
      events: events,
      now: now,
      duration: duration,
    );
  }

  /// Blocks [start]–[end] on the account's calendar for [commitment] and
  /// records the event on the ledger. A commitment that already has a block
  /// has that event *moved*; if the event is gone (deleted by hand) a new one
  /// is created instead. Returns whether the calendar accepted it; a failure
  /// is surfaced through [CommitmentsState.message].
  Future<bool> schedule(
    Commitment commitment, {
    required DateTime start,
    required DateTime end,
  }) async {
    final accountId = state.accountId;
    if (accountId == null) return false;

    final result = await _scheduler(commitment, start: start, end: end);
    if (isClosed) return false;

    final scheduled = result.fold((_) => null, (c) => c);
    if (scheduled == null) {
      emit(state.copyWith(
        message: result.fold((f) => f.message, (_) => null),
      ));
      return false;
    }

    final updated = [
      for (final c in state.commitments)
        c.id == commitment.id ? scheduled : c,
    ];
    // A block that fills a freed gap retires the label.
    _freedSlotStarts.remove(start);
    final ctx = await _contextFor(accountId, updated);
    if (isClosed) return true;
    emit(state.copyWith(
      message: null,
      commitments: updated,
      todayEvents: ctx.events,
      tasksDueToday: ctx.tasksDue,
      forecast: ctx.forecast,
    ));
    return true;
  }

  /// Applies a rebalance plan's chosen [moves] one after another — each is a
  /// [schedule] — and returns how many the calendar accepted. Stops at the
  /// first refusal so the failure message in state is about that move.
  Future<int> applyMoves(List<ScheduleMove> moves) async {
    var applied = 0;
    for (final move in moves) {
      // Use the ledger's current copy of the commitment: an earlier move in
      // the same plan may already have given it a block id to reuse.
      final current = state.commitments
          .where((c) => c.id == move.commitment.id)
          .cast<Commitment?>()
          .firstWhere((_) => true, orElse: () => null);
      final ok = await schedule(
        current ?? move.commitment,
        start: move.toStart,
        end: move.toEnd,
      );
      if (!ok || isClosed) break;
      applied++;
    }
    return applied;
  }

  /// Puts the slot's suggested commitment into the gap: its estimated length
  /// when the gap has that much, otherwise the whole gap.
  Future<bool> fillSlot(OpenSlot slot) async {
    final target = slot.suggestion;
    if (target == null) return false;
    final wanted = SuggestTimeBlock.durationFor(target);
    final length = slot.length >= wanted ? wanted : slot.length;
    return schedule(target, start: slot.start, end: slot.start.add(length));
  }

  // ---------------------------------------------------------------------------
  // Natural-language control
  // ---------------------------------------------------------------------------

  /// What the commitments agent sees at the start of a turn: the ledger and
  /// the context as of the last refresh. Null until an account has loaded.
  CommitmentsAgentSnapshot? agentSnapshot() {
    final accountId = state.accountId;
    if (accountId == null) return null;
    return CommitmentsAgentSnapshot(
      accountId: accountId,
      commitments: state.commitments,
      events: _lastEvents ?? const [],
      taskDueDates: _lastTaskDueDates,
      now: _now(),
    );
  }

  /// Re-reads the ledger and today's context without a model scan — what the
  /// agent's tools changed is on disk, and this brings it on screen.
  Future<void> reloadLedger() async {
    final accountId = state.accountId;
    if (accountId == null || isClosed) return;
    final ledger = await _ledger.getCommitments(accountId: accountId);
    if (isClosed) return;
    final commitments = ledger.getOrElse((_) => state.commitments);
    final ctx = await _contextFor(accountId, commitments);
    if (isClosed) return;
    emit(state.copyWith(
      commitments: commitments,
      todayEvents: ctx.events,
      tasksDueToday: ctx.tasksDue,
      forecast: ctx.forecast,
    ));
  }

  // ---------------------------------------------------------------------------
  // Inputs
  // ---------------------------------------------------------------------------

  /// The newest [recentMailWindow] cached messages of the account's Sent and
  /// Inbox folders, found by well-known id or display name in the folder
  /// cache. A folder that cannot be found contributes nothing — the scan runs
  /// on whichever side is available.
  Future<({List<Email> sent, List<Email> inbox})> _recentMail(
    String accountId,
  ) async {
    final folders = (await _emails.getCachedFolders(accountId))
        .getOrElse((_) => const []);
    final sentMatches = folders.where(isSentMailFolder);
    final inboxMatches = folders.where(isInboxFolder);
    final sentFolder = sentMatches.isEmpty ? null : sentMatches.first;
    final inboxFolder = inboxMatches.isEmpty ? null : inboxMatches.first;

    Future<List<Email>> recent(String? folderId) async {
      if (folderId == null) return const [];
      final emails = (await _emails.getCachedEmails(
        accountId: accountId,
        folderId: folderId,
      ))
          .getOrElse((_) => const []);
      // The cache is ordered newest first already; make sure of it.
      final sorted = List<Email>.of(emails)
        ..sort((a, b) => (b.sentDateTime ?? b.receivedDateTime)
            .compareTo(a.sentDateTime ?? a.receivedDateTime));
      return sorted.take(recentMailWindow).toList();
    }

    return (
      sent: await recent(sentFolder?.id),
      inbox: await recent(inboxFolder?.id),
    );
  }

  /// Today's events, the count of open tasks due today, and the week-ahead
  /// forecast — from one read of the calendar cache over [scheduleLookahead]
  /// and the task-reminder rows (which cover every list). [commitments] is
  /// the ledger the forecast should describe: the list about to be emitted,
  /// which is not always the one in state.
  Future<({List<CalendarEvent> events, int tasksDue, WorkloadForecast forecast})>
      _contextFor(String accountId, List<Commitment> commitments) async {
    final now = _now();
    final start = DateTime(now.year, now.month, now.day);
    final tomorrow = start.add(const Duration(days: 1));

    final events = (await _calendar(GetCalendarEventsParams(
      startDateTime: start,
      endDateTime: start.add(scheduleLookahead),
      accountId: accountId,
    )))
        .getOrElse((_) => const []);
    final todayEvents = [
      for (final e in events)
        if (e.start.toLocal().isBefore(tomorrow) && e.end.toLocal().isAfter(start))
          e,
    ]..sort((a, b) => a.start.compareTo(b.start));

    final taskDueDates = <DateTime>[];
    try {
      final rows = await _taskReminders.getScheduledTaskReminders(accountId);
      for (final r in rows) {
        taskDueDates.add(
          taskDueDay(DateTime.fromMillisecondsSinceEpoch(r.dueAtMs)),
        );
      }
    } catch (e) {
      debugPrint('CommitmentsCubit: task reminder rows unavailable: $e');
    }
    _lastTaskDueDates = taskDueDates;
    final tasksDue = taskDueDates.where((d) => d == start).length;

    var forecast = forecaster(
      commitments: commitments,
      events: events,
      taskDueDates: taskDueDates,
      now: now,
      previousEvents: _lastEvents,
    );
    _lastEvents = events;
    forecast = _withStickyFreed(forecast, now);

    return (events: todayEvents, tasksDue: tasksDue, forecast: forecast);
  }

  /// Keeps a slot labelled *freed* across refreshes until it is filled or its
  /// start has passed.
  WorkloadForecast _withStickyFreed(WorkloadForecast f, DateTime now) {
    _freedSlotStarts.removeWhere((s) => !s.isAfter(now));
    for (final s in f.openSlots) {
      if (s.freed) _freedSlotStarts.add(s.start);
    }
    if (_freedSlotStarts.isEmpty) return f;
    return WorkloadForecast(
      days: f.days,
      plans: f.plans,
      openSlots: [
        for (final s in f.openSlots)
          s.freed || !_freedSlotStarts.contains(s.start)
              ? s
              : OpenSlot(
                  start: s.start,
                  end: s.end,
                  suggestion: s.suggestion,
                  freed: true,
                ),
      ],
      computedAt: f.computedAt,
    );
  }
}
