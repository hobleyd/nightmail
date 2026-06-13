import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/exceptions.dart';
import '../../../core/settings/app_settings.dart';
import '../../../data/datasources/local/delta_token_datasource.dart';
import '../../../data/datasources/remote/graph_delta_datasource.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import '../../../infrastructure/badge/badge_service.dart';
import 'mail_poller_state.dart';

class MailPollerCubit extends Cubit<MailPollerState> {
  MailPollerCubit({
    required AccountManager accountManager,
    required AppSettings appSettings,
    required BadgeService badgeService,
    required DeltaTokenDatasource database,
  })  : _accountManager = accountManager,
        _appSettings = appSettings,
        _badgeService = badgeService,
        _database = database,
        super(const MailPollerState(
          accountsWithNewMail: {},
          pollIntervalSeconds: AppSettings.defaultPollIntervalSeconds,
        ));

  final AccountManager _accountManager;
  final AppSettings _appSettings;
  final BadgeService _badgeService;
  final DeltaTokenDatasource _database;

  Timer? _timer;
  bool _polling = false;
  bool _initialized = false;
  final Map<String, int> _baselineUnread = {};
  final Map<String, int> _latestPolledUnread = {};
  final Set<String> _newMailAccounts = {};
  final Set<String> _bootstrapping = {};

  Future<void> initialize() async {
    final interval = await _appSettings.loadPollIntervalSeconds();
    if (!isClosed) emit(state.copyWith(pollIntervalSeconds: interval));
    _startTimer(interval);
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

    try {
      final accounts = _accountManager.accounts;
      if (accounts.isEmpty) return;

      final activeId = _accountManager.activeAccount?.id;
      bool changed = false;
      bool activeInboxChanged = false;

      for (final account in accounts) {
        try {
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
              _latestPolledUnread[account.id] = unreadCount;

              if (!_initialized || !_baselineUnread.containsKey(account.id)) {
                _baselineUnread[account.id] = unreadCount;
                if (account.id != activeId && unreadCount > 0) {
                  if (_newMailAccounts.add(account.id)) changed = true;
                }
              } else {
                if (account.id == activeId) {
                  _baselineUnread[account.id] = unreadCount;
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
                } else if (unreadCount == 0) {
                  if (_newMailAccounts.remove(account.id)) changed = true;
                }
              }
              // No changes → skip getMailFolders(); badge count is unchanged.
            }
          } else {
            // Non-delta path: Gmail / IMAP — existing unread-count polling.
            final folders = await ds.getMailFolders();
            final inboxes =
                folders.where((f) => f.displayName.toLowerCase() == 'inbox');
            if (inboxes.isEmpty) continue;
            final unreadCount = inboxes.first.unreadItemCount;
            _latestPolledUnread[account.id] = unreadCount;

            if (!_initialized || !_baselineUnread.containsKey(account.id)) {
              _baselineUnread[account.id] = unreadCount;
              if (account.id != activeId && unreadCount > 0) {
                if (_newMailAccounts.add(account.id)) changed = true;
              }
              continue;
            }

            if (account.id == activeId) {
              _baselineUnread[account.id] = unreadCount;
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
        } catch (_) {
          // Silently skip accounts that fail to poll.
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
        ));
      }
    } finally {
      _polling = false;
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
    } catch (_) {
      // Bootstrap failed; next poll cycle will retry when savedToken is null.
    } finally {
      _bootstrapping.remove(accountId);
    }
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
    _timer?.cancel();
    return super.close();
  }
}
