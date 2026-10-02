/// Whether a folder is the account's Inbox, for code that needs the Inbox
/// without a network round-trip (the commitments scan reads it from the
/// folder cache).
///
/// Matched the same way [isJunkMailFolder] matches Junk: Gmail's and IMAP's
/// well-known id, or display name for Graph, whose ids are opaque. Carries the
/// same localization caveat — a German Graph mailbox reports "Posteingang" and
/// does not match; `MailPollerCubit` makes the same bet by name.
library;

import '../../domain/entities/email_folder.dart';

const _inboxFolderIds = {'INBOX'};

/// Whether [folder] is the Inbox.
bool isInboxFolder(EmailFolder? folder) {
  if (folder == null) return false;
  if (_inboxFolderIds.contains(folder.id.toUpperCase())) return true;
  return folder.displayName.trim().toLowerCase() == 'inbox';
}
