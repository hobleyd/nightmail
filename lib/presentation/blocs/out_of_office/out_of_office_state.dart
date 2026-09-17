import 'package:equatable/equatable.dart';

import '../../../domain/entities/out_of_office_settings.dart';

enum OutOfOfficeStatus {
  /// Nothing selected yet, or the selected account is being fetched.
  loading,

  /// [OutOfOfficeState.draft] is editable and reflects the mailbox.
  ready,

  /// This provider has no automatic-reply setting (IMAP).
  unsupported,

  /// The fetch failed; [OutOfOfficeState.errorMessage] says how.
  error,
}

class OutOfOfficeState extends Equatable {
  const OutOfOfficeState({
    this.accountId,
    this.status = OutOfOfficeStatus.loading,
    this.saved,
    this.draft,
    this.needsPermission = false,
    this.saving = false,
    this.errorMessage,
    this.savedAt,
  });

  /// The mailbox being edited. The screen lists every signed-in account and
  /// defaults to the active one; out of office is a per-mailbox server
  /// setting, so "the one that happens to be selected in the mail list" is not
  /// a safe thing to leave implicit.
  final String? accountId;
  final OutOfOfficeStatus status;

  /// What the provider last told us it holds. [draft] is what is on screen.
  final OutOfOfficeSettings? saved;
  final OutOfOfficeSettings? draft;

  /// The account's token cannot write the setting yet, so saving has to run
  /// the provider's consent flow first. Reading needs nothing extra on either
  /// provider, which is why this never blocks the form from being shown.
  final bool needsPermission;

  final bool saving;
  final String? errorMessage;

  /// Stamped on a successful save so the screen can confirm it. A timestamp
  /// rather than a flag because two saves in a row are otherwise equal and
  /// Equatable would drop the second emit — the same trap as
  /// `EmailListActionFailure.sequence`.
  final DateTime? savedAt;

  bool get isDirty => draft != null && draft != saved;

  bool get canSave =>
      status == OutOfOfficeStatus.ready &&
      !saving &&
      draft != null &&
      // Turning it off needs no message; turning it on without one would
      // send blank replies to everybody who writes.
      (!draft!.enabled || !hasEmptyMessage) &&
      (!draft!.enabled || _datesValid);

  /// A message that is on but has nothing in it. Checks the external body too
  /// when one is in use — an empty *second* message is the same blank reply,
  /// just to a different audience, and it is the one the user cannot see while
  /// the editor is on the other tab.
  bool get hasEmptyMessage {
    final d = draft;
    if (d == null) return false;
    if (d.messageHtml.trim().isEmpty) return true;
    return d.useSeparateExternalMessage && d.externalMessageHtml.trim().isEmpty;
  }

  bool get _datesValid {
    final start = draft?.start;
    final end = draft?.end;
    if (start == null || end == null) return false;
    return !end.isBefore(start);
  }

  /// True when the window is the wrong way round — reported on the form rather
  /// than left to the provider, which answers a generic 400.
  bool get hasDateOrderError => draft != null && draft!.enabled && !_datesValid;

  OutOfOfficeState copyWith({
    String? accountId,
    OutOfOfficeStatus? status,
    OutOfOfficeSettings? saved,
    OutOfOfficeSettings? draft,
    bool? needsPermission,
    bool? saving,
    String? errorMessage,
    bool clearError = false,
    DateTime? savedAt,
  }) {
    return OutOfOfficeState(
      accountId: accountId ?? this.accountId,
      status: status ?? this.status,
      saved: saved ?? this.saved,
      draft: draft ?? this.draft,
      needsPermission: needsPermission ?? this.needsPermission,
      saving: saving ?? this.saving,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      savedAt: savedAt ?? this.savedAt,
    );
  }

  @override
  List<Object?> get props => [
    accountId,
    status,
    saved,
    draft,
    needsPermission,
    saving,
    errorMessage,
    savedAt,
  ];
}

/// Which of a mailbox's two reply bodies the message editor is showing.
///
/// Only Microsoft has two; everywhere else the editor is always on
/// [OutOfOfficeMessageSlot.internal], which is then simply "the message".
enum OutOfOfficeMessageSlot { internal, external }
