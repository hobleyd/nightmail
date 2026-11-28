# Gmail API Quota

What every Gmail request costs and the budget it comes out of. Read this before
adding, repeating or widening any Gmail call; the datasource's own notes are in
`lib/data/datasources/remote/gmail_datasource_impl.dart`. See
[../../CLAUDE.md](../../CLAUDE.md) for architecture-wide rules.

## The Numbers

Google changed the Gmail API quotas on 1 May 2026 (projects that used the API
between November 2025 and April 2026 kept the old ones; NightMail's Gmail
support landed in June 2026, so project 618412142210 is on the new ones):

| | Units |
|---|---|
| **Per user per minute** | **6,000** (was 15,000) |
| `threads.get` | 40 (was 10) |
| `messages.get`, `messages.attachments.get`, `drafts.get`, `messages.trash`, `threads.trash` | 20 (was 5) |
| `threads.list` | 10 |
| `messages.list`, `messages.modify`, `drafts.list` | 5 |
| `history.list` | 2 |
| `labels.list`, `labels.get`, `getProfile` | 1 |
| `messages.send`, `drafts.send` | 100 |
| `messages.batchModify`, `messages.batchDelete` | 50 |

The per-user limit is per *Google account* across every client of the project:
a phone and a Mac signed into the same mailbox share the 6,000.

What NightMail's paths cost under that table:

| | Units |
|---|---|
| One 25-row folder page (`threads.list` + 25 × `threads.get`) | 1,010 |
| Folder list on a mailbox with 129 labels, counts read in full | 130 |
| Folder list, quiet mailbox (`labels.list` + `getProfile`) | 2 |
| Watched-folder poll cycle, quiet (thread index) | 10 |
| One message opened (`messages.get` full) | 20, +20 per >2 MB inline image |
| 50-result search (`messages.list` + 50 × `messages.get`) | 1,005 |
| History delta re-fetch at its 250-message budget | 5,000 |
| Body prefetch batch (20 × `messages.get`) | 400 |
| Unread-body warm after a folder listing (≤ 20 × `messages.get`, unread rows only) | ≤ 400 |
| Load More from the cache (the folder's cached threads below the ones on screen) | 0 |
| Load More past the cache with no page token (a fast-forward by thread ids, per 500 threads skipped) | +10 |
| Offline backfill, per page (the same 1,010, at most one every 30 s) | ~2,000/min |
| Offline backfill of a 5,000-thread folder, first time and at each monthly re-check | ~200,000 over ~1 h 40 min |

## The Error

Spending the minute's 6,000 gets every subsequent request refused with a
**403** — reason `rateLimitExceeded`/`userRateLimitExceeded`, message "Quota
exceeded for quota metric 'Total Query Cost' and limit 'Units per minute per
user'…" — not a 429. `RetryInterceptor.isThrottled` recognises that body and
backs off; a 403 for any other reason is final. First seen on the HTW account on
2026-10-06 at 14:02: an account switch, a scroll, a thread open and two poll
cycles inside one minute, when the poll re-paged the folder on screen every
30 s for 1,010 units a time.

## The Rules That Keep It Under

- **Never re-page what an index can describe.** The poller reads the watched
  folder as a thread index (`ThreadIndexDatasource`, 10 units) and fetches only
  the threads whose `historyId` moved — see
  [`lib/presentation/blocs/mail_poller/CLAUDE.md`](../../lib/presentation/blocs/mail_poller/CLAUDE.md).
- **Never re-count what the history says did not move.** `getMailFolders` reads
  the mailbox's `historyId` first and asks `history.list` which labels were
  touched since the counts were last read; the memo that carries the answer
  between the poller's per-cycle datasources is `GmailLabelCountMemo`, held by
  `AccountManager` per account.
- **Bound every fan-out.** Thread, message and label fetches go through
  `_fetchInChunks` at 8 in flight (25 for the history re-fetch). A search used
  to fire all 100 of its results at once.
- **Warm bodies for unread rows only when a listing triggers it.**
  `EmailListBloc` hands `BodyPrefetchService` the unread rows of each page it
  lists, so a folder page costs 1,010 plus 20 per unread message rather than
  plus 400 flat; a user flipping between four folders in a minute would
  otherwise have spent 5,600 before the poller had its turn. The poller's own
  warms are bounded by what a sync wrote. See
  [`lib/presentation/blocs/mail_poller/CLAUDE.md`](../../lib/presentation/blocs/mail_poller/CLAUDE.md).
- **Page the offline backfill slowly, and never by re-fetching pages in
  between.** Settings > General > *Keep opened folders offline*
  (`FolderBackfillService`) walks a folder one page every 30 s — a third of
  the minute's quota, leaving the rest to the poller and the user. A page
  continues an "older than" listing on its saved token; with no token (after
  a restart) the listing is fast-forwarded by thread ids at 10 units per 500,
  never by fetching the pages in between at 1,010 apiece. See
  [`lib/presentation/blocs/email_list/CLAUDE.md`](../../lib/presentation/blocs/email_list/CLAUDE.md).
- **Cost a change in units before shipping it**: a new per-row or per-poll
  request is multiplied by 25 rows and by two cycles a minute.
