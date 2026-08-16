/// A provider-neutral classification of the folders every mailbox has one of,
/// used to map a source folder onto its *equivalent* on another account
/// (e.g. an IMAP account's Junk onto an O365 account's Junk) rather than by
/// display name, which differs per provider and per server.
///
/// Deliberately excludes Drafts: account migration skips that folder outright
/// (see the Migrate Account feature), so there is nothing that needs to
/// resolve it.
enum SpecialFolderKind {
  inbox,
  sent,
  trash,
  junk,
  archive,
}
