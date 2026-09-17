import '../../../domain/entities/out_of_office_settings.dart';

/// Reads and writes a mailbox's automatic-reply configuration.
///
/// A narrow interface of its own rather than methods on [EmailRemoteDatasource]
/// — the same shape as [ConversationFolderDatasource] — because only two of the
/// three mail providers have the concept at all. IMAP has no such server
/// setting, and putting these on the shared interface would force
/// `ImapDatasourceImpl` to stub a method it can never honour. The repository
/// tests for it with `is` and answers `UnsupportedFailure` when it is absent.
///
/// Implemented by `GraphApiDatasourceImpl` and `GmailDatasourceImpl`.
abstract interface class OutOfOfficeDatasource {
  /// The mailbox's current automatic-reply configuration.
  Future<OutOfOfficeSettings> getOutOfOffice();

  /// Applies [settings] to the mailbox.
  ///
  /// Implementations read the current configuration first and write it back
  /// whole. That is not an optimisation to remove: Gmail's `updateVacation` is
  /// a PUT (an omitted field is a *cleared* field, so the reply subject and
  /// the restrict-to-contacts flags would be wiped by a partial write), and
  /// Graph replaces a complex property rather than merging into it, which
  /// would drop `externalAudience` the same way.
  Future<void> setOutOfOffice(OutOfOfficeSettings settings);
}
