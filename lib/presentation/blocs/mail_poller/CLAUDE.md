# Mail Poller

Which folders a poll cycle syncs, and the delta-cursor rules behind it. See [../../../../CLAUDE.md](../../../../CLAUDE.md) for architecture-wide rules.

## The Poll Syncs the Folder On Screen, Not Just the Inbox

`HomePage` tells `MailPollerCubit.setWatchedFolder` which folder is showing; the
cycle syncs that as well as the Inbox and publishes the folders it wrote as
`MailPollerState.syncedFolderIds`. A repaint from cache is only valid for a
folder in that set — HomePage goes to the network for anything else, because the
poll wrote nothing there. Every account's cache is refreshed, not just the active
one. Adding a field to `MailPollerState` means adding it to `props`, or `emit`
drops the change.

The watched folder is compared against the Inbox id the poller *remembers*
(`_inboxIds`), because a quiet delta fetches no folders — and `_samePage` matches
by id on what a row shows, since the two sides differ in order and in how much
of each message they carry.

A **delta cursor is a one-shot receipt**: save it only after the page it
acknowledges has been applied, or a failed write loses those changes for good.
400/404/410 and a missing delta link all clear it, as does any three consecutive
failures — nothing else in the app ever clears one, and the table is persistent.
`MailDeltaDatasource` is the provider-neutral interface (Graph delta link, Gmail
`historyId`); both store their cursor under the `'inbox'` key.

**Not every delta item is a message.** Graph answers a read-state or flag change
with the id and the changed property alone; parsed as a message it becomes a
blank, epoch-dated row that *replaces* the real one. Those arrive as
`MailDeltaResult.fieldUpdates` and are applied to the cached row in place
(`updateCachedEmailFields`), never through `cacheEmails`.

**A just-set read state is answered from `RecentMutationStore`, not from the
row.** A message read on Office 365 went read → unread → read: `markAsRead`
writes the row and drains at once, but every list writer — `getEmail`,
`getEmails`, the poller's watched-folder sync — reconciles, *then* encrypts,
*then* writes, unordered against it, so a fetch that resolved a moment before
the click passes reconciliation (nothing pending yet) and lands its stale
`isRead:false` on top of the user's. The next poll's server copy used to paper
over it. Ordering the writers is not on the table (the poller's window is a
25-row decrypt-and-encrypt, every cycle), so
`EmailLocalDatasourceImpl.updateEmailReadStatusInCache` records the value the
user set and every cache read (`getCachedEmails`, `getCachedEmailById`)
overlays it for the store's 30 s window — long enough for the drain and the
next fetch to bring the server's copy. Pinning the *cached* value instead was
tried first and pinned the stale write: read → unread → stuck.

The same store carries the 30 s removal tombstone, and **the tombstone is
armed twice**: by the repository as it queues the op, and again by
`OutboxDrainService` the moment the server acknowledges the delete/move/junk
(or drops a delete on 404). The drain can take longer than the tombstone to
reach the server — it waits for connectivity, chains behind the calendar drain
and any drain in flight, and a throttled Graph move sits out `Retry-After` up
to five times — and while the op is queued the pending-ops set keeps the id
out; the window nothing covers is the one *after* dequeue, which the
enqueue-time tombstone had often already left. Exchange Online then answered
the next listing from a replica behind the move, the row came back, and the
following delta took it away again. The tests that cover this move the clock
between enqueue and drain (`outbox_drain_service_test.dart`); a test that
records the tombstone and feeds a stale snapshot without advancing time only
proves the window the doc describes, not the one the code runs. Both
reconciliation paths (`EmailRepositoryImpl._reconcileAgainstPendingOps`,
`MailPollerCubit._pendingMutations` behind the watched-folder sync, the delta
upserts and `_applyFieldUpdates`) read both namespaces alongside the pending
ops — a folder listing that resolves after the op is dequeued would otherwise
be *returned* to the bloc with the stale value even though the cache read
would have corrected it.

Failures are reported on `lastPollAt`/`lastPollErrors`, including the
offline skip. A silent `catch (_)` here is how a deterministic failure came to
look like a quiet mailbox for the life of an install.

## A Gmail Folder Is Re-Read as an Index, Not as a Page

The watched-folder sync used to call `getEmails` every cycle: for Gmail that is
`threads.list` plus one `threads.get` per thread, 1,010 quota units for 25
threads, every 30 s — a third of the account's 6,000 units/minute on a folder
where nothing had happened (see [`docs/claude/gmail-quota.md`](../../../../docs/claude/gmail-quota.md)).
A provider that implements `ThreadIndexDatasource` (Gmail only) is read as an
**index** instead — each thread's id and the `historyId` of its last change,
10 units — and `_watchedPageFromIndex` fetches only the threads whose stamp
moved since `_watchedIndex` last saw the folder, taking the rest from the
folder's cache. A quiet cycle costs the index and nothing else.

Three rules keep that honest:

- **The index is a receipt, like a delta cursor.** `_watchedIndex` is written
  only after `cacheEmails` has landed; remembered before the write, a failed
  write would read as a quiet folder until something else moved a thread.
- **An unchanged thread is trusted even when the cache holds no rows for it.**
  A thread whose every message is in Trash is still listed under its label
  and parses to no rows; fetching it again because it is "missing" would cost
  40 units a cycle for the thirty days Trash keeps it. Only an *empty* folder
  cache — cleared by a recovery, or never written — refetches everything, and
  the unchanged-index shortcut is skipped for the same reason.
- **A thread that was fetched and came back empty is reported empty**, not
  patched from the cache: that is how a trashed message leaves the list.

`listThreadIndex` must not touch the datasource's page tokens — the list on
screen may be mid-way through loading more of the same folder.

## A Re-Sign-In Clears the Re-Auth Flag Now, Not at the Next Tick

`accountsNeedingReauth` is rewritten at the end of each cycle, and that used
to be the only place an account that had signed in again stopped being
flagged. The folder panel ORs this set with `AccountCubit`'s own, so the Sign
In prompt outlived a successful sign-in by up to a poll interval. The cubit
now listens to `AccountManager.authSuccesses` — which a verified interactive
sign-in fires as well as the interceptor's refreshes — and an account *it had
flagged* is unflagged at once and polled at once (`_onAuthSuccess`). An
account it had not flagged is left alone: that stream also carries every
routine hourly refresh, and polling on each of those would be a second poll
timer. A shared mailbox is flagged under its own id but signs in through its
owner, so the owner's success clears the mailboxes riding on it too.

## A Cycle Must Not Put Back a Read the Server Has Not Caught Up With

`_latestPolledUnread` — the per-account Inbox count behind the dock badge and
the header envelope (`accountsWithNewMail`) — is overwritten with the server's
`unreadItemCount` by every cycle that fetches folders, and that count is
routinely answered from *before* a read the user has just made: the mark-read
PATCH is still in flight when the folder fetch lands (the cycle drains the
outbox at its top, so a read made mid-cycle is not waited for), or Graph's
count simply trails it. The user read an inbox down to zero, switched
accounts, and the next cycle flagged it again; for an account that is not
active nothing but a later cycle could clear it, and
`HomePage`'s `updateBadgeFromFolders` only ever corrects the active one.

`decrementUnreadCount`/`incrementUnreadCount` now record each change with the
count the cubit held before it (`_recentUnreadChanges`, 30 s like the folder
panel's), and `_withRecentUnreadChanges` re-applies the live ones over a
fetched count **only where it still reads exactly that** — the same rule and
the same reasoning as `FolderListBloc._recentCountChanges`. The baselines
(`_baselineUnread`) keep the raw server value: they exist to detect server
change, and the user's own read reaching the server is one. The delta branch
passes `serverMoved` when the page carried new unread mail, because arrivals
that happen to equal the reads the server absorbed leave the count reading as
before. The UI sites that move this count are therefore Inbox-only
(`markThreadReadOnceLoaded`, `_applyRemovalCountChange`, mark-unread, folder
moves): a read in another folder used to be a one-cycle inaccuracy and would
now be held for the window.
