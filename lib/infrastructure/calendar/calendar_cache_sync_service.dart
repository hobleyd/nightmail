import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../data/datasources/local/calendar_local_datasource.dart';
import '../../data/datasources/local/pending_calendar_operations_datasource.dart';
import '../accounts/account.dart';
import '../accounts/account_manager.dart';
import '../sync/calendar_outbox_drain_service.dart';

/// Keeps the local calendar cache stocked so the calendar paints from disk
/// instead of from a spinner.
///
/// The window it maintains is **today through four weeks ahead**, for every
/// configured account, and it drops anything that finished more than a
/// **fortnight** ago. Those two bounds are deliberately asymmetric: the future
/// is what the calendar is opened to look at, while the recent past only needs
/// to be there for the weeks a user scrolls back through, and letting it
/// accumulate would grow the cache without bound.
///
/// Runs in the **main window only**. Sub-windows get their own engine, isolate
/// and service locator, so a calendar sub-window running this too would have
/// every account fetched twice on a timer for no benefit — the sub-window reads
/// the same SQLite file the main window fills. What a sub-window *does* do is
/// refresh the week it is showing through the repository, which writes that week
/// back to the cache on the way past.
///
/// Like [ContactCacheSyncService], this loops every account via
/// [AccountManager.buildCalendarDatasourceForAccount] rather than going through
/// `CalendarRepository`, which is hard-wired to the active account.
class CalendarCacheSyncService {
  CalendarCacheSyncService({
    required AccountManager accountManager,
    required CalendarLocalDatasource cache,
    required PendingCalendarOperationsDatasource pendingOperations,
    required CalendarOutboxDrainService outboxDrainService,
  })  : _accountManager = accountManager,
        _cache = cache,
        _pendingOperations = pendingOperations,
        _outboxDrainService = outboxDrainService;

  final AccountManager _accountManager;
  final CalendarLocalDatasource _cache;
  final PendingCalendarOperationsDatasource _pendingOperations;
  final CalendarOutboxDrainService _outboxDrainService;

  /// How far ahead of today the cache is kept warm.
  static const lookahead = Duration(days: 28);

  /// How far back a finished meeting is kept before it is expired.
  static const retention = Duration(days: 14);

  /// How often a long-running session refreshes the window. Desktop sessions
  /// stay open for days, so a startup-only sync would go stale — and this also
  /// rolls the window forward as the days pass.
  static const _tickInterval = Duration(minutes: 15);

  /// How long the first sync waits after start-up.
  ///
  /// Nothing here is urgent: whatever is already cached is on screen, and the
  /// calendar's own fetch covers the week actually being looked at. Delaying
  /// keeps this out of the scrum of first-seconds work (the first mail poll, the
  /// reminder reconcilers, the contact cache sync) that the UI can least afford.
  static const _startupDelay = Duration(seconds: 10);

  Timer? _timer;
  Timer? _startupTimer;

  /// One entry per in-flight account sync, so overlapping triggers (start-up,
  /// the timer, an account being added) collapse into a single fetch.
  final Map<String, Future<void>> _inFlight = {};

  /// Starts (or restarts) the periodic sync. Safe to call repeatedly — any
  /// existing timers are cancelled first.
  void startPeriodic({Duration interval = _tickInterval}) {
    stop();
    _startupTimer = Timer(_startupDelay, () => unawaited(syncAll()));
    _timer = Timer.periodic(interval, (_) => unawaited(syncAll()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _startupTimer?.cancel();
    _startupTimer = null;
  }

  /// Refreshes the cached window for every account and expires what has aged
  /// out. Never throws: an account that fails is logged and the rest continue.
  Future<void> syncAll() async {
    final accounts = _accountManager.accounts;

    // Push queued mutations before re-reading the calendars, so a fetch cannot
    // overwrite an optimistic change with the server state that predates it.
    // A mutation queued *after* this point survives anyway — the fetch writes
    // the window, then the drain applies to the server, then the next pass
    // agrees with both.
    try {
      await _outboxDrainService.drainAll();
    } catch (e) {
      debugPrint('CalendarCacheSyncService: outbox drain failed: $e');
    }

    await Future.wait([for (final a in accounts) syncAccount(a.id)]);
    await _pruneRemovedAccounts(accounts);
  }

  /// Refreshes one account's window. Safe to call concurrently with itself —
  /// the second caller awaits the first rather than starting a second fetch.
  Future<void> syncAccount(String accountId) {
    final existing = _inFlight[accountId];
    if (existing != null) return existing;

    final future = _syncAccountInner(accountId).whenComplete(() {
      _inFlight.remove(accountId);
    });
    _inFlight[accountId] = future;
    return future;
  }

  Future<void> _syncAccountInner(String accountId) async {
    Account? account;
    for (final a in _accountManager.accounts) {
      if (a.id == accountId) {
        account = a;
        break;
      }
    }
    if (account == null) return;

    // Expire first, and unconditionally: aged-out rows should go even if the
    // fetch below fails, and doing it first keeps the table small for the write.
    try {
      await _cache.pruneEventsEndingBefore(
        accountId: accountId,
        before: DateTime.now().toUtc().subtract(retention),
      );
    } catch (e) {
      debugPrint('CalendarCacheSyncService: prune failed for $accountId: $e');
    }

    // Reuse the active account's shared datasource rather than building a second
    // one: `buildCalendarDatasourceForAccount` stands up an independent auth
    // pipeline against the same stored token, and running that alongside the
    // active one races on refresh (see CalendarReminderService._reconcileAccount).
    final ds = account.id == _accountManager.activeAccount?.id
        ? _accountManager.calendarDatasource
        : _accountManager.buildCalendarDatasourceForAccount(account);
    // Null for account types with no calendar — nothing to sync, and the prune
    // above has already run.
    if (ds == null) return;

    final (windowStart, windowEnd) = currentWindow();

    try {
      final events = await ds.getCalendarEvents(
        startDateTime: windowStart,
        endDateTime: windowEnd,
      );
      await _cache.cacheEvents(
        accountId: accountId,
        windowStart: windowStart,
        windowEnd: windowEnd,
        events: events,
      );
    } catch (e) {
      // Auth error, network blip, calendar unavailable — leave the previous
      // cache in place rather than blanking the window, and try again next tick.
      debugPrint('CalendarCacheSyncService: sync failed for $accountId: $e');
    }
  }

  /// Forgets everything held for [accountId] — its cached meetings and any
  /// mutations still queued against it. Called when the account is removed,
  /// where replaying a queued RSVP would mean talking to a mailbox the user has
  /// just disconnected.
  Future<void> clearAccount(String accountId) async {
    _inFlight.remove(accountId);
    await _pendingOperations.clearCalendarOperationsForAccount(accountId);
    await _cache.clearEventsForAccount(accountId);
  }

  /// The window the cache is kept warm over: midnight *local* today through
  /// [lookahead] later.
  ///
  /// Local midnight, not "now", because "cache today" means the whole of today —
  /// a meeting that started an hour ago is still the one on screen. Returned as
  /// UTC instants, which is what the providers and the cache both take.
  static (DateTime, DateTime) currentWindow() {
    final now = DateTime.now();
    final localMidnight = DateTime(now.year, now.month, now.day);
    final start = localMidnight.toUtc();
    return (start, start.add(lookahead));
  }

  /// Drops cached events belonging to accounts that are no longer configured,
  /// so removing an account does not leave its meetings on disk.
  Future<void> _pruneRemovedAccounts(List<Account> accounts) async {
    try {
      final live = {for (final a in accounts) a.id};
      final cached = await _cache.cachedEventAccountIds();
      for (final id in cached) {
        if (!live.contains(id)) await _cache.clearEventsForAccount(id);
      }
    } catch (e) {
      debugPrint('CalendarCacheSyncService: prune of removed accounts: $e');
    }
  }
}
