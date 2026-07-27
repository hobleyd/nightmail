import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/task_reminder_schedule_local_datasource.dart';
import '../../domain/entities/todo_task.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';
import 'notification_service.dart';

/// Raises a notification when a to-do item falls due, on the same footing as
/// new mail and calendar reminders.
///
/// Mirrors [CalendarReminderService]: it reconciles every configured account's
/// open tasks against what NightMail has scheduled with the OS, so a task
/// announces itself whether or not the user has the tasks pane open — and
/// bypasses `TasksRepository`/`GetTasks` (hard-wired to the single *active*
/// account) by looping every account via
/// [AccountManager.buildTasksDatasourceForAccount].
///
/// Unlike a calendar event, a task's due moment does not pass: an overdue task
/// is still due. So a trigger that has already elapsed with nothing delivered
/// (the app was closed, or a Linux in-process timer died with the process)
/// fires on the next reconcile rather than being skipped. The persisted
/// `notifiedAtMs` is what stops that catch-up from repeating every cycle.
class TaskReminderService {
  TaskReminderService({
    required AccountManager accountManager,
    required NotificationService notificationService,
    required TaskReminderScheduleLocalDatasource database,
  })  : _accountManager = accountManager,
        _notificationService = notificationService,
        _database = database;

  /// How far ahead to hand triggers to the OS. Anything further out is picked
  /// up by a later reconcile, which keeps the pending-notification list short.
  static const _lookahead = Duration(days: 14);

  /// How far *back* a missed trigger is still worth announcing. Without this,
  /// the first reconcile after installing (or after a long absence) would
  /// treat every stale overdue task as freshly missed and alert on all of
  /// them; anything older than this is recorded as announced without a sound,
  /// since the tasks pane already shows it in red.
  static const _catchUpWindow = Duration(days: 3);

  /// Above this many catch-ups in one account's pass, they collapse into a
  /// single "N tasks are due" alert instead of one banner each.
  static const _maxIndividualCatchUps = 3;

  /// Local time of day used for date-only due dates (Microsoft To Do and
  /// Google Tasks both store "due" as a calendar day). Midnight would fire a
  /// reminder while the user is asleep, and — worse — one that arrives before
  /// the working day it refers to has started.
  static const _dateOnlyDueHour = 9;

  final AccountManager _accountManager;
  final NotificationService _notificationService;
  final TaskReminderScheduleLocalDatasource _database;

  Timer? _timer;
  bool _reconciling = false;

  /// Starts (or restarts) the periodic reconciliation timer. Safe to call
  /// repeatedly — any existing timer is cancelled first.
  void startPeriodic({Duration interval = const Duration(minutes: 15)}) {
    _timer?.cancel();
    unawaited(reconcileAll());
    _timer = Timer.periodic(interval, (_) => reconcileAll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// Fetches open tasks for every account and schedules/fires/cancels due
  /// notifications so they match. Skips a cycle if one is already running.
  Future<void> reconcileAll() async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      for (final account in _accountManager.accounts) {
        try {
          await _reconcileAccount(account);
        } catch (e) {
          // Skip accounts that fail (auth error, network blip, no tasks
          // provider for this account type) — the next cycle retries.
          debugPrint(
              'TaskReminderService: reconcile failed for account ${account.id}: $e');
        }
      }
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _reconcileAccount(Account account) async {
    // For the active account reuse AccountManager's shared datasource rather
    // than building a fresh one — see the same note in
    // CalendarReminderService: a second auth pipeline for one account races
    // on refresh-token rotation with the one the UI is using.
    final ds = account.id == _accountManager.activeAccount?.id
        ? _accountManager.tasksDatasource
        : _accountManager.buildTasksDatasourceForAccount(account);
    if (ds == null) return;

    final persisted = await _database.getScheduledTaskReminders(account.id);
    final persistedByTaskId = {for (final r in persisted) r.taskId: r};

    final lists = await ds.getTaskLists();
    final seenTaskIds = <String>{};
    final catchUps = <TodoTask>[];
    var suppressed = 0;

    for (final list in lists) {
      // getTasks(includeCompleted: false) already drops finished items, so a
      // completed task simply stops appearing and is cancelled by the sweep
      // at the end of this method.
      final tasks = await ds.getTasks(list.id);
      for (final task in tasks) {
        final trigger = triggerFor(task);
        if (trigger == null) continue;

        final now = DateTime.now();
        if (trigger.isAfter(now.add(_lookahead))) continue;

        seenTaskIds.add(task.id);
        switch (await _syncTask(
          accountId: account.id,
          task: task,
          trigger: trigger,
          existing: persistedByTaskId[task.id],
          now: now,
        )) {
          case _SyncOutcome.announce:
            catchUps.add(task);
          case _SyncOutcome.tooStaleToAnnounce:
            suppressed++;
          case _SyncOutcome.nothingToDo:
            break;
        }
      }
    }

    // Tasks that dropped out entirely — completed, deleted, or their due date
    // removed (triggerFor returned null, so they were never marked seen).
    for (final r in persisted) {
      if (!seenTaskIds.contains(r.taskId)) {
        await _notificationService.cancelTaskReminder(
            accountId: account.id, taskId: r.taskId);
        await _database.deleteScheduledTaskReminder(account.id, r.taskId);
      }
    }

    if (suppressed > 0) {
      debugPrint('TaskReminderService: ${account.id} — $suppressed task(s) '
          'overdue by more than ${_catchUpWindow.inDays} days recorded '
          'without an alert');
    }
    await _announce(account, catchUps);
  }

  /// Brings one task's OS-level alert and persisted row in line with its
  /// current due moment, and reports whether it still needs announcing now.
  ///
  /// Rows are stamped as notified here rather than by the caller, so a crash
  /// between this and [_announce] can at worst lose one alert instead of
  /// repeating it on every subsequent cycle.
  Future<_SyncOutcome> _syncTask({
    required String accountId,
    required TodoTask task,
    required DateTime trigger,
    required ScheduledTaskReminderRecord? existing,
    required DateTime now,
  }) async {
    final triggerAtMs = trigger.millisecondsSinceEpoch;
    final dueAtMs = (task.dueDateTime ?? task.reminderDateTime ?? trigger)
        .millisecondsSinceEpoch;
    final rescheduled = existing != null && existing.triggerAtMs != triggerAtMs;

    if (existing != null && !rescheduled) {
      // Same due moment as last pass. Nothing to do unless it has since
      // elapsed with no notification actually delivered.
      if (existing.notifiedAtMs != null) return _SyncOutcome.nothingToDo;
      if (trigger.isAfter(now)) return _SyncOutcome.nothingToDo;
      if (existing.osScheduled && _notificationService.osRetainsSchedule) {
        // The OS delivered it while we weren't looking; just close the record
        // so this branch isn't re-evaluated every cycle.
        await _database.markTaskReminderNotified(
          accountId: accountId,
          taskId: task.id,
          notifiedAtMs: triggerAtMs,
        );
        return _SyncOutcome.nothingToDo;
      }
      await _database.markTaskReminderNotified(
        accountId: accountId,
        taskId: task.id,
        notifiedAtMs: now.millisecondsSinceEpoch,
      );
      return _withinCatchUpWindow(trigger, now)
          ? _SyncOutcome.announce
          : _SyncOutcome.tooStaleToAnnounce;
    }

    // New task, or one whose due date moved. Replace any pending alert.
    if (rescheduled) {
      await _notificationService.cancelTaskReminder(
          accountId: accountId, taskId: task.id);
    }

    if (trigger.isAfter(now)) {
      await _notificationService.scheduleTaskReminder(
        accountId: accountId,
        listId: task.listId,
        taskId: task.id,
        title: task.title,
        body: _body(task, _accountLabel(accountId), trigger),
        triggerUtc: trigger.toUtc(),
      );
      await _database.upsertScheduledTaskReminder(
        accountId: accountId,
        listId: task.listId,
        taskId: task.id,
        triggerAtMs: triggerAtMs,
        dueAtMs: dueAtMs,
        osScheduled: _notificationService.osRetainsSchedule,
      );
      return _SyncOutcome.nothingToDo;
    }

    // Already due when first seen (or when its due date was moved into the
    // past) — announce it now rather than never.
    await _database.upsertScheduledTaskReminder(
      accountId: accountId,
      listId: task.listId,
      taskId: task.id,
      triggerAtMs: triggerAtMs,
      dueAtMs: dueAtMs,
      osScheduled: false,
      notifiedAtMs: now.millisecondsSinceEpoch,
    );
    return _withinCatchUpWindow(trigger, now)
        ? _SyncOutcome.announce
        : _SyncOutcome.tooStaleToAnnounce;
  }

  static bool _withinCatchUpWindow(DateTime trigger, DateTime now) =>
      now.difference(trigger) <= _catchUpWindow;

  /// Raises the alerts for tasks that were already due when this pass found
  /// them — individually while there are only a few, and as a single summary
  /// beyond that, so a backlog can't turn into a wall of banners.
  Future<void> _announce(Account account, List<TodoTask> tasks) async {
    if (tasks.isEmpty) return;

    if (tasks.length > _maxIndividualCatchUps) {
      await _notificationService.showTasksDueSummaryNotification(
        accountId: account.id,
        count: tasks.length,
        accountLabel: account.displayName,
      );
      return;
    }

    final now = DateTime.now();
    for (final task in tasks) {
      await _notificationService.showTaskDueNotification(
        accountId: account.id,
        listId: task.listId,
        taskId: task.id,
        title: task.title,
        body: _body(task, account.displayName, now),
      );
    }
  }

  /// The local moment a task should announce itself, or null if it never
  /// should (completed, or no due date and no reminder set).
  ///
  /// An explicit reminder wins over the due date: the user asked to be told at
  /// that time specifically.
  @visibleForTesting
  static DateTime? triggerFor(TodoTask task) {
    if (task.isCompleted) return null;

    final reminder = task.reminderDateTime;
    if (task.isReminderOn && reminder != null) return reminder;

    final due = task.dueDateTime;
    if (due == null) return null;

    // Both providers store a due *date*, which arrives here as midnight UTC
    // converted to local — so read the intended calendar day off the UTC side
    // (in UTC-behind timezones the local side has already slipped to the
    // previous day) and fire at a civil hour on that day.
    final utc = due.toUtc();
    final isDateOnly = utc.hour == 0 &&
        utc.minute == 0 &&
        utc.second == 0 &&
        utc.millisecond == 0;
    if (!isDateOnly) return due;
    return DateTime(utc.year, utc.month, utc.day, _dateOnlyDueHour);
  }

  String _accountLabel(String accountId) =>
      _accountManager.accounts
          .where((a) => a.id == accountId)
          .firstOrNull
          ?.displayName ??
      '';

  String _body(TodoTask task, String accountLabel, DateTime now) {
    final due = task.dueDateTime;
    if (due != null) {
      final today = DateTime(now.year, now.month, now.day);
      final dueDay = DateTime(due.year, due.month, due.day);
      final days = today.difference(dueDay).inDays;
      if (days > 0) {
        final label = days == 1 ? 'yesterday' : '$days days ago';
        return 'Overdue — was due $label · $accountLabel';
      }
    }
    return 'Task due · $accountLabel';
  }

  /// Fast-path removal for the app's own completions and due-date edits on the
  /// active account — the periodic reconcile is the safety net that also
  /// catches changes made from other clients, but it runs on a ~15min cadence,
  /// which would otherwise let a just-ticked-off task's alert fire before the
  /// next cycle notices. Dropping the row also lets that cycle re-schedule a
  /// moved due date from scratch.
  Future<void> dismissTask(String taskId) async {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    await _notificationService.cancelTaskReminder(
        accountId: accountId, taskId: taskId);
    await _database.deleteScheduledTaskReminder(accountId, taskId);
  }

  /// Cancels every pending task reminder for [accountId] and clears its
  /// persisted state. Called when an account is removed so stale OS-level
  /// notifications don't fire later with no account behind them.
  Future<void> clearAccount(String accountId) async {
    final rows = await _database.getScheduledTaskReminders(accountId);
    for (final r in rows) {
      await _notificationService.cancelTaskReminder(
          accountId: accountId, taskId: r.taskId);
    }
    await _database.clearScheduledTaskRemindersForAccount(accountId);
  }
}

enum _SyncOutcome {
  /// Due now and recent enough to be worth a banner.
  announce,

  /// Due, but so long ago that alerting would be noise — recorded silently.
  tooStaleToAnnounce,

  /// Scheduled for later, unchanged, or already announced.
  nothingToDo,
}
