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

The same store carries the 30 s post-dequeue tombstone removals already had,
and both reconciliation paths (`EmailRepositoryImpl._reconcileAgainstPendingOps`,
`MailPollerCubit._pendingMutations` behind the watched-folder sync, the delta
upserts and `_applyFieldUpdates`) read both namespaces alongside the pending
ops — a folder listing that resolves after the op is dequeued would otherwise
be *returned* to the bloc with the stale value even though the cache read
would have corrected it.

Failures are reported on `lastPollAt`/`lastPollErrors`, including the
offline skip. A silent `catch (_)` here is how a deterministic failure came to
look like a quiet mailbox for the life of an install.

