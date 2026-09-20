/// Whether a folder is the account's Junk/Spam folder, for UI that changes
/// behaviour there (the Report-junk action becomes Not-junk; see
/// `EmailListPanel`).
///
/// Matched the same way [isOutgoingMailFolder] matches Sent/Drafts: Gmail's
/// well-known label id, or display name for Graph/IMAP whose ids are opaque or
/// server-chosen. The name set mirrors ImapDatasourceImpl's own `_junkNames`.
///
/// **Does not survive localization.** A Graph mailbox in German reports
/// "Junk-E-Mail", French "Courrier indésirable" — those don't match and the
/// user sees Report-junk while already sitting in Junk. The provider-accurate
/// signal (`EmailRemoteDatasource.getSpecialFolderIds`) exists at the data
/// layer but isn't plumbed up to presentation; doing so for this one button
/// wasn't judged worth the four layers it would cross.
library;

import '../../domain/entities/email_folder.dart';

const _junkFolderIds = {'SPAM'};

const _junkFolderNames = {
  'junk',
  'junk e-mail',
  'junk email',
  'spam',
};

/// Whether [folder] is the Junk/Spam folder.
///
/// A null [folder] is an unscoped view (search, a focused thread), which is
/// not a folder to be "in" at all.
bool isJunkMailFolder(EmailFolder? folder) {
  if (folder == null) return false;
  if (_junkFolderIds.contains(folder.id.toUpperCase())) return true;
  return _junkFolderNames.contains(folder.displayName.trim().toLowerCase());
}
