# IMAP Connections

Why every IMAP command is serialised through one connection/mailbox selection. See [../../CLAUDE.md](../../CLAUDE.md) for architecture-wide rules.

## One IMAP Connection, One Selected Mailbox — So Serialise It

Every IMAP command goes through `withConnection`/`_withMailbox`, which chain so a
SELECT+FETCH pair is atomic. **Never `await` a sibling public method from inside
one** — it deadlocks on the link it is already holding; call an `_…Inner` helper.
IDLE runs through the same chain and yields the connection the moment anything
else queues, main window only (`AppWindow.isMain`).

A UIDVALIDITY change means the server rebuilt the mailbox and every cached
`folderId:uid` now names a different message, so that folder's cache is dropped.
The reading is persisted, because a rebuild while the app was closed is the case
an in-memory comparison cannot see.

