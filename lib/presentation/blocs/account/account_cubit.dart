import 'dart:async';

import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

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
  }

  final AccountManager _accountManager;
  final EmailRepository _emailRepository;
  final CalendarReminderService _calendarReminderService;
  late final StreamSubscription<String> _authFailureSub;

  // Cached future for the in-progress initialize so that a retry re-attaches
  // to the same operation rather than starting a second concurrent one.  Kept
  // alive across timeouts; cleared on success or non-timeout failure.
  Future<void>? _inFlight;

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

  @override
  Future<void> close() {
    unawaited(_authFailureSub.cancel());
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
    } on TimeoutException {
      emit(const AccountError(message: 'Unable to load accounts. Please retry.'));
    } catch (e) {
      _inFlight = null;
      emit(AccountError(message: e.toString()));
    }
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
