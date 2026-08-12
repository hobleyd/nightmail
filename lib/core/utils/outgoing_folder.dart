/// Whether a folder is one whose contents are the user's *own* outgoing mail.
///
/// The thread-anchor rule (`EmailConversation.anchor`) heads a row with the
/// newest message the user did **not** send, because in an incoming folder a row
/// headed by your own reply hides whoever is waiting on you. Sent inverts that
/// premise: the user's own message is the entire reason the folder is being
/// looked at, so the same rule points the wrong way — see [isOutgoingMailFolder]
/// for what reads this.
library;

import '../../domain/entities/email_folder.dart';

/// Gmail's stable well-known label ids for the outgoing folders. Graph's folder
/// ids are opaque and IMAP's are server-chosen paths, so those two are matched
/// by display name instead.
const _outgoingFolderIds = {'SENT', 'DRAFT', 'DRAFTS'};

/// Display names the providers give the outgoing folders. Graph reports
/// "Sent Items" and "Drafts"; Gmail and IMAP both report "Sent"; an IMAP server
/// may also expose it as a child of INBOX ("INBOX.Sent"), which still carries
/// the leaf name.
const _outgoingFolderNames = {
  'sent',
  'sent items',
  'sent mail',
  'sent messages',
  'drafts',
  'outbox',
};

/// Whether [folder] holds the user's own outgoing mail (Sent, Drafts, Outbox).
///
/// A null [folder] is an unscoped view, which is not an outgoing folder: it
/// mixes both directions and wants the ordinary anchor rule.
///
/// A *user* folder the account owner happened to name "Sent" matches too. That
/// is the right answer rather than a false positive — a folder called Sent holds
/// sent mail, whoever created it.
bool isOutgoingMailFolder(EmailFolder? folder) {
  if (folder == null) return false;
  if (_outgoingFolderIds.contains(folder.id.toUpperCase())) return true;
  return _outgoingFolderNames.contains(folder.displayName.trim().toLowerCase());
}
