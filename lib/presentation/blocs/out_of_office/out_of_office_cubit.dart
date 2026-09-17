import 'package:flutter_bloc/flutter_bloc.dart';

import '../../../core/error/failures.dart';
import '../../../domain/entities/out_of_office_settings.dart';
import '../../../domain/usecases/get_out_of_office.dart';
import '../../../domain/usecases/set_out_of_office.dart';
import '../../../infrastructure/accounts/account_manager.dart';
import 'out_of_office_state.dart';

/// Drives the Out of Office settings screen for one account at a time.
class OutOfOfficeCubit extends Cubit<OutOfOfficeState> {
  OutOfOfficeCubit({
    required GetOutOfOffice getOutOfOffice,
    required SetOutOfOffice setOutOfOffice,
    required AccountManager accountManager,
  }) : _get = getOutOfOffice,
       _set = setOutOfOffice,
       _accountManager = accountManager,
       super(const OutOfOfficeState());

  final GetOutOfOffice _get;
  final SetOutOfOffice _set;
  final AccountManager _accountManager;

  /// How long a window a mailbox with nothing scheduled is offered. A week
  /// from today is the common case and is easier to shorten than to invent.
  static const _defaultWindowDays = 7;

  /// Loads [accountId], or the active account when none is given.
  ///
  /// [quiet] skips the loading state and keeps whatever is on screen while the
  /// fetch runs — used for the re-read after a save, where blanking the form
  /// the user is looking at would read as the save having lost it.
  Future<void> load([String? accountId, bool quiet = false]) async {
    final id =
        accountId ?? state.accountId ?? _accountManager.activeAccount?.id;
    if (id == null) {
      // `error`, not `unsupported`: no account being signed in *yet* is a
      // state that resolves on its own, and only the error branch offers a
      // way back. A terminal status here leaves the screen dead until
      // Settings is closed and reopened, with no account picker to escape
      // through — it is hidden below two accounts.
      emit(
        const OutOfOfficeState(
          status: OutOfOfficeStatus.error,
          errorMessage: 'No account is signed in yet.',
        ),
      );
      return;
    }

    final savedAt = quiet ? state.savedAt : null;
    if (!quiet) {
      emit(OutOfOfficeState(accountId: id, status: OutOfOfficeStatus.loading));
    }

    // Asked alongside the fetch rather than at save time so the screen can say
    // up front that the provider will need to ask — springing a browser on
    // somebody who has just pressed Save is the thing this avoids. A quiet
    // refresh follows a save that has just succeeded, so the answer is
    // already known and re-reading the token would only delay the
    // confirmation.
    final canWrite = quiet
        ? !state.needsPermission
        : await _accountManager.hasOutOfOfficeWriteAccess(id);
    final result = await _get(id);
    if (isClosed || state.accountId != id) return;

    result.fold(
      (failure) {
        // A quiet refresh that fails changes nothing: the save it follows
        // already succeeded, and replacing the form with an error would
        // report the wrong thing about it.
        if (quiet) return;
        emit(
          OutOfOfficeState(
            accountId: id,
            status: failure is UnsupportedFailure
                ? OutOfOfficeStatus.unsupported
                : OutOfOfficeStatus.error,
            errorMessage: failure.message,
          ),
        );
      },
      (settings) {
        emit(
          OutOfOfficeState(
            accountId: id,
            status: OutOfOfficeStatus.ready,
            saved: settings,
            draft: _withDefaultDates(settings),
            needsPermission: !canWrite,
            savedAt: savedAt,
          ),
        );
      },
    );
  }

  /// A mailbox with nothing scheduled comes back with no dates at all, and a
  /// form whose date buttons read "—" cannot be pressed into shape without
  /// two extra taps. Only the *draft* gets them, so [OutOfOfficeState.isDirty]
  /// still reads false until the user actually changes something.
  OutOfOfficeSettings _withDefaultDates(OutOfOfficeSettings settings) {
    if (settings.start != null && settings.end != null) return settings;
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final start = settings.start ?? today;
    return settings.copyWith(
      start: start,
      end:
          settings.end ??
          _endOfDay(start.add(const Duration(days: _defaultWindowDays))),
    );
  }

  void setEnabled(bool enabled) =>
      _editDraft((d) => d.copyWith(enabled: enabled));

  /// The window is picked as whole dates: the first day starts at midnight and
  /// the last day is *inclusive*, which is what "away until Friday" means and
  /// what Gmail's own UI does. Anchoring the bounds here rather than in each
  /// datasource means both providers are told the same instant.
  void setStartDate(DateTime date) => _editDraft((d) {
    final start = DateTime(date.year, date.month, date.day);
    final end = d.end;
    // Dragging the start past the end takes the end with it rather than
    // leaving the form in a state it refuses to save. `copyWith` reads a
    // null as "leave it alone" and cannot clear a bound, so the
    // no-adjustment case passes nothing rather than passing `end` back.
    if (end != null && end.isBefore(start)) {
      return d.copyWith(start: start, end: _endOfDay(start));
    }
    return d.copyWith(start: start);
  });

  void setEndDate(DateTime date) =>
      _editDraft((d) => d.copyWith(end: _endOfDay(date)));

  void setMessage(String html) =>
      _editDraft((d) => d.copyWith(messageHtml: html));

  void setExternalMessage(String html) =>
      _editDraft((d) => d.copyWith(externalMessageHtml: html));

  /// Writes [html] into whichever message the editor is currently showing.
  void setMessageFor(OutOfOfficeMessageSlot slot, String html) =>
      switch (slot) {
        OutOfOfficeMessageSlot.internal => setMessage(html),
        OutOfOfficeMessageSlot.external => setExternalMessage(html),
      };

  void setAudience(OutOfOfficeAudience audience) => _editDraft((d) {
    // A separate external message is meaningless once nobody outside the
    // organisation is answered, so narrowing the audience switches the
    // option off rather than leaving a control that claims to do
    // something. The text itself is kept: widening the audience again
    // brings it back.
    if (audience == OutOfOfficeAudience.organisationOnly) {
      return d.copyWith(audience: audience, useSeparateExternalMessage: false);
    }
    return d.copyWith(audience: audience);
  });

  void setUseSeparateExternalMessage(bool value) =>
      _editDraft((d) => d.copyWith(useSeparateExternalMessage: value));

  static DateTime _endOfDay(DateTime date) =>
      DateTime(date.year, date.month, date.day, 23, 59, 59);

  void _editDraft(OutOfOfficeSettings Function(OutOfOfficeSettings) edit) {
    final draft = state.draft;
    if (draft == null || state.status != OutOfOfficeStatus.ready) return;
    emit(state.copyWith(draft: edit(draft), clearError: true));
  }

  /// Runs the provider's consent flow for the write scope.
  ///
  /// Returns whether it came back granted. A decline is an answer, not an
  /// error — nothing has been changed, and the caller simply does not save.
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

  Future<void> save() async {
    final id = state.accountId;
    final draft = state.draft;
    if (id == null || draft == null || !state.canSave) return;

    emit(state.copyWith(saving: true, clearError: true));
    final result = await _set(
      SetOutOfOfficeParams(accountId: id, settings: draft),
    );
    if (isClosed || state.accountId != id) return;

    result.fold(
      (failure) =>
          emit(state.copyWith(saving: false, errorMessage: failure.message)),
      (_) {
        // Re-read rather than assuming the draft landed verbatim: both
        // providers normalise what they are given (Graph rewrites the bounds
        // into the mailbox's zone, Gmail may hold a reply subject this screen
        // never showed), and the advisory flags come back with it.
        emit(
          state.copyWith(saving: false, saved: draft, savedAt: DateTime.now()),
        );
        load(id, true);
      },
    );
  }
}
