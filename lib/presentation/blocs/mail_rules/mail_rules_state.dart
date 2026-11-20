import 'package:equatable/equatable.dart';

import '../../../domain/entities/email_folder.dart';
import '../../../domain/entities/mail_rule.dart';

enum MailRulesStatus {
  /// Nothing selected yet, or the selected account is being fetched.
  loading,

  /// [MailRulesState.rules] reflects the mailbox.
  ready,

  /// This provider has no server-side rules (IMAP), or the server has not
  /// implemented them yet (Nightware).
  unsupported,

  /// The fetch failed; [MailRulesState.errorMessage] says how.
  error,
}

class MailRulesState extends Equatable {
  const MailRulesState({
    this.accountId,
    this.status = MailRulesStatus.loading,
    this.rules = const [],
    this.capabilities,
    this.folders = const [],
    this.needsPermission = false,
    this.busy = false,
    this.errorMessage,
    this.savedAt,
  });

  /// The mailbox whose rules are shown. Picked on the screen, defaulting to
  /// the active account — rules are per mailbox, and editing whichever one
  /// happens to be selected in the mail list is not safe to leave implicit.
  final String? accountId;
  final MailRulesStatus status;

  /// In run order where the provider has one.
  final List<MailRule> rules;
  final MailRuleCapabilities? capabilities;

  /// Where a move or copy can file to, named by full path.
  final List<EmailFolder> folders;

  /// The token cannot write rules yet, so any change has to run the
  /// provider's consent flow first. Reading needs nothing extra.
  final bool needsPermission;

  /// A change is on its way to the server. Every control that would start
  /// another is disabled meanwhile — two reorders in flight renumber the
  /// same rules from two different starting lists.
  final bool busy;
  final String? errorMessage;

  /// Stamped when a change lands so the screen can confirm it. A timestamp,
  /// not a flag, for the reason `OutOfOfficeState.savedAt` gives.
  final DateTime? savedAt;

  /// The folder [id] names, if it is one the picker knows.
  EmailFolder? folderById(String? id) {
    for (final f in folders) {
      if (f.id == id) return f;
    }
    return null;
  }

  MailRulesState copyWith({
    List<MailRule>? rules,
    bool? needsPermission,
    bool? busy,
    String? errorMessage,
    bool clearError = false,
    DateTime? savedAt,
  }) {
    return MailRulesState(
      accountId: accountId,
      status: status,
      rules: rules ?? this.rules,
      capabilities: capabilities,
      folders: folders,
      needsPermission: needsPermission ?? this.needsPermission,
      busy: busy ?? this.busy,
      errorMessage: clearError ? null : (errorMessage ?? this.errorMessage),
      savedAt: savedAt ?? this.savedAt,
    );
  }

  @override
  List<Object?> get props => [
    accountId,
    status,
    rules,
    capabilities,
    folders,
    needsPermission,
    busy,
    errorMessage,
    savedAt,
  ];
}
