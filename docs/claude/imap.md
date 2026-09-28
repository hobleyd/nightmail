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


## Testing Against a Real Dialogue

`test/data/datasources/imap_test_harness.dart` runs a scripted IMAP server and
SMTP server on loopback ports and points an `ImapDatasourceImpl` at them, so a
test drives the unmodified datasource through the full LOGIN → SELECT → UID
FETCH → SMTP DATA → APPEND-to-Sent exchange and reads back what was sent
(`harness.smtp.sent`) and filed (`harness.imap.appended`). Prefer it over
mocking `ImapClient`: the connection chain and the literal handling are the
parts worth covering, and a mock skips both. `imap_datasource_send_test.dart`
shows the shape.
