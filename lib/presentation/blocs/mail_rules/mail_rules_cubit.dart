import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:fpdart/fpdart.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/mail_rule.dart';
import '../../../domain/usecases/mail_rules/delete_mail_rule.dart';
import '../../../domain/usecases/mail_rules/get_mail_rule_folders.dart';
import '../../../domain/usecases/mail_rules/get_mail_rules.dart';
import '../../../domain/usecases/mail_rules/reorder_mail_rules.dart';
import '../../../domain/usecases/mail_rules/save_mail_rule.dart';
import '../../../domain/usecases/mail_rules/set_mail_rule_enabled.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'mail_rules_state.dart';

/// Drives the Rules settings screen for one account at a time.
///
/// Every change goes straight to the server and is followed by a quiet
/// re-read, rather than patched into the list locally: Graph renumbers and
/// normalises what it is given, and a Gmail edit comes back under a new id.
class MailRulesCubit extends Cubit<MailRulesState> {
  MailRulesCubit({
    required GetMailRules getMailRules,
    required GetMailRuleFolders getMailRuleFolders,
    required SaveMailRule saveMailRule,
    required DeleteMailRule deleteMailRule,
    required SetMailRuleEnabled setMailRuleEnabled,
    required ReorderMailRules reorderMailRules,
    required this._accountManager,
  }) : _get = getMailRules,
       _getFolders = getMailRuleFolders,
       _save = saveMailRule,
       _delete = deleteMailRule,
       _setEnabled = setMailRuleEnabled,
       _reorder = reorderMailRules,
       super(const MailRulesState());

  final GetMailRules _get;
  final GetMailRuleFolders _getFolders;
  final SaveMailRule _save;
  final DeleteMailRule _delete;
  final SetMailRuleEnabled _setEnabled;
  final ReorderMailRules _reorder;
  final AccountManager _accountManager;

  /// Loads [accountId], or the active account when none is given.
  ///
  /// [quiet] keeps the list on screen while the re-read runs — used after a
  /// change, where blanking the list would read as the change having lost it.
  Future<void> load([String? accountId, bool quiet = false]) async {
    final id =
        accountId ?? state.accountId ?? _accountManager.activeAccount?.id;
    if (id == null) {
      // `error`, not `unsupported`, for the reason OutOfOfficeCubit.load
      // gives: no account yet resolves on its own, and only the error branch
      // offers a way back.
      emit(
        const MailRulesState(
          status: MailRulesStatus.error,
          errorMessage: 'No account is signed in yet.',
        ),
      );
      return;
    }

    if (!quiet) {
      emit(MailRulesState(accountId: id, status: MailRulesStatus.loading));
    }

    // Writing rules needs the same scope as writing an automatic reply on
    // both providers — Graph's MailboxSettings.ReadWrite, Gmail's
    // gmail.settings.basic — so the Out of Office check and consent flow are
    // the right ones, not a near-copy of them.
    final canWrite = quiet
        ? !state.needsPermission
        : await _accountManager.hasOutOfOfficeWriteAccess(id);
    final (result, folders) = await (_get(id), _getFolders(id)).wait;
    if (isClosed || state.accountId != id) return;

    result.fold(
      (failure) {
        if (quiet) {
          emit(state.copyWith(busy: false, errorMessage: failure.message));
          return;
        }
        emit(
          MailRulesState(
            accountId: id,
            status: failure is UnsupportedFailure
                ? MailRulesStatus.unsupported
                : MailRulesStatus.error,
            errorMessage: failure.message,
          ),
        );
      },
      (set) => emit(
        MailRulesState(
          accountId: id,
          status: MailRulesStatus.ready,
          rules: set.rules,
          capabilities: set.capabilities,
          // A folder list that failed to load only costs the picker its
          // names; the rules themselves are still right.
          folders: folders.getOrElse((_) => const []),
          // Local (IMAP) rules are files on this device: nothing to grant.
          needsPermission: set.capabilities.runsOnServer && !canWrite,
          // A quiet re-read after a failed change must not wipe the reason.
          errorMessage: quiet ? state.errorMessage : null,
          savedAt: quiet ? state.savedAt : null,
        ),
      ),
    );
  }

  /// Runs the provider's consent flow for the write scope. A decline is an
  /// answer, not an error: nothing has changed, and the caller simply stops.
  Future<bool> requestPermission() async {
    final id = state.accountId;
    if (id == null) return false;
    try {
      final granted = await _accountManager.requestOutOfOfficeWriteAccess(id);
      if (isClosed) return granted;
      emit(state.copyWith(needsPermission: !granted, clearError: true));
      return granted;
    } catch (e) {
      if (!isClosed) emit(state.copyWith(errorMessage: e.toString()));
      return false;
    }
  }

  /// Creates [rule] when it has no id, otherwise replaces it. Returns whether
  /// it landed, so the editor knows whether to close.
  Future<bool> saveRule(MailRule rule) {
    // A new Graph rule runs after every existing one, which is where Outlook
    // puts it too. Gmail ignores the number.
    final toSave = rule.id != null
        ? rule
        : rule.copyWith(
            sequence:
                state.rules.fold<int>(0, (m, r) => r.sequence > m ? r.sequence : m) +
                1,
          );
    return _mutate((id) => _save(SaveMailRuleParams(accountId: id, rule: toSave)));
  }

  Future<bool> deleteRule(MailRule rule) => _mutate(
    (id) => _delete(DeleteMailRuleParams(accountId: id, ruleId: rule.id!)),
  );

  Future<bool> setEnabled(MailRule rule, bool enabled) {
    if (!_canMutate) return Future.value(false);
    // Shown at once: the switch snapping back while the request is out reads
    // as the tap not having registered. The re-read corrects it on failure.
    emit(
      state.copyWith(
        rules: [
          for (final r in state.rules)
            r.id == rule.id ? r.copyWith(enabled: enabled) : r,
        ],
      ),
    );
    return _mutate(
      (id) => _setEnabled(
        SetMailRuleEnabledParams(
          accountId: id,
          ruleId: rule.id!,
          enabled: enabled,
        ),
      ),
    );
  }

  /// Whether [rule] can trade places with its neighbour [delta] away (-1
  /// earlier, +1 later). A read-only neighbour cannot have its sequence
  /// changed, so it pins the rules either side of it.
  bool canMove(MailRule rule, int delta) {
    final from = state.rules.indexWhere((r) => r.id == rule.id);
    final to = from + delta;
    if (from < 0 || to < 0 || to >= state.rules.length) return false;
    return !rule.isReadOnly && !state.rules[to].isReadOnly;
  }

  /// Swaps [rule] with its neighbour [delta] away. Two PATCHes, touching
  /// only those two rules: renumbering the whole list would also PATCH every
  /// read-only rule, which Graph refuses.
  Future<bool> move(MailRule rule, int delta) {
    if (!_canMutate || !canMove(rule, delta)) return Future.value(false);
    final ordered = [...state.rules];
    final from = ordered.indexWhere((r) => r.id == rule.id);
    final to = from + delta;
    final other = ordered[to];
    // Outlook can leave two rules on the same number, and swapping equal
    // numbers changes nothing; then the moved rule steps one past.
    final sequences = rule.sequence != other.sequence
        ? {rule.id!: other.sequence, other.id!: rule.sequence}
        : {rule.id!: other.sequence + delta};
    ordered
      ..[to] = rule.copyWith(sequence: sequences[rule.id!])
      ..[from] = other.copyWith(sequence: sequences[other.id!] ?? other.sequence);
    emit(state.copyWith(rules: ordered));
    return _mutate(
      (id) => _reorder(ReorderMailRulesParams(accountId: id, sequences: sequences)),
    );
  }

  bool get _canMutate =>
      state.accountId != null &&
      !state.busy &&
      state.status == MailRulesStatus.ready;

  Future<bool> _mutate(
    Future<Either<Failure, Unit>> Function(String accountId) change,
  ) async {
    if (!_canMutate) return false;
    final id = state.accountId!;
    emit(state.copyWith(busy: true, clearError: true));
    final result = await change(id);
    if (isClosed || state.accountId != id) return false;
    final failure = result.getLeft().toNullable();
    if (failure != null) {
      emit(state.copyWith(busy: false, errorMessage: failure.message));
      // Put back whatever the optimistic switch or reorder showed.
      await load(id, true);
      return false;
    }
    await load(id, true);
    if (!isClosed && state.accountId == id) {
      emit(state.copyWith(busy: false, savedAt: DateTime.now()));
    }
    return true;
  }
}
