import 'package:equatable/equatable.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../domain/repositories/email_repository.dart';
import '../../../infrastructure/accounts/account.dart';
import '../../../infrastructure/accounts/account_manager.dart';

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
  });

  final List<Account> accounts;
  final int activeIndex;

  Account get activeAccount => accounts[activeIndex];

  @override
  List<Object?> get props => [accounts, activeIndex];
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
  }) : super(const AccountLoading());

  final AccountManager _accountManager;
  final EmailRepository _emailRepository;

  Future<void> initialize() async {
    await _accountManager.initialize();
    if (_accountManager.hasAccounts) {
      emit(AccountsLoaded(
        accounts: _accountManager.accounts,
        activeIndex: _accountManager.activeIndex,
      ));
    } else {
      emit(const AccountNoAccounts());
    }
  }

  Future<void> addAccount(Account account) async {
    await _accountManager.addAccount(account);
    emit(AccountsLoaded(
      accounts: _accountManager.accounts,
      activeIndex: _accountManager.activeIndex,
    ));
  }

  Future<void> updateAccount(Account account) async {
    await _accountManager.updateAccount(account);
    emit(AccountsLoaded(
      accounts: _accountManager.accounts,
      activeIndex: _accountManager.activeIndex,
    ));
  }

  /// Cycle to the next account and return it.
  Future<Account> cycleAccount() async {
    final next = await _accountManager.cycleToNextAccount();
    emit(AccountsLoaded(
      accounts: _accountManager.accounts,
      activeIndex: _accountManager.activeIndex,
    ));
    return next;
  }

  Future<void> switchToAccount(int index) async {
    await _accountManager.switchToAccount(index);
    emit(AccountsLoaded(
      accounts: _accountManager.accounts,
      activeIndex: _accountManager.activeIndex,
    ));
  }

  Future<void> removeAccount(String accountId) async {
    await _accountManager.removeAccount(accountId);
    await _emailRepository.clearCacheForAccount(accountId);
    if (_accountManager.hasAccounts) {
      emit(AccountsLoaded(
        accounts: _accountManager.accounts,
        activeIndex: _accountManager.activeIndex,
      ));
    } else {
      emit(const AccountNoAccounts());
    }
  }

  /// Sign out of the active account and remove it.
  Future<void> signOutActiveAccount() async {
    final account = _accountManager.activeAccount;
    if (account == null) return;
    try {
      await _accountManager.activeAuthService.signOut();
    } catch (_) {}
    await removeAccount(account.id);
  }
}
