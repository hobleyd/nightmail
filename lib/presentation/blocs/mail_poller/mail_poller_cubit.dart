import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/settings/app_settings.dart';
import '../../../data/datasources/local/delta_token_datasource.dart';
import '../../../data/datasources/local/email_local_datasource.dart';
import '../../../data/datasources/remote/graph_delta_datasource.dart';
import '../../../domain/entities/email.dart';
import '../../../domain/usecases/get_cached_folders.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import '../../../infrastructure/badge/badge_service.dart';
import '../../../infrastructure/notifications/notification_service.dart';
import 'mail_poller_state.dart';

class MailPollerCubit extends Cubit<MailPollerState> with WidgetsBindingObserver {
  MailPollerCubit({
    required AccountManager accountManager,
    required AppSettings appSettings,
    required BadgeService badgeService,
    required DeltaTokenDatasource database,
    required EmailLocalDatasource emailLocalDatasource,
    required GetCachedFolders getCachedFolders,
    required NotificationService notificationService,
  })  : _accountManager = accountManager,
        _appSettings = appSettings,
        _badgeService = badgeService,
        _database = database,
        _emailLocalDatasource = emailLocalDatasource,
        _getCachedFolders = getCachedFolders,
        _notificationService = notificationService,
        super(const MailPollerState(
          accountsWithNewMail: {},
          pollIntervalSeconds: AppSettings.defaultPollIntervalSeconds,
        ));

  final AccountManager _accountManager;
  final AppSettings _appSettings;
  final BadgeService _badgeService;
  final DeltaTokenDatasource _database;
  final EmailLocalDatasource _emailLocalDatasource;
  final GetCachedFolders _getCachedFolders;
  final NotificationService _notificationService;

  Timer? _timer;
  bool _polling = false;
  bool _initialized = false;
  final Map<String, int> _baselineUnread = {};
  final Map<String, int> _baselineTotal = {};
  final Map<String, int> _latestPolledUnread = {};
  final Set<String> _newMailAccounts = {};
  final Set<String> _bootstrapping = {};
  final Set<String> _reauthAccounts = {};

  static const _systemEventsChannel =
      MethodChannel('au.com.sharpblue.nightmail/system_events');

  Future<void> initialize() async {
    // Remove before add to guard against multiple initialize() calls (e.g.
    // BlocProvider.value rebuilds) registering duplicate observers.
    WidgetsBinding.instance.removeObserver(this);
    WidgetsBinding.instance.addObserver(this);
    if (!kIsWeb && Platform.isMacOS) {
      _systemEventsChannel.setMethodCallHandler((call) async {
        if (call.method == 'systemDidWake') _poll();
      });
    }
    final interval = await _appSettings.loadPollIntervalSeconds();
    if (!isClosed) emit(state.copyWith(pollIntervalSeconds: interval));
    await _primeBadgeFromCache();
    _startTimer(interval);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _poll();
  }

  Future<void> _primeBadgeFromCache() async {
    int total = 0;
    for (final account in _accountManager.accounts) {
      final result = await _getCachedFolders(account.id);
      result.fold((_) {}, (folders) {
        final inbox = folders.where(
          (f) => f.displayName.toLowerCase() == 'inbox',
        );
        if (inbox.isNotEmpty) {
          final count = inbox.first.unreadItemCount;
          _latestPolledUnread[account.id] = count;
          _baselineUnread[account.id] = count;
          total += count;
        }
      });
    }
    if (total > 0) await _badgeService.setBadgeCount(total);
  }

  void _startTimer(int seconds) {
    _timer?.cancel();
    _timer = null;
    if (seconds <= 0) return;
    _poll();
    _timer = Timer.periodic(Duration(seconds: seconds), (_) => _poll());
  }

  Future<void> _poll() async {
    if (_polling || isClosed) return;
    _polling = true;
    // Captured so we can notify only for accounts that newly gained unread
    // mail *this cycle* — not ones already flagged from a previous poll, and
    // not the very first poll, which just establishes the baseline from
    // whatever unread mail already existed before NightMail was opened.
    final wasInitialized = _initialized;
    final previousNewMailAccounts = Set<String>.of(_newMailAccounts);

    try {
      final accounts = _accountManager.accounts;
      if (accounts.isEmpty) return;

      final activeId = _accountManager.activeAccount?.id;
      bool changed = false;
      bool activeInboxChanged = false;

      for (final account in accounts) {
        try {
          // Optimistically assume this round will succeed; the AuthException
          // handler below re-flags the account if it doesn't.
          if (_reauthAccounts.remove(account.id)) changed = true;
          final ds = _accountManager.buildEmailDatasourceForAccount(account);

          if (account is MicrosoftAccount && ds is GraphDeltaDatasource) {
            final deltaDs = ds as GraphDeltaDatasource;
            final savedToken =
                await _database.loadDeltaToken(account.id, 'inbox');

            if (savedToken == null) {
              // No token yet: use folder polling for unread count and kick off
              // an async bootstrap to fetch the initial delta token.
              final folders = await ds.getMailFolders();
              final inboxes = folders
                  .where((f) => f.displayName.toLowerCase() == 'inbox');
              if (inboxes.isEmpty) continue;
              final unreadCount = inboxes.first.unreadItemCount;
              final totalCount = inboxes.first.totalItemCount;
              _latestPolledUnread[account.id] = unreadCount;

              if (!_initialized || !_baselineUnread.containsKey(account.id)) {
                _baselineUnread[account.id] = unreadCount;
                _baselineTotal[account.id] = totalCount;
                if (account.id != activeId && unreadCount > 0) {
                  if (_newMailAccounts.add(account.id)) changed = true;
                }
              } else {
                if (account.id == activeId) {
                  final prevUnread = _baselineUnread[account.id];
                  final prevTotal = _baselineTotal[account.id];
                  // Mirror Gmail/IMAP: any change (increase or decrease) must
                  // refresh the UI. A decrease means mail was deleted or read
                  // on another client and would otherwise never self-heal.
                  if ((prevUnread != null && unreadCount != prevUnread) ||
                      (prevTotal != null && totalCount != prevTotal)) {
                    activeInboxChanged = true;
                  }
                  _baselineUnread[account.id] = unreadCount;
                  _baselineTotal[account.id] = totalCount;
                  if (_newMailAccounts.remove(account.id)) changed = true;
                } else if (unreadCount > 0) {
                  if (_newMailAccounts.add(account.id)) changed = true;
                } else {
                  if (_newMailAccounts.remove(account.id)) changed = true;
                }
              }

              unawaited(_bootstrapDeltaToken(account.id, deltaDs));
            } else {
              // Incremental delta sync — only fetch changes since last call.
              final result = await deltaDs.syncMailDelta('inbox',
                  deltaLink: savedToken);
              await _database.saveDeltaToken(
                  account.id, 'inbox', result.deltaLink);

              if (result.hasChanges) {
                // Mirror the delta straight into the cache so the message
                // list can repaint from disk without waiting on a second,
                // separate network round-trip. Awaited: pollGeneration bumps
                // right after this loop and the list repaints from cache, so
                // the write must land first.
                await _cacheUpserted(account.id, result.upserted);
                for (final removedId in result.removedIds) {
                  unawaited(_emailLocalDatasource.deleteEmailFromCache(
                    accountId: account.id,
                    emailId: removedId,
                  ));
                }

                // Refresh unread count only when something actually changed.
                final folders = await ds.getMailFolders();
                final inboxes = folders
                    .where((f) => f.displayName.toLowerCase() == 'inbox');
                if (inboxes.isEmpty) continue;
                final unreadCount = inboxes.first.unreadItemCount;
                _latestPolledUnread[account.id] = unreadCount;

                final hasNewUnread = result.upserted.any((e) => !e.isRead);

                if (account.id == activeId) {
                  _baselineUnread[account.id] = unreadCount;
                  if (_newMailAccounts.remove(account.id)) changed = true;
                  activeInboxChanged = true;
                } else if (hasNewUnread) {
                  if (_newMailAccounts.add(account.id)) changed = true;
                  // Send one notification per new unread email (capped at 5).
                  final newEmails =
                      result.upserted.where((e) => !e.isRead).take(5);
                  for (final email in newEmails) {
                    unawaited(_notificationService.showEmailNotification(
                      emailId: email.id,
                      accountId: account.id,
                      subject: email.subject,
                      senderName: email.from.displayName,
                      accountLabel: account.displayName,
                    ));
                  }
                } else if (unreadCount == 0) {
                  if (_newMailAccounts.remove(account.id)) changed = true;
                }
              } else if (!_latestPolledUnread.containsKey(account.id)) {
                // No changes and no cached count yet (first poll after startup).
                // Fetch folders once to prime the badge count.
                final folders = await ds.getMailFolders();
                final inboxes = folders
                    .where((f) => f.displayName.toLowerCase() == 'inbox');
                if (inboxes.isEmpty) continue;
                final unreadCount = inboxes.first.unreadItemCount;
                _latestPolledUnread[account.id] = unreadCount;
                _baselineUnread[account.id] = unreadCount;
              }
              // No changes and count already known → badge count is unchanged.
            }
          } else {
            // Non-delta path: Gmail / IMAP — existing unread-count polling.
            final folders = await ds.getMailFolders();
            final inboxes =
                folders.where((f) => f.displayName.toLowerCase() == 'inbox');
            if (inboxes.isEmpty) continue;
            final unreadCount = inboxes.first.unreadItemCount;
            _latestPolledUnread[account.id] = unreadCount;

            final totalCount = inboxes.first.totalItemCount;

            if (!_initialized || !_baselineUnread.containsKey(account.id)) {
              _baselineUnread[account.id] = unreadCount;
              _baselineTotal[account.id] = totalCount;
              if (account.id != activeId && unreadCount > 0) {
                if (_newMailAccounts.add(account.id)) changed = true;
              }
              continue;
            }

            if (account.id == activeId) {
              final prevUnread = _baselineUnread[account.id];
              final prevTotal = _baselineTotal[account.id];
              // Any change — not just an increase — must refresh the UI: a
              // decrease can come from reading/deleting mail on another
              // client, or from an in-app action whose optimistic local
              // update was missed, and would otherwise never self-heal.
              if ((prevUnread != null && unreadCount != prevUnread) ||
                  (prevTotal != null && totalCount != prevTotal)) {
                activeInboxChanged = true;
                // Gmail/IMAP have no delta feed, so unlike the Graph branch
                // above there's no upserted-message list — fetch the inbox
                // page directly and cache it (awaited: pollGeneration bumps
                // right after this loop and the list repaints from cache,
                // so the write must land first) instead of showing stale
                // data until a manual refresh.
                final freshEmails =
                    await ds.getEmails(folderId: inboxes.first.id, top: 25);
                await _emailLocalDatasource.cacheEmails(
                  accountId: account.id,
                  folderId: inboxes.first.id,
                  emails: freshEmails,
                );
              }
              _baselineUnread[account.id] = unreadCount;
              _baselineTotal[account.id] = totalCount;
              if (_newMailAccounts.remove(account.id)) changed = true;
            } else if (unreadCount > 0) {
              if (_newMailAccounts.add(account.id)) changed = true;
            } else {
              if (_newMailAccounts.remove(account.id)) changed = true;
            }
          }
        } on ServerException catch (e) {
          if (e.statusCode == 410) {
            // Delta token expired (tokens are valid for 7 days). Clear it so
            // the next poll bootstraps a fresh one.
            await _database.clearDeltaTokensForAccount(account.id);
          }
        } on AuthException catch (_) {
          // Refresh token rejected/revoked — surface this account as needing
          // re-authentication instead of silently freezing its counts forever.
          if (_reauthAccounts.add(account.id)) changed = true;
        } catch (_) {
          // Silently skip accounts that fail to poll for other reasons
          // (network blips, etc.) — the next poll cycle will retry.
        }
      }

      _initialized = true;
      final totalUnread =
          _latestPolledUnread.values.fold(0, (sum, n) => sum + n);
      await _badgeService.setBadgeCount(totalUnread);
      if ((changed || activeInboxChanged) && !isClosed) {
        emit(state.copyWith(
          accountsWithNewMail: Set.of(_newMailAccounts),
          pollGeneration: activeInboxChanged
              ? state.pollGeneration + 1
              : state.pollGeneration,
          accountsNeedingReauth: Set.of(_reauthAccounts),
        ));
      }
    } finally {
      _polling = false;
    }

    // Windows/Linux have no OS-level badge/dock affordance for background
    // accounts the way macOS (dock badge) and mobile (background isolate +
    // WorkManager notification) do, so the foreground poller raises a toast
    // itself here. Excludes MicrosoftAccount: once it has a delta token, the
    // per-account loop above already calls showEmailNotification with actual
    // message detail for it — this aggregate fallback would double-notify.
    if (wasInitialized && (Platform.isWindows || Platform.isLinux)) {
      final newlyFlagged = _newMailAccounts.difference(previousNewMailAccounts);
      for (final accountId in newlyFlagged) {
        Account? account;
        for (final a in _accountManager.accounts) {
          if (a.id == accountId) {
            account = a;
            break;
          }
        }
        if (account == null || account is MicrosoftAccount) continue;
        unawaited(_notifyNewMail(account));
      }
    }
  }

  /// Gmail/IMAP have no delta sync, so unlike the Graph path above this has
  /// no upserted-message list to read a real subject/sender from — only an
  /// aggregate unread count. Fetches the inbox's most recent unread message
  /// for real notification content, falling back to the generic aggregate
  /// alert if that fails (no inbox, empty result, network error, etc.).
  Future<void> _notifyNewMail(Account account) async {
    final newCount = _latestPolledUnread[account.id] ?? 0;
    try {
      final ds = _accountManager.buildEmailDatasourceForAccount(account);
      final folders = await ds.getMailFolders();
      final inbox = folders
          .where((f) => f.displayName.toLowerCase() == 'inbox')
          .firstOrNull;
      if (inbox == null) throw StateError('no inbox folder');
      final emails = await ds.getEmails(folderId: inbox.id, top: 10);
      unawaited(_emailLocalDatasource.cacheEmails(
        accountId: account.id,
        folderId: inbox.id,
        emails: emails,
      ));
      final latestUnread = emails.where((e) => !e.isRead).firstOrNull;
      if (latestUnread == null) throw StateError('no unread message found');
      final senderName = newCount > 1
          ? '${latestUnread.from.displayName} and ${newCount - 1} more'
          : latestUnread.from.displayName;
      await _notificationService.showEmailNotification(
        emailId: latestUnread.id,
        accountId: account.id,
        subject: latestUnread.subject,
        senderName: senderName,
        accountLabel: account.displayName,
      );
    } catch (_) {
      await _notificationService.showNewMailNotification(
        accountLabel: account.emailAddress,
        newCount: newCount,
      );
    }
  }

  /// Performs the initial full delta sync for [accountId] to establish a delta
  /// token. Runs in the background so it does not block the poll cycle.
  Future<void> _bootstrapDeltaToken(
    String accountId,
    GraphDeltaDatasource ds,
  ) async {
    if (_bootstrapping.contains(accountId)) return;
    _bootstrapping.add(accountId);
    try {
      final result = await ds.syncMailDelta('inbox');
      await _database.saveDeltaToken(accountId, 'inbox', result.deltaLink);
      // The bootstrap fetch already pulled the last 30 days of messages to
      // establish the delta token — cache them now instead of discarding,
      // so a fresh account is usable offline without a separate fetch.
      await _cacheUpserted(accountId, result.upserted);
      // The fresh delta snapshot reflects the inbox at this moment. The email
      // list cache may be stale (e.g. emails deleted before/during bootstrap),
      // so force a UI refresh now that we have a reliable baseline.
      if (!isClosed && accountId == _accountManager.activeAccount?.id) {
        emit(state.copyWith(pollGeneration: state.pollGeneration + 1));
      }
    } catch (_) {
      // Bootstrap failed; next poll cycle will retry when savedToken is null.
    } finally {
      _bootstrapping.remove(accountId);
    }
  }

  /// Groups [upserted] by their real server folder id (Graph messages carry
  /// `parentFolderId`) and writes each group into the cache. Delta syncs are
  /// scoped to a single well-known folder name (e.g. 'inbox'), which is not
  /// the same string as that folder's actual id used elsewhere for cache
  /// lookups/UI navigation — grouping by parentFolderId keeps cache keys
  /// consistent with what the email list reads.
  Future<void> _cacheUpserted(String accountId, List<Email> upserted) async {
    if (upserted.isEmpty) return;
    final byFolder = <String, List<Email>>{};
    for (final email in upserted) {
      final folderId = email.parentFolderId ?? 'inbox';
      byFolder.putIfAbsent(folderId, () => []).add(email);
    }
    for (final entry in byFolder.entries) {
      await _emailLocalDatasource.cacheEmails(
        accountId: accountId,
        folderId: entry.key,
        emails: entry.value,
      );
    }
  }

  void decrementUnreadCount() {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    final current = _latestPolledUnread[accountId] ?? 0;
    if (current > 0) _latestPolledUnread[accountId] = current - 1;
    final total = _latestPolledUnread.values.fold(0, (sum, n) => sum + n);
    unawaited(_badgeService.setBadgeCount(total));
  }

  void incrementUnreadCount() {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    final current = _latestPolledUnread[accountId] ?? 0;
    _latestPolledUnread[accountId] = current + 1;
    final total = _latestPolledUnread.values.fold(0, (sum, n) => sum + n);
    unawaited(_badgeService.setBadgeCount(total));
  }

  void updateBadgeFromFolders(int inboxUnreadCount) {
    final accountId = _accountManager.activeAccount?.id;
    if (accountId == null) return;
    _latestPolledUnread[accountId] = inboxUnreadCount;
    final total = _latestPolledUnread.values.fold(0, (sum, n) => sum + n);
    unawaited(_badgeService.setBadgeCount(total));
  }

  void markAccountViewed(String accountId) {
    _newMailAccounts.remove(accountId);
    _baselineUnread[accountId] = _latestPolledUnread[accountId] ?? 0;
    if (!isClosed) {
      emit(state.copyWith(accountsWithNewMail: Set.of(_newMailAccounts)));
    }
  }

  Future<void> updatePollInterval(int seconds) async {
    await _appSettings.savePollIntervalSeconds(seconds);
    if (!isClosed) emit(state.copyWith(pollIntervalSeconds: seconds));
    _startTimer(seconds);
  }

  @override
  Future<void> close() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    return super.close();
  }
}
