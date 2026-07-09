import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/reminder_schedule_local_datasource.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';
import 'notification_service.dart';

/// Reconciles every configured account's upcoming calendar events against
/// what NightMail has scheduled with the OS notification system, so a
/// reminder fires for a meeting regardless of whether the user ever opened
/// the calendar pane for it.
///
/// This intentionally bypasses [CalendarRepository]/`GetCalendarEvents`
/// (which are hard-wired to the single *active* account) and instead loops
/// every account via [AccountManager.buildCalendarDatasourceForAccount],
/// mirroring how `MailPollerCubit` already polls all accounts for mail.
class CalendarReminderService {
  CalendarReminderService({
    required AccountManager accountManager,
    required NotificationService notificationService,
    required ReminderScheduleLocalDatasource database,
  })  : _accountManager = accountManager,
        _notificationService = notificationService,
        _database = database;

  static const _lookahead = Duration(days: 14);

  final AccountManager _accountManager;
  final NotificationService _notificationService;
  final ReminderScheduleLocalDatasource _database;

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

  /// Fetches upcoming events for every account and schedules/cancels
  /// reminders so they match. Skips a cycle if one is already running.
  Future<void> reconcileAll() async {
    if (_reconciling) return;
    _reconciling = true;
    try {
      for (final account in _accountManager.accounts) {
        debugPrint(
            'CalendarReminderService: reconciling account ${account.id} (${account.runtimeType}) ${account.emailAddress}');
        try {
          await _reconcileAccount(account);
          debugPrint(
              'CalendarReminderService: reconcile OK for account ${account.id}');
        } catch (e) {
          // Skip accounts that fail (auth error, network blip, calendar not
          // supported for this account type) — the next cycle retries.
          debugPrint(
              'CalendarReminderService: reconcile failed for account ${account.id}: $e');
        }
      }
    } finally {
      _reconciling = false;
    }
  }

  Future<void> _reconcileAccount(Account account) async {
    // For the currently-active account, reuse AccountManager's shared
    // datasource instead of building a fresh one. buildCalendarDatasourceForAccount
    // constructs its own independent auth/token pipeline (separate
    // MicrosoftAuthService/GmailAuthService reading/writing the same
    // secure-storage token key) — running that concurrently with the active
    // pipeline races on token refresh and can invalidate the token the
    // calendar pane is actively using if the provider rotates refresh
    // tokens on use.
    final ds = account.id == _accountManager.activeAccount?.id
        ? _accountManager.calendarDatasource
        : _accountManager.buildCalendarDatasourceForAccount(account);
    if (ds == null) {
      debugPrint(
          'CalendarReminderService: no calendar datasource for account ${account.id}, skipping');
      return;
    }

    final now = DateTime.now().toUtc();
    final events = await ds.getCalendarEvents(
      startDateTime: now,
      endDateTime: now.add(_lookahead),
    );

    final persisted = await _database.getScheduledReminders(account.id);
    final persistedByEventId = {for (final r in persisted) r.eventId: r};

    final liveEventIds = <String>{};
    for (final e in events) {
      liveEventIds.add(e.id);
      final reminderMinutes = e.reminderMinutes;

      if (reminderMinutes == null) {
        // Event exists but has no reminder now (removed elsewhere) — cancel
        // any reminder we previously scheduled for it.
        if (persistedByEventId.containsKey(e.id)) {
          await _notificationService.cancelEventReminder(
              accountId: account.id, eventId: e.id);
          await _database.deleteScheduledReminder(account.id, e.id);
        }
        continue;
      }

      final triggerAtMs = e.start
          .subtract(Duration(minutes: reminderMinutes))
          .millisecondsSinceEpoch;
      final existing = persistedByEventId[e.id];
      final unchanged = existing != null &&
          existing.triggerAtMs == triggerAtMs &&
          existing.reminderMinutes == reminderMinutes &&
          existing.eventStartMs == e.start.millisecondsSinceEpoch;
      if (unchanged) continue;

      await _notificationService.scheduleEventReminder(
        accountId: account.id,
        eventId: e.id,
        eventTitle: e.subject,
        startUtc: e.start,
        reminderMinutes: reminderMinutes,
        startIso: e.start.toIso8601String(),
      );
      await _database.upsertScheduledReminder(
        accountId: account.id,
        eventId: e.id,
        triggerAtMs: triggerAtMs,
        reminderMinutes: reminderMinutes,
        eventStartMs: e.start.millisecondsSinceEpoch,
      );
    }

    // Cancel reminders for events that dropped out of the lookahead window
    // entirely (cancelled/declined server-side, or otherwise no longer
    // returned by the fetch).
    for (final r in persisted) {
      if (!liveEventIds.contains(r.eventId)) {
        await _notificationService.cancelEventReminder(
            accountId: account.id, eventId: r.eventId);
        await _database.deleteScheduledReminder(account.id, r.eventId);
      }
    }
  }

  /// Cancels every pending reminder for [accountId] and clears its persisted
  /// state. Called when an account is removed so stale OS-level
  /// notifications don't fire later with no account behind them.
  Future<void> clearAccount(String accountId) async {
    final rows = await _database.getScheduledReminders(accountId);
    for (final r in rows) {
      await _notificationService.cancelEventReminder(
          accountId: accountId, eventId: r.eventId);
    }
    await _database.clearScheduledRemindersForAccount(accountId);
  }
}
