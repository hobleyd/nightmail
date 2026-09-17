# Contacts Typeahead

Local-only recipient search: the read path (per keystroke) and the daily write path. See [../../../CLAUDE.md](../../../CLAUDE.md) for architecture-wide rules.

## Contacts Typeahead Architecture

**The dropdown never hits the network.** Every address book is pulled down at
most once a day and searched locally. A keystroke must only ever run indexed
SQL — if you find yourself adding an API call to this path, you have
reintroduced the problem this design exists to solve.

### Read path (per keystroke)

`RecipientInputField` (`lib/presentation/widgets/recipient_input_field.dart`)
debounces 200 ms, then calls `SearchContacts`, which reads two local tables
concurrently and merges them:

- `cached_contacts` via `ContactCacheRepository` — provider directory, personal
  contacts, OS address book.
- `known_senders` via `SenderRepository.searchSendersForAccount` — people who
  have emailed this account. Written continuously as mail arrives, so it is
  always current and is deliberately *not* folded into the daily cache.

Ranking (`SearchContacts._rank`): match quality (prefix > word-prefix >
mid-string) → account domain → `ContactSource.rank` → named before bare
addresses. Capped at 8.

Two things that look optional but are not:
- **Filter in SQL, not Dart.** Both queries push the `LIKE` down. Loading a
  table and filtering in Dart is what made this slow originally.
- `_searchRequestId` in `RecipientInputField` drops out-of-order responses.
  Cancelling the debounce timer does not cancel an already-awaiting search.

### Write path (daily refresh)

`ContactCacheSyncService` (`lib/infrastructure/contacts/`) refreshes each
account at most once every 24 h (1 h after a failure). Triggered from
`main.dart` at startup (main window only — secondary windows have their own
engine and service locator), a 6 h staleness timer, `_runBackgroundPoll` on
mobile, and `AccountCubit` on account add/remove/re-auth.

Per account type:

| Type | Sources |
|---|---|
| Gmail | People API `connections` + `otherContacts` + `listDirectoryPeople` |
| Microsoft | Graph `/me/contacts` + `/users` + `/me/people` |
| IMAP | none — records a clean empty sync; suggestions come from known senders |
| macOS (all accounts) | `CNContactStore` via the contacts channel, cached under `__system__` |

- Sources fail **independently**. A partial address book is recorded as
  `status: 'partial'` with the reason in `contact_sync_states.detail`; it never
  aborts the sync. A fetch that returns nothing *and* failed leaves the previous
  cache in place rather than wiping it.
- `Contacts.Read` and `People.Read` were added to the Microsoft scopes after
  release. Accounts authorised earlier 403 on two of the three collections until
  re-authenticated from Settings; the Entra directory still populates.

### Where the work happens

Read `contact_bulk_parser.dart` before touching the fetch path — the isolate
split is easy to undo by accident:

- **SQL** — already off the UI isolate. `driftDatabase()` resolves to
  `NativeDatabase.createBackgroundConnection`, so drift hosts sqlite itself.
- **JSON decode + normalise** — `compute()`. This is the part that actually
  janks (a large tenant is tens of thousands of people). The fetchers request
  `ResponseType.plain` and pass **undecoded** body strings through; letting Dio
  call `jsonDecode` puts the expensive half back on the UI isolate.
- **Pagination tokens** — scanned out of the raw body by regex
  (`googleNextPageToken` / `graphNextLink`), because paging is sequential and
  cannot move into the isolate.
- **Network** — plain async I/O on the calling isolate; it never blocks the UI.

### Other notes

- `ContactSuggestion` (`{address, name, displayText}`) is the presentation
  shape; `CachedContact` (`{address, name, source}`) is the cache shape.
- `RecipientInputField` calls `warmUp()` in `initState()` so the macOS
  permission dialog appears when the compose window opens rather than on the
  first keystroke.
- The live per-keystroke lookup still exists but only runs for an account that
  has never synced — i.e. the window between first launch and the first
  refresh completing.
