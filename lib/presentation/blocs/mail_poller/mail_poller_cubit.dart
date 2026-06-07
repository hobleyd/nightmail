import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/settings/app_settings.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'mail_poller_state.dart';

class MailPollerCubit extends Cubit<MailPollerState> {
  MailPollerCubit({
    required AccountManager accountManager,
    required AppSettings appSettings,
  })  : _accountManager = accountManager,
        _appSettings = appSettings,
        super(const MailPollerState(
          accountsWithNewMail: {},
          pollIntervalSeconds: AppSettings.defaultPollIntervalSeconds,
        ));

  final AccountManager _accountManager;
  final AppSettings _appSettings;

  Timer? _timer;
  bool _polling = false;
  bool _initialized = false;
  final Map<String, int> _baselineUnread = {};
  final Map<String, int> _latestPolledUnread = {};
  final Set<String> _newMailAccounts = {};

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

      for (final account in accounts) {
        try {
          final ds = _accountManager.buildEmailDatasourceForAccount(account);
          final folders = await ds.getMailFolders();
          final inboxMatches =
              folders.where((f) => f.displayName.toLowerCase() == 'inbox');
          if (inboxMatches.isEmpty) continue;
          final unreadCount = inboxMatches.first.unreadItemCount;

          _latestPolledUnread[account.id] = unreadCount;

          if (!_initialized || !_baselineUnread.containsKey(account.id)) {
            _baselineUnread[account.id] = unreadCount;
            continue;
          }

          if (account.id == activeId) {
            _baselineUnread[account.id] = unreadCount;
            if (_newMailAccounts.remove(account.id)) changed = true;
          } else if (unreadCount > (_baselineUnread[account.id] ?? 0)) {
            if (_newMailAccounts.add(account.id)) changed = true;
          }
        } catch (_) {
          // Silently skip accounts that fail to poll.
        }
      }

      _initialized = true;
      if (changed && !isClosed) {
        emit(state.copyWith(accountsWithNewMail: Set.of(_newMailAccounts)));
      }
    } finally {
      _polling = false;
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
