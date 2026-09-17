# Email List

How the email list groups threads across folders, decides which message heads a thread, labels rows from other folders, and guards against the account-switch race. See [../../../../CLAUDE.md](../../../../CLAUDE.md) for architecture-wide rules and [../folder_list/CLAUDE.md](../folder_list/CLAUDE.md) for the folder panel's own guard.

## A Folder Listing Expands Its Threads Across Folders

Both providers return a thread's copies from *other* folders alongside the folder
page — that is what puts the Sent replies `EmailConversation.anchor` reads in
reach. Deleted Items/Junk (Graph `_expansionExcludedFolderIds`) and TRASH/SPAM
(Gmail `excludeLabels`) are excluded, or a deleted message comes back on every
refresh: a delete *moves* it, so it keeps its `conversationId` and gets a **new
id** the outbox's pending-op and tombstone reconciliation cannot recognise.

**Graph's exclusion is in the request, not in the merge.** The expansion filter
carries `parentFolderId ne '<id>'` for each excluded folder, because Graph does
not encode a folder id consistently: `/mailFolders/deleteditems` answered one
mailbox with an `AQMk…` id while its messages carried `AAMk…` in
`parentFolderId`, so a string comparison on the client kept nothing out and a
Drafts listing filled with the Deleted Items copies of the threads its drafts
answered. The merge still compares client-side as a second line, and the
per-conversation fallback retries without the clause if a tenant refuses it.

The whole page is cached under the folder being listed, expansion rows
included — so a `cached_emails` row is *one message as seen in one folder*, and
`folderId` is in its primary key. Without it an `insertOrReplace` moved the row,
and listing any folder emptied every other folder's cache of the mail they
shared a thread with. `CacheMembershipRepairService` files misplaced rows back
once per account, reading each one's own folder out of its payload.

`BodyPrefetchService` writes through `upgradeCachedEmailBody`, never
`cacheEmails`: its write lands a round-trip after its "still cached?" check, on
the message the user is most likely reading, so only a present-row-only write
inside one transaction can refuse to resurrect a delete that landed meanwhile.
It upgrades every folder's copy and files no new one — a body belongs to the
message, and taking a folder there was a second way to re-file a row.

**A folder listing must never read a body.** Bodies and inline image bytes live
in `cached_email_details`, keyed by message rather than folder, because
`getCachedEmails` decrypts every row it returns and those fields are all of the
bytes — one real Sent folder cost 2.4 s of AES on the UI isolate before painting.
Attachment *metadata* stays on the list row: it is in `Email.props`, so serving it
empty makes every IMAP folder compare unequal to its own cache on every poll.

**The expansion asks per chunk, not per thread.** Graph takes one
`conversationId in (…)` request per 15 ids, so a page costs 2 requests rather
than 25; Gmail has no multi-thread get, so it is bounded to 8 in flight instead.
25 at once is enough for either provider to throttle, and a 429 buys a second or
more of `RetryInterceptor` backoff.

## A Gmail Thread Can Be In a Folder When None of Its Messages Is

A Gmail folder listing is `GET /users/me/threads?labelIds=<folder>` — it asks
for **threads** the label applies to and then shows every message of each one.
So a thread can sit in the Inbox with not one of its messages carrying `INBOX`.
Real mailboxes reach that state: a move that reached some messages and not
others, a filter, a label edit from another client.

Every folder-scoped action is per *message* (`Email.isInFolder`, off the raw
label list the parser stamps into `folderIds`). In that state none of them
qualifies, so `_onEmailsMoved` used to hit `if (idsToMove.isEmpty) return;` —
**no request, no error, no change on screen**, and the thread back on the next
listing. Pressing Move did nothing, forever, and looked like nothing had been
pressed.

`ConversationFolderDatasource.removeConversationFromFolder` is the fallback:
`threads/{id}/modify`, which writes the *conversation's* own label state — the
thing the listing reads and the thing a loop over `messages/{id}/modify` cannot
touch, since each of those would be a no-op here.

Four things are load-bearing:

- **Removal only, never an add.** The thread endpoint reaches the copies in
  Sent, and dropping a destination label on those is exactly what
  `Email.isMovableFrom`'s Sent guard exists to prevent. So the fallback cannot
  *file* a thread, only take it out of here — `destinationFolderId` is not
  honoured. In practice a thread that gets stuck like this has usually been
  moved already and the labels are right; the listing is all that is wrong.
- **`UnsupportedFailure` is not a failure to report.** Graph and IMAP file a
  message in exactly one folder and have no thread-level membership, so there
  the empty `idsToMove` really does mean "this selection is other-folder
  context" and the old silent return is correct. A distinct failure type is what
  lets the bloc tell that apart from a move that genuinely broke.
- **Network-first, deliberately not in the outbox.** Every pending op is keyed by
  *message* id, and a Gmail thread id is routinely also the id of the thread's
  first message (`19f8c30ceaff85df` is both) — a queued op here would be in reach
  of the drain's id-remapping for that message. Offline it fails and says so,
  which is honest: there is nothing about a repaired thread to show
  optimistically.
- **It acts before touching the list**, unlike the per-message path either side
  of it. There is no optimistic removal to make, and pulling rows out only to
  put them back on the `UnsupportedFailure` every non-Gmail account returns would
  flicker the list on the common case.

**A drag has to be thread-scoped for any of this to be reached.** The only
thing that raises `EmailListEmailsMoved` is the folder panel's drop target, and
it passes the `conversationId` the dragged row carried. A conversation header
always has one. A *top-level* single row is a one-message thread and now carries
one too — but a **child** row inside an expanded thread deliberately does not:
it is an individual message, and dragging the thread's copy in Sent out of the
Inbox has to stay the no-op it is rather than filing the whole thread away. A
multi-select drag drops the `conversationId` for the same reason — the user
named specific messages.

`EmailListActionFailure` carries a `sequence` because of `props`: without it the
same failure twice in a row compares equal, the second emit is dropped, and a
user pressing the same broken button twice is told once. Same trap as
`MailPollerState`. It is a snack bar rather than `EmailListError` — the list
itself is fine, and replacing it would be a worse lie than the silence.

## A Thread Row Is Not Its Newest Message

A collapsed thread row shows its **anchor**: the newest message the user did not
send (`EmailConversation.anchor`, `email_list_conversations.dart`). Graph and
Gmail both surface a thread's copies in Sent inside a folder listing, so a
folder the user has replied in was otherwise full of rows headed by their own
replies — which tell them nothing they don't already know, and hide whoever is
waiting on them. A thread of nothing but the user's own messages (one they
started and nobody has answered, or anything seen from Sent) falls back to its
newest, because the row still has to show something.

`selfAddress` — `AccountManager.activeAccount?.emailAddress`, threaded in from
the panel — is what tells the two apart; the list only ever shows one account, so
the active one answers for every row. An **empty** from address counts as the
user's own: that is an unsent draft. Omitting `selfAddress` restores
newest-heads-everything, which is what the pure grouping tests exercise.

**Sent inverts the rule.** `isOutgoingMailFolder` (`core/utils/outgoing_folder.dart`)
turns on `groupIntoConversations`'s `anchorOnSelf` for Sent/Drafts/Outbox, or the
expansion's Inbox copies head every row — and date every thread — with the
correspondent's message, filing a reply sent today under the date it answered.

Three consequences, none incidental:

- **Threads sort by `anchorDate`, not `latestDate`.** The row shows the anchor,
  so ordering on the thread's newest message runs the *visible* dates down the
  list out of sequence. A thread answered long after it arrived therefore sits
  where the incoming message put it, not at the top.
- **An expanded thread repeats its own anchor**, drawn in italics
  (`EmailListItem.isDuplicate`). Leaving it out would strand the reply above it
  over a gap, and the back-and-forth is the only thing the order conveys. The
  one exception is an anchor that is *also* the newest message: repeating it
  directly beneath the header it just filled is noise, so
  `expandedEmails` drops it there — which is the whole of the old `skip(1)`
  behaviour, now a special case rather than the rule.
- **The echo row carries the header's id**, so it is the same message for every
  purpose but drawing. That makes it the header's equal for selection and delete
  (`resolveDeleteTargets` keys threads off `anchor.id`), and rules three things
  out: it takes no flag/delete buttons (one `FocusNode` cannot be attached to two
  widgets), no drag or swipe wrapper (both would act on the row above), and no
  keyboard stop — `_isNavigable` skips it, or arrow-down would select what is
  already selected and bounce back to the header on the next press.

## A List Row Names Its Own Folder

A row whose message is **somewhere else** names that folder in brackets between
the sender and the date (`emailFolderLabel`,
`presentation/widgets/email_folder_label.dart`). A folder listing carries
messages from other folders — the copies in Sent and the already-filed replies
both providers expand a thread with — and this is how a reader tells those apart
from the mail that is really here.

Five things here are load-bearing:

- **A message that is in the folder on screen gets no label at all**
  (`Email.isInFolder`). The pane already names that folder above the list, so
  labelling nearly every row of a listing with it says nothing and crowds out
  the sender. The label means *elsewhere*.
- **Only a folder listing may suppress** (`EmailListLoaded.isShowingFolder`).
  Search results and a focused thread are drawn from across the mailbox, so
  there the panel passes no current folder and every row names its own — a hit
  from Archive would otherwise be silently taken for one in whatever folder is
  still selected in the panel behind it.
- **A raw provider id is never drawn.** Gmail stamps every label a message
  carries into `folderIds` — `UNREAD` and `IMPORTANT` among them — and a Graph
  folder id means nothing to a reader. Anything that does not resolve against
  `FolderListBloc`'s tree is skipped, and a row with nothing left to resolve
  gets no brackets rather than a `Label_123`. Resolving against the tree is what
  drops the non-folder labels, for free.
- **A Gmail category resolves, and is skipped anyway** (`isGmailCategoryLabel`,
  `core/utils/gmail_category_label.dart`). `getMailFolders` turns the five
  `CATEGORY_*` ids into folders (`Category/Personal` and friends) — browsing one
  is the only way to reach an inbox tab in an app that has none — so they are
  *in* the tree, and the first-resolvable-id loop named them. `folderIds` is in
  Gmail's own order, which routinely puts `CATEGORY_PERSONAL` ahead of the label
  the message was actually filed under, so a message filed under a nested user
  label — `Vendors/Acme`, say — drew `[Personal]` and sent the reader looking in
  a folder it had never been in. A category is skipped rather than ranked last: a
  message carrying nothing else gets no brackets, because naming the category
  there is the same wrong claim with nothing on the row left to contradict it.
  The parser already keeps categories out of `parentFolderId` (`_isSystemLabel`
  lists all five), so the fallback agrees with the loop; it is guarded regardless
  so the two cannot drift. Matched by exact id, never the `CATEGORY_` prefix — a
  *user* label may be called anything, and swallowing one would be this bug in
  reverse. Note that two folders can display as "Personal" either way, since a
  Gmail label's display name is its leaf segment: `CATEGORY_PERSONAL` and a user
  label `Work/Personal` both draw as `Personal`.
- **The id→name map is held in `_EmailListPanelState`, not watched.**
  `EmailFolder.props` carries the unread counts the poller rewrites every cycle,
  so a `BlocBuilder` here would rebuild every row in the list each time a count
  moved. A listener refreshes the map only when a *name* changes.
- **The label is capped, and the cap is a fraction of the row**
  (`folderLabelMaxWidth`). The sender is the row's only flexible child, so a
  label laid out at its natural size squeezes the sender to nothing and then
  pushes the date off the end — and making the label flexible instead would
  ellipsise it while there was still room, since a Flex hands a loose child its
  share rather than what it asks for. Hence the `LayoutBuilder`: an inflexible
  child of a Row is measured against an unbounded width and cannot work its own
  share out.

## Which Folder an Account Switch Lands On

`HomePage`'s `AccountCubit` listener owns the whole switch — it files the
outgoing folder under the account being left (`_accountShowing`) and drops the
selection; `folderToAutoSelect` restores it when the new folder list *lands*, so
the saved id is checked against real folders and falls back to the Inbox.
Nothing may select a folder at switch time: that listener clears it a beat
later, which is what made the old restore in `folder_panel.dart` a no-op.

### A Null Folder Is the Whole Mailbox, Not No Folder

`getEmails(folderId: null)` is `/me/messages` on Graph: the newest mail of the
entire mailbox, every folder included, cached under `__DEFAULT__`. Nothing in
the app asks for that on purpose, so a null reaching a fetch is a bug that
*succeeds* — 25 rows come back and are painted into whatever folder the panel
still names, each labelled with its own folder because `currentFolderId` is
null. Observed, on a real install: an **empty Drafts folder** filled on refresh
with the last few hours of Deleted Items, Junk and filed mail, and 25 rows
under `__DEFAULT__` in the cache afterwards.

`_onRefreshRequested` used to read the folder off the loaded state alone, and a
folder with nothing cached and nothing yet fetched has none — it is
`EmailListLoading`, or `EmailListError` if the first fetch failed — so every
refresh that landed in that window (a poll, the drafts-changed channel, the
Refresh button) went mailbox-wide, and being the slower of the two fetches in
the same generation it won the screen. It now stands down while a load is
running, exactly as `_onCacheRefreshRequested` does, and otherwise takes the
folder from `_lastLoadedFolderId`, which is what that field is for.

### A Folder Id Is Only Meaningful to the Account It Came From

`AccountManager.activeAccount` flips **before** `AccountCubit` emits, so between
the switch and the `EmailListCleared` that follows it `EmailListBloc` holds one
account's folder id while the datasource, the cache key and the account id every
use case reads have already become the next account's. Anything that reuses
`currentFolderId` in that window addresses the new account with the old
account's folder.

Observed, on a real install: 22 Graph Inbox messages filed under the Gmail
label id `INBOX`, and the same 22 under the real folder id ten seconds later.
So the request evidently *succeeds* rather than erroring — which is the shape
of this that makes it quiet. `EmailRepositoryImpl.getEmails` already binds the account id and the
datasource together before its await (`email_repository_impl.dart`), which is a
different half of the same race: those two agreed here, and the folder id was
the stale one.

`EmailListBloc._loadedAccountId` records the account that was active when the
folder was *chosen* — set in `_onLoadRequested`, which is the only thing that
establishes one — and `_folderBelongsToAnotherAccount` stands the refresh,
load-more, cache-repaint and the repaint's cold-start reload down until the new
account's own load arrives. Same shape as `FolderListBloc._loadedAccountId`.

Three things here are load-bearing:

- **The capture has to be at the load, not at the handler.** A handler that
  reads the active account at its own start compares the new account against
  the new account and passes — the switch happened before it ran. That version
  looks right and guards nothing.
- **`EmailListCleared` must not clear it.** That event *arrives* in the window
  this guards, so clearing there would disarm the guard for exactly as long as
  it is wanted. The next `EmailListLoadRequested` overwrites it, the same way
  `_lastLoadedFolderId` is handled.
- **The repaint is the one with a user-visible failure.** The others 404 or
  write to a key nothing reads, but `_repaintFromCache` reads the *new*
  account's cache under the *old* account's folder key — and that key can hold
  rows, because this race is what filed them there. A hit paints one mailbox's
  Inbox into a list the folder panel still names as the other's, with no network
  call to fail and nothing to report.

The rows earlier builds filed under a phantom key are cleared by
`CacheMembershipRepairService`'s second pass, once per account at launch
(`pruneForeignFolderRows`). They cannot come back — the race is closed — so this
is one-shot residue, and the pass is written to be **lossless rather than
thorough**, because the folder list it judges rows by may itself be wrong:

- **An unknown folder tree is not an empty one.** No cached folders means prune
  nothing *and do not mark the account done*, or "we could not tell" is recorded
  as "there was nothing to do" for good. The next launch, by which point a tree
  has been cached, tries again.
- **A row only goes while a known folder still lists the same message.** So the
  worst a folder list that arrived incomplete can do is leave a row behind,
  which is the thing being cleaned up — never lose a message, and never orphan a
  cached body (bodies are collected once no folder lists their message).
- **`__DEFAULT__` is a real key, not residue.** It is what a listing with no
  folder is filed under, and it is in no folder tree.

Its marker is its own sentinel (`__foreign_folder_prune__`), because an install
that has run the older membership repair has not necessarily run this.

