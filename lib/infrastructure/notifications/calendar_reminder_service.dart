import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/reminder_schedule_local_datasource.dart';
import '../../domain/entities/calendar_event.dart';
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

  /// How far ahead alerts are actually handed to the OS.
  ///
  /// Deliberately much shorter than [_lookahead]: the fetch has to reach far
  /// enough to notice a meeting whose reminder is days long, but the *queue*
  /// must not. Every platform caps how many pending alerts one app may hold
  /// (Apple documents 64) and the countdown turns one meeting into up to five,
  /// so a fortnight of a working calendar asks for several hundred. The
  /// requests past the cap are discarded silently — `add` still reports success
  /// — and because a row lands in `scheduled_reminders` regardless, the
  /// [_notificationService.osRetainsSchedule] skip below then never revisits
  /// them: a dropped alert stays dropped for the life of the event. Measured on
  /// a real mailbox: 99 events, 321 alerts requested, ~100 held.
  ///
  /// A pass runs every 15 minutes, so the window rolls forward long before
  /// anything inside it fires. What it cannot cover is a machine that was
  /// asleep or shut down across the whole window — but nothing can, since the
  /// alert has to be queued while the app is running either way.
  static const _scheduleHorizon = Duration(hours: 36);

  /// The most alerts one pass will hand the OS, across every account.
  ///
  /// The horizon is the usual limit; this is the backstop for a calendar dense
  /// enough that a day and a half of it still overflows. Set below the 64 Apple
  /// documents, because the pool is per *app*: [TaskReminderService] queues into
  /// the same one, and a reminder that never arrives is worse than one queued a
  /// cycle later.
  static const _maxScheduledAlerts = 48;

  final AccountManager _accountManager;
  final NotificationService _notificationService;
  final ReminderScheduleLocalDatasource _database;

  Timer? _timer;
  Timer? _startupTimer;
  bool _reconciling = false;
  bool _rerunRequested = false;

  /// How long the first reconcile waits after startup.
  ///
  /// Reconciling fetches every account's calendar and parses the response on
  /// the UI isolate. Doing that the instant the home shell mounts put it in a
  /// dead heat with the first mail poll, the task reconciler and the contact
  /// cache sync — four multi-account network-and-parse jobs interleaving over
  /// the app's first seconds, which is exactly when the UI can least afford it.
  /// Nothing here is time-critical: the reminders being reconciled are for
  /// events at least a lead-time away, and a sub-window's change arrives as an
  /// explicit nudge rather than waiting for a cycle.
  static const _startupDelay = Duration(seconds: 20);

  /// Starts (or restarts) the periodic reconciliation timer. Safe to call
  /// repeatedly — any existing timer is cancelled first.
  void startPeriodic({Duration interval = const Duration(minutes: 15)}) {
    _timer?.cancel();
    _startupTimer?.cancel();
    _startupTimer = Timer(_startupDelay, () => unawaited(reconcileAll()));
    _timer = Timer.periodic(interval, (_) => reconcileAll());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _startupTimer?.cancel();
    _startupTimer = null;
  }

  /// Fetches upcoming events for every account and schedules/cancels
  /// reminders so they match.
  ///
  /// A request that arrives while a cycle is running does not run concurrently,
  /// but nor is it dropped: it books exactly one more pass once the current one
  /// finishes. A sub-window's nudge (see [ReminderReconcileChannel]) would
  /// otherwise be lost whenever it happened to land mid-cycle — which is the
  /// very delay it exists to avoid — and a cycle already past the account in
  /// question would never see the change. Capped at one extra pass so a stream
  /// of nudges cannot spin here indefinitely.
  Future<void> reconcileAll() async {
    if (_reconciling) {
      _rerunRequested = true;
      return;
    }
    _reconciling = true;
    try {
      var passes = 0;
      do {
        _rerunRequested = false;
        await _reconcileEveryAccount();
        passes++;
      } while (_rerunRequested && passes < 2);
    } finally {
      _reconciling = false;
      _rerunRequested = false;
    }
  }

  Future<void> _reconcileEveryAccount() async {
    final now = DateTime.now().toUtc();

    // Fetch every account first, then decide what to queue across all of them
    // at once. The budget below is per *app*, not per account, so it cannot be
    // spent one mailbox at a time — doing that would hand the first account
    // everything and leave the second with nothing however close its meetings
    // were.
    final fetched = <String, List<CalendarEvent>>{};
    for (final account in _accountManager.accounts) {
      try {
        fetched[account.id] = await _fetchEvents(account, now);
      } catch (e) {
        // Skip accounts that fail (auth error, network blip, calendar not
        // supported for this account type) — the next cycle retries. Their
        // persisted rows are deliberately left alone: a fetch that did not
        // happen is not evidence that a meeting was cancelled.
        debugPrint(
            'CalendarReminderService: fetch failed for account ${account.id}: $e');
      }
    }
    if (fetched.isEmpty) return;

    final wanted = _chooseWhatToSchedule(fetched, now);
    final pending = await _notificationService.pendingReminders();

    for (final entry in fetched.entries) {
      try {
        await _applyAccount(
          accountId: entry.key,
          wanted: wanted[entry.key] ?? const {},
          pending: pending,
          now: now,
        );
      } catch (e) {
        debugPrint(
            'CalendarReminderService: reconcile failed for account ${entry.key}: $e');
      }
    }

    await _clearOrphans(
      known: {for (final a in _accountManager.accounts) a.id},
      pending: pending,
    );
  }

  /// Cancels every alert, and deletes every row, keyed to an account this
  /// process does not have.
  ///
  /// The loop above only ever visits configured accounts, and
  /// [clearAccount] only runs for a removal this process saw — so an alert
  /// under any other account id is one nothing here will ever cancel or move,
  /// and it fires on whatever schedule it was given. Two things leave such
  /// alerts behind: another build of the app sharing this bundle id (a debug
  /// run adds the same mailboxes under fresh ids, since the Keychain is per
  /// code signature, and queues into the same OS notification pool), and an
  /// account removed while the app was not running. Observed as a meeting
  /// moved to tomorrow still announcing itself at today's time, from the
  /// debug build's copy of the series.
  ///
  /// Both sources are checked: the rows, which is what a shared database
  /// leaves, and the OS's own pending list, which is what a build with its
  /// own data directory leaves. Skipped while no account is configured — an
  /// empty account list is more likely a moment before they load than a user
  /// who removed every one, and [clearAccount] has the removal case anyway.
  Future<void> _clearOrphans({
    required Set<String> known,
    required PendingReminders? pending,
  }) async {
    if (known.isEmpty) return;
    try {
      final onDisk = await _database.getScheduledReminderAccountIds();
      for (final accountId in onDisk.difference(known)) {
        for (final r in await _database.getScheduledReminders(accountId)) {
          await _notificationService.cancelEventReminder(
              accountId: accountId, eventId: r.eventId);
        }
        await _database.clearScheduledRemindersForAccount(accountId);
      }
      for (final orphan in pending?.orphanedEvents(known) ?? const {}) {
        await _notificationService.cancelEventReminder(
            accountId: orphan.accountId, eventId: orphan.eventId);
      }
    } catch (e) {
      debugPrint('CalendarReminderService: orphan cleanup failed: $e');
    }
  }

  Future<List<CalendarEvent>> _fetchEvents(Account account, DateTime now) async {
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
    if (ds == null) return const [];

    return ds.getCalendarEvents(
      startDateTime: now,
      endDateTime: now.add(_lookahead),
    );
  }

  /// Picks the events whose alerts this pass will actually queue, account id →
  /// event id → event.
  ///
  /// Soonest first, across every account, until either the horizon or the alert
  /// budget runs out. Chronological order is what makes the budget defensible:
  /// when it binds, what is dropped is the furthest away, which is also what the
  /// next pass has the most time to pick up.
  Map<String, Map<String, CalendarEvent>> _chooseWhatToSchedule(
    Map<String, List<CalendarEvent>> fetched,
    DateTime now,
  ) {
    final horizon = now.add(_scheduleHorizon);
    final candidates = <({String accountId, CalendarEvent event, DateTime triggerAt})>[];
    for (final entry in fetched.entries) {
      for (final e in entry.value) {
        final reminderMinutes = e.reminderMinutes;
        if (reminderMinutes == null) continue;
        final triggerAt = e.start.subtract(Duration(minutes: reminderMinutes));
        if (triggerAt.isAfter(horizon)) continue;
        candidates.add((accountId: entry.key, event: e, triggerAt: triggerAt));
      }
    }
    candidates.sort((a, b) => a.triggerAt.compareTo(b.triggerAt));

    final chosen = <String, Map<String, CalendarEvent>>{};
    var alerts = 0;
    for (final c in candidates) {
      final count = NotificationService.alertCountFor(
        startUtc: c.event.start,
        reminderMinutes: c.event.reminderMinutes!,
        now: now,
      );
      // Stop rather than skip: taking a later, cheaper event once a nearer one
      // has been refused would put the queue out of chronological order for no
      // gain, and the pass is over either way.
      if (alerts + count > _maxScheduledAlerts) break;
      alerts += count;
      (chosen[c.accountId] ??= {})[c.event.id] = c.event;
    }
    return chosen;
  }

  Future<void> _applyAccount({
    required String accountId,
    required Map<String, CalendarEvent> wanted,
    required PendingReminders? pending,
    required DateTime now,
  }) async {
    final persisted = await _database.getScheduledReminders(accountId);
    final persistedByEventId = {for (final r in persisted) r.eventId: r};

    for (final e in wanted.values) {
      final reminderMinutes = e.reminderMinutes!;
      final triggerAtMs = e.start
          .subtract(Duration(minutes: reminderMinutes))
          .millisecondsSinceEpoch;
      final existing = persistedByEventId[e.id];
      final unchanged = existing != null &&
          existing.triggerAtMs == triggerAtMs &&
          existing.reminderMinutes == reminderMinutes &&
          existing.eventStartMs == e.start.millisecondsSinceEpoch &&
          // Skipping an unchanged event assumes the alerts it was scheduled
          // with are still queued somewhere. Where nothing outlives the process
          // (Linux, whose reminders are in-process timers) that assumption is
          // wrong after a restart and the row would silence the event for good,
          // so re-arm it every pass instead. Rescheduling is idempotent: the
          // cancel below clears the old timers and offsets already gone by are
          // skipped, so a meeting mid-countdown picks it up where it is.
          _notificationService.osRetainsSchedule &&
          // Where the OS can be asked, ask it rather than assuming. A row here
          // records what was *requested*; a request past the platform's pending
          // cap is discarded silently, and a schedule can also be cleared behind
          // the app's back. Either way the row alone would skip the event
          // forever. A null answer is "nothing learned" — fall back to the row.
          (pending?.holdsSeries(
                accountId: accountId,
                eventId: e.id,
                startUtc: e.start,
                reminderMinutes: reminderMinutes,
                now: now,
              ) ??
              true);
      if (unchanged) continue;

      // Drop the alerts already sitting with the OS before queuing the new
      // ones. Scheduling over the top is not a replacement: on Windows
      // `zonedSchedule` calls `AddToSchedule`, which appends a second scheduled
      // toast rather than superseding the one carrying the same id, so a
      // meeting postponed to tomorrow still fired at its original time.
      //
      // Unconditional, on two counts. A start moved to inside its lead time
      // leaves earlier offsets unschedulable, and the stale alerts for the
      // original time still have to go. And an event with no row here is not
      // proof the OS holds nothing for it — a build that scheduled a single
      // alert per event, or a cache cleared behind our back, both leave alerts
      // pending that only a cancel by id can reach. Cancelling ids the OS never
      // had is a no-op.
      await _notificationService.cancelEventReminder(
          accountId: accountId, eventId: e.id);

      await _notificationService.scheduleEventReminder(
        accountId: accountId,
        eventId: e.id,
        eventTitle: e.subject,
        startUtc: e.start,
        reminderMinutes: reminderMinutes,
        startIso: e.start.toIso8601String(),
      );
      await _database.upsertScheduledReminder(
        accountId: accountId,
        eventId: e.id,
        triggerAtMs: triggerAtMs,
        reminderMinutes: reminderMinutes,
        eventStartMs: e.start.millisecondsSinceEpoch,
      );
    }

    // Cancel reminders for anything this pass is not holding alerts for:
    // events cancelled or declined server-side, ones whose reminder was
    // removed, and ones that have fallen back outside the scheduling horizon
    // or off the end of the budget.
    //
    // Deleting the row is the point, not the cancel. A row is a claim that the
    // OS is holding this series, and the `unchanged` test above believes it —
    // so leaving one behind for an event nothing was queued for is exactly how
    // a meeting comes to be skipped silently on every pass once it does come
    // back into range.
    for (final r in persisted) {
      if (wanted.containsKey(r.eventId)) continue;
      await _notificationService.cancelEventReminder(
          accountId: accountId, eventId: r.eventId);
      await _database.deleteScheduledReminder(accountId, r.eventId);
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
