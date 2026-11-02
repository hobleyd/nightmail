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


## A Message's Raw Bytes Are the Literal's, Not a Rendering

`getRawEmailBytes` is the `.eml` a forward-as-attachment or an attach-to-task
sends on, so it must be the message byte for byte. `rawBytesOfFetchedMessage`
returns the `BODY[]` literal's own bytes, which the fetch parser keeps as
`BinaryMimeData` (it no longer UTF-8-decodes them — see `fetch_parser.dart`).
It used to render the message and take the string's `codeUnits`. That was
byte-exact for a literal only because `BinaryMimeData.render` writes one char
code per byte, and wrong for a non-literal answer: that text has been
UTF-8-decoded by the response reader, so every character above U+00FF was cut
to its low byte. The text fallback is now UTF-8-encoded back.
`imap_raw_email_bytes_test.dart` pins both, including a windows-1252 body that
any decode-and-re-encode would mangle.

## Testing Against a Real Dialogue

`test/data/datasources/imap_test_harness.dart` runs a scripted IMAP server and
SMTP server on loopback ports and points an `ImapDatasourceImpl` at them, so a
test drives the unmodified datasource through the full LOGIN → SELECT → UID
FETCH → SMTP DATA → APPEND-to-Sent exchange and reads back what was sent
(`harness.smtp.sent`) and filed (`harness.imap.appended`). Prefer it over
mocking `ImapClient`: the connection chain and the literal handling are the
parts worth covering, and a mock skips both. `imap_datasource_send_test.dart`
shows the shape.
