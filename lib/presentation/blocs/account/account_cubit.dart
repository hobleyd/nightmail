import 'dart:async';
import 'dart:io' show Platform;

import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../../../domain/repositories/email_repository.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import '../../../infrastructure/notifications/calendar_reminder_service.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

sealed class AccountState extends Equatable {
  const AccountState();
}

final class AccountLoading extends AccountState {
  const AccountLoading();
  @override
  List<Object?> get props => [];
}

final class AccountNoAccounts extends AccountState {
  const AccountNoAccounts();
  @override
  List<Object?> get props => [];
}

final class AccountsLoaded extends AccountState {
  const AccountsLoaded({
    required this.accounts,
    required this.activeIndex,
    this.unauthenticatedAccountIds = const {},
  });

  final List<Account> accounts;
  final int activeIndex;
  final Set<String> unauthenticatedAccountIds;

  Account get activeAccount => accounts[activeIndex];

  bool get activeAccountNeedsReauth =>
      unauthenticatedAccountIds.contains(accounts[activeIndex].id);

  @override
  List<Object?> get props => [
        accounts,
        activeIndex,
        (List.from(unauthenticatedAccountIds)..sort()),
      ];
}

final class AccountError extends AccountState {
  const AccountError({required this.message});

  final String message;

  @override
  List<Object?> get props => [message];
}

// ---------------------------------------------------------------------------
// Cubit
// ---------------------------------------------------------------------------

class AccountCubit extends Cubit<AccountState> {
  AccountCubit({
    required this._accountManager,
    required this._emailRepository,
    required this._calendarReminderService,
  }) : super(const AccountLoading()) {
    _authFailureSub = _accountManager.authFailures.listen(_onAuthFailure);
    _authSuccessSub = _accountManager.authSuccesses.listen(_onAuthSuccess);
  }

  final AccountManager _accountManager;
  final EmailRepository _emailRepository;
  final CalendarReminderService _calendarReminderService;
  late final StreamSubscription<String> _authFailureSub;
  late final StreamSubscription<String> _authSuccessSub;

  // Cached future for the in-progress initialize so that a retry re-attaches
  // to the same operation rather than starting a second concurrent one.  Kept
  // alive across timeouts; cleared on success or non-timeout failure.
  Future<void>? _inFlight;

  // Counts automatic retries triggered by iOS errSecInteractionNotAllowed
  // (-25308). Reset to 0 on success or after exhausting retries.
  int _keychainRetries = 0;

  // Reacts to AuthInterceptor reporting a failed token refresh for
  // [accountId] (e.g. revoked/expired refresh token, missing admin consent)
  // so the reauth banner appears immediately, regardless of which code path
  // triggered the failing request.
  void _onAuthFailure(String accountId) {
    final current = state;
    if (current is! AccountsLoaded ||
        current.unauthenticatedAccountIds.contains(accountId)) {
      return;
    }
    emit(AccountsLoaded(
      accounts: current.accounts,
      activeIndex: current.activeIndex,
      unauthenticatedAccountIds: {
        ...current.unauthenticatedAccountIds,
        accountId,
      },
    ));
  }

  // Reacts to AuthInterceptor obtaining a usable token for [accountId]. Clears
  // any stale reauth flag so the banner self-heals: a transient failure (e.g. a
  // lost refresh-token rotation race) can flag an account whose credentials are
  // in fact still valid, and without this the flag would persist until the next
  // explicit account action even though every request now succeeds.
  void _onAuthSuccess(String accountId) {
    final current = state;
    if (current is! AccountsLoaded ||
        !current.unauthenticatedAccountIds.contains(accountId)) {
      return;
    }
    emit(AccountsLoaded(
      accounts: current.accounts,
      activeIndex: current.activeIndex,
      unauthenticatedAccountIds: {...current.unauthenticatedAccountIds}
        ..remove(accountId),
    ));
  }

  @override
  Future<void> close() {
    unawaited(_authFailureSub.cancel());
    unawaited(_authSuccessSub.cancel());
    return super.close();
  }

  Future<void> _emitLoaded() async {
    final unauthIds = await _accountManager.getUnauthenticatedAccountIds();
    emit(AccountsLoaded(
      accounts: _accountManager.accounts,
      activeIndex: _accountManager.activeIndex,
      unauthenticatedAccountIds: unauthIds,
    ));
  }

  Future<void> initialize() async {
    emit(const AccountLoading());
    _inFlight ??= _doInitialize();
    try {
      await _inFlight!.timeout(const Duration(seconds: 10));
      _inFlight = null;
      _keychainRetries = 0;
    } on TimeoutException {
      _keychainRetries = 0;
      emit(const AccountError(message: 'Unable to load accounts. Please retry.'));
    } catch (e) {
      _inFlight = null;
      // iOS errSecInteractionNotAllowed (-25308): keychain temporarily
      // inaccessible during the brief background execution phase of a
      // notification-tap cold launch. Wait for protected data to become
      // available, then retry (up to 2 times) before showing an error.
      if (_isKeychainInteractionError(e) && _keychainRetries < 2) {
        _keychainRetries++;
        await _waitForProtectedData();
        return initialize();
      }
      _keychainRetries = 0;
      emit(AccountError(message: e.toString()));
    }
  }

  static bool _isKeychainInteractionError(Object e) =>
      !kIsWeb &&
      Platform.isIOS &&
      e is PlatformException &&
      e.details == -25308;

  // Waits until iOS protected data is available (i.e. the device has been
  // unlocked). If already available, returns immediately. Times out after 3 s
  // so a retry always occurs even when the stream never fires.
  static Future<void> _waitForProtectedData() async {
    try {
      const storage = FlutterSecureStorage();
      final available = await storage.isCupertinoProtectedDataAvailable();
      if (available != false) return;
      await storage.onCupertinoProtectedDataAvailabilityChanged
          ?.where((v) => v)
          .first
          .timeout(const Duration(seconds: 3));
    } catch (_) {}
  }

  Future<void> _doInitialize() async {
    await _accountManager.initialize();
    if (_accountManager.hasAccounts) {
      await _emitLoaded();
      // Best-effort email backfill for legacy-migrated Microsoft accounts that
      // were recorded without an email address.  Runs after the loaded state is
      // emitted so a slow/failing network request does not block startup.
      unawaited(
        _accountManager.ensureEmailPopulated().then((_) async {
          try {
            if (!isClosed) await _emitLoaded();
          } catch (_) {}
        }).catchError((_) {}),
      );
    } else {
      emit(const AccountNoAccounts());
    }
  }

  Future<void> addAccount(Account account) async {
    await _accountManager.addAccount(account);
    await _emitLoaded();
  }

  Future<void> updateAccount(Account account) async {
    await _accountManager.updateAccount(account);
    await _emitLoaded();
  }

  /// Cycle to the next account and return it.
  Future<Account> cycleAccount() async {
    final next = await _accountManager.cycleToNextAccount();
    await _emitLoaded();
    return next;
  }

  Future<void> switchToAccount(int index) async {
    await _accountManager.switchToAccount(index);
    await _emitLoaded();
  }

  Future<void> removeAccount(String accountId) async {
    await _accountManager.removeAccount(accountId);
    await _emailRepository.clearCacheForAccount(accountId);
    await _calendarReminderService.clearAccount(accountId);
    if (_accountManager.hasAccounts) {
      await _emitLoaded();
    } else {
      emit(const AccountNoAccounts());
    }
  }

  /// Sign out of the active account, clearing credentials but keeping the
  /// account configured. The account will show a re-authentication prompt.
  Future<void> signOutActiveAccount() async {
    final account = _accountManager.activeAccount;
    if (account == null) return;
    await _accountManager.signOutAccount(account.id);
    await _emitLoaded();
  }

  /// Re-authenticate the active Microsoft or Gmail account via OAuth.
  Future<void> reauthenticateActiveOAuth() async {
    await _accountManager.reauthenticateActiveOAuth();
    await _emitLoaded();
  }

  /// Re-authenticate the active IMAP account with the supplied password.
  Future<void> reauthenticateActiveImap(String password) async {
    final account = _accountManager.activeAccount;
    if (account == null) return;
    await _accountManager.reauthenticateImapAccount(account.id, password);
    await _emitLoaded();
  }
}
