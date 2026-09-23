# Folder List

Optimistic counts, cache-freeze recovery, and folder create/move/delete/empty in `FolderListBloc`. See [../../../../CLAUDE.md](../../../../CLAUDE.md) for architecture-wide rules and [../email_list/CLAUDE.md](../email_list/CLAUDE.md) for the account-switch race this shares.

## A Folder Fetch Must Not Put Back a Count the User Just Changed

Every unread/total count on the folder panel is optimistic first
(`FolderListUnreadCountChanged`) and replaced wholesale by the next
folder-tree fetch. That fetch is routinely answered from *before* the change:
the poller echoes a mark-read back as a delta and reloads the tree, a second
message read while that walk is in flight is decremented and then put back by
the result — and Graph's `unreadItemCount` trails a PATCH by a moment, so a
fetch issued *after* the read can answer the same way. Two unread, both read,
Inbox saying 1 until something else reloaded the tree.

`FolderListBloc._recentCountChanges` keeps each change for 30 s (the
`RecentMutationStore` window) with the counts the folder read *before* it, and
re-applies it to a fetched list **only where the folder still reads exactly
that** — the signature of a server that has not caught up. A folder whose
counts moved at all is taken at the server's word: re-applying there would
count the change twice once the server did reflect it, and nothing in the
bloc can tell that from another client's change without the comparison.
Entries are re-applied in order over the running value, so two reads over a
server behind both, or behind only the first, both land on the right count.

## A Failed First Load Must Not Freeze the Cache On Screen

`FolderListBloc` and `EmailListBloc` both load cache-then-network and swallow the
network failure while cached data is showing. So both retry it
(`core/utils/stale_data_retry.dart`), and `MailPollerCubit._shouldPrimeBaseline`
lets the first poll compare the active account against the counts the badge was
primed from — otherwise a cold start whose first fetch failed silently sat on
yesterday's counts until the user pressed Refresh.

`FolderListBloc`'s prefer-state-over-cache shortcut is guarded on the account id
(`_loadedAccountId`): an account switch only re-requests, never clears the bloc,
and re-emitting the old mailbox's folders makes HomePage auto-select an Inbox id
the new account does not have (`folderToAutoSelect`).

## A New Folder Is Shown Before the Tree Is Re-Fetched

Creating a folder used to await the create round trip *and then* a full
folder-tree fetch — `getMailFolders` plus a `getChildFolders` round trip per
level of the hierarchy — before anything appeared, so the name the user had
just typed vanished and came back a beat or more later. Both halves were on
the critical path; neither has been timed against a real mailbox, so which
dominates is unknown, and the fix removes the second one either way.

`EmailRepository.createFolder` returns the **created folder**, not `unit`.
Every datasource already knew the server's id for it (Graph folder id, Gmail
label id, IMAP path — the path is deterministic, so IMAP needs no lookup) and
the repository was throwing it away. `FolderListBloc` inserts that folder into
state as soon as the create returns and *then* requests the reconcile, which
now only corrects counts and sort position.

**No id that isn't the server's may reach the UI.** That rule is what makes
this safe rather than something to defend with guards, and it is why the
in-flight row is a `PendingFolderCreation` — a name and its parent, no id —
rather than a folder with a local stand-in id. A stand-in would be a valid
move destination as far as everything downstream could tell, and dropping mail
on it would: enqueue a `move` op naming a folder the server has never heard
of, tombstone the message and delete its cache row *immediately*, then fail on
every drain — `move` is deliberately excluded from the 404-drop set — until the
25-retry budget ran out. The message would appear to move, never arrive, and
return on the next folder sync with nothing left to explain it.

The pending row is drawn whether or not its parent is expanded, and appended
at the root if that parent has gone altogether. A failed create is cleared
only by its own retry or dismiss button and survives a reload by design, so
anything that can hide the row strands it. It is dropped on an account switch
for the same reason — its parent is in the mailbox being left.

**Dragging a folder onto another one is the same story with a sharper edge.**
Only the tree fetch moved the row — and when it landed the row *vanished*,
because a folder you have just dropped something onto is a folder you have not
expanded, so it arrived out of sight inside it. Two halves to that: `moveFolder`
now returns the folder's id after the move and `FolderListBloc` reparents the
row (adjusting both parents' `childFolderCount`, which is what draws the
disclosure arrows) as soon as the provider accepts; and `FolderPanel` opens the
drop target on the drop.

Nothing is drawn ahead of the provider's answer here, unlike a create: the row
is already on screen where it started, so moving it early would mean putting it
back on a failure. A refused move leaves the folder where it was and changes
nothing else.

**A row has two folder-drop zones, and the lower one is the only way to the
top level.** Dropping *onto* a row makes the dragged folder its child, so a
mailbox whose top level is nothing but system folders (a SharpBlue account)
had no folder to drop onto that meant "back to the root". Outlook's gesture is
what `_FolderItem` does now: over the upper part of the row it highlights
(child); ease the drag into the bottom `_siblingZoneFraction` of the row and a
line is drawn under it instead, starting at that row's own indent, and the
drop makes the folder the row's *sibling* — under the row's parent, or the
root when the row has none. The line says which level, not which position:
siblings sort by name, so the folder lands wherever its name puts it.

Four things are load-bearing:

- **The root is the empty string, end to end.** The same sentinel
  `createFolder` already takes, so `MoveFolderParams.newParentFolderId` stays
  a non-null `String` and each datasource maps it itself: Graph to its
  `msgfolderroot` well-known name, Gmail to the bare leaf label, IMAP to the
  leaf under `_inboxFolderPrefix` — on a Courier-style server everything the
  user sees as top level really lives under `INBOX`, and a bare leaf would land
  outside the namespace the folder list reads.
- **`EmailFolder.copyWith` cannot clear a parent with `null`** (null means
  keep, as for every other field), so it takes `toRoot: true`. Without it the
  bloc's optimistic reparent silently left the folder where it was, and the
  reconcile then took the server's list as *disagreeing* with a move that had
  in fact applied.
- **The zone is read from the pointer, not from `DragTargetDetails.offset`.**
  That offset is the feedback's anchored corner, which with
  `childDragAnchorStrategy` is wherever in the row the user grabbed it. The
  panel already tracks the pointer through a global route for auto-scroll, and
  hands the row a getter.
- **A zone whose move would be a no-op or a cycle draws nothing and drops
  nothing**, while the other zone on the same row still works: a folder's own
  parent refuses "into" but takes "sibling", and a folder's sibling the other
  way round. So `onWillAcceptWithDetails` says yes if *either* zone would, and
  the zone is decided again at the drop.

**On a touch screen the row is a `LongPressDraggable`, not a `Draggable`.** A
`Draggable` claims the touch the moment it moves, so on a phone every swipe
that began on a user folder picked the folder up and a list longer than the
screen could not be scrolled at all. On touch a swipe scrolls; holding still
lifts the folder (with a haptic) and dragging on from there moves it. That
takes the long press the context menu used on touch, and the two recognisers
race on the same 500 ms timer — whichever fires first wins the arena, so a row
must not carry both. The menu on a draggable row is therefore what iOS does
natively: hold, then let go without moving (`onDraggableCanceled` with the
finger still within touch slop of where it went down). System folders are not
draggable and keep the plain long-press menu. `folder_panel_test.dart` pins
`debugDefaultTargetPlatformOverride` around each drag test because the test
binding's default platform is Android.

**A move can change the folder's id, and then the optimism is off.** IMAP
mailbox paths and Gmail *virtual* folder ids (`__virtual__<path>`) are paths, so
moving one mints a new id — and every descendant's id changed with it. Nothing
above the datasource can derive what they are now, so the bloc applies nothing
and leaves the whole subtree to the fetch. Graph and real Gmail labels keep
their id, which is why the id has to be *returned* rather than assumed either
way.

**A tree fetch that omits the just-created folder must not delete it.** The
fetch is a wholesale replacement and both providers can answer one built a
moment too early (Graph propagation, Gmail's cached label list), including the
reconcile the create itself fires. So the bloc re-applies an unconfirmed change
to a list that disagrees with it, for `_unconfirmedFolderGrace` fetches — past
that the disagreement is more likely the truth (changed from another client)
than lag. Entries are cleared on an account switch.

What counts as agreement differs by change, which is the whole of
`_unconfirmedFolders`' `isMove` flag: a create is confirmed by its id being
listed at all, a move only by its id being listed **under the parent it was
moved to**. Confirming a move on the id alone would take a stale list naming
the folder in its old place as agreement and put the row back.

`EmailFolder.props` carries `parentFolderId` and `childFolderCount` because of
this: inserting a child bumps its parent's count, and an emit that changed
nothing else would otherwise compare equal and be dropped — same trap as
`MailPollerState`.

### Being drawn is not the same as being on screen

Both ends of a create — the inline editor, and the folder row that replaces it
— land wherever the tree puts them, which in a list taller than the panel is
routinely out of sight. The editor opens under the parent's *last child*, and
the folder then sorts in among its siblings, so the two are not even in the
same place: adding a folder to a parent with forty children opened the editor
below the fold and, once named, filed the row above it.

`Scrollable.ensureVisible` is not enough on its own, because **a
`ListView.builder` row that is off screen has no context to scroll to** — it
was never built. That is why the editor's old reveal was a silent no-op in
exactly the case that needed it (an invisible editor is also an unreachable
one: there is no `TextField` to type into). So `_revealTargetRow` *jumps*
first, using the row's index against the list's own extent estimate, and
positions it exactly on the next frame, when the row really exists. Four
attempts is a backstop, not a search.

Three things here are load-bearing:

- **A row already fully inside the viewport is left alone.** `ensureVisible`
  scrolls whether or not it needs to, so centring unconditionally would jerk
  the list on the common case — a folder appearing directly under the parent
  it was added to, in plain sight.
- **The create is remembered by parent + typed name, not by id.** There is no
  id at submit time, and the folder may arrive on either of two states (the
  create's reply, or the reconcile fetch behind it). It is kept across a
  *failed* create so the retry button needs nothing of its own, and the parent
  is re-expanded when the match lands — a row must be in the display list to
  be scrolled to.
- **The editor focuses itself outright, not by `autofocus`.** A `TextField`'s
  `autofocus` is honoured only while nothing else in the enclosing
  `FocusScope` holds focus — and the context menu the editor was chosen from
  restores focus to whatever had it before, on its way out. So the field
  opened *dead*: visibly ready, needing a click before it would take a
  keystroke. It is invisible in a test harness holding nothing else focusable,
  which is why `folder_panel_test` pumps the panel beside a `Focus` standing in
  for the rest of the app. The rename editor is the same shape and got the same
  treatment.
- **The `GlobalKey` is attached by index, and never to the editor.** Matching
  the item a second time could put one key on two rows, which throws; and the
  editor keeps its own key, which is what preserves the text being typed while
  the reveal wrapper comes and goes.

`test/presentation/widgets/folder_panel_test.dart` is the panel's first widget
test, and two things in its harness are load-bearing: **the `FolderListBloc`
must be constructed inside the test body, not in `setUp`** — a bloc's event
stream belongs to the zone that made it, and one made in `setUp` delivers its
events outside the tester's fake-async zone, so the load event never runs and
the panel sits on its spinner until `pumpAndSettle` times out. The other is
that `AccountCubit`, `MailPollerCubit`, `EmailListBloc` (every folder row
subscribes to it), `OverdueTasksCubit` and `UpdateCubit` are all read during
build, and `AccountMigrationService` is reached through `sl`.

The failure is no longer swallowed. A failed create keeps the typed name on
screen in red with the reason and a retry, which is also the only thing that
reports a create attempted offline (`createFolder` goes through `_execute`, so
it fails fast rather than queueing — folders are not in the outbox).

### Deleting One Is the Same Shape, Minus the Optimism

"Delete Folder" sits on the folder's own context menu between "Rename Folder"
and "Delete All" — which deletes the *mail* in a folder, not the folder, and is
why the new item needed a name that could not be read as the old one.

Nothing is drawn or undrawn ahead of the provider's answer, the same rule a
move follows: the row is on screen where it has always been, so a refused
delete simply leaves it there, and that row is the whole of the report. Once
the provider accepts, `FolderListBloc` takes the row away — with its whole
subtree — and requests the reconcile fetch behind it.

Five things here are load-bearing:

- **The subtree goes, and two providers need telling.** Graph and IMAP delete a
  container and its contents follow, but a Gmail "folder" is a label and
  `Vendors/Datadog` is a *separate* label that outlives `Vendors` — as a root
  folder, which is worse than leaving it alone. So the Gmail datasource deletes
  every label sharing the path prefix, which also makes a **virtual** folder
  (`__virtual__<path>`, a path segment with no label of its own) deletable at
  all: its descendants are the only thing there is to delete. IMAP goes
  deepest-first, because RFC 3501 leaves a deleted parent's inferior names in
  place and the parent behind as a `\Noselect` husk.
  `test/data/datasources/remote/gmail_delete_folder_test.dart` pins which
  labels the Gmail path deletes — chiefly that a sibling named
  `Vendors Archive` is *not* inside `Vendors`, and that an unresolvable id
  deletes nothing rather than resolving to an empty prefix that matches every
  label there is.
- **What happens to the messages is said out loud, and it differs.** Deleting a
  Gmail label deletes no mail — every message keeps its other labels and stays
  in All Mail — where Graph and IMAP take the contents with the folder. Those
  are not the same warning, so the dialog asks `AccountCubit` which account is
  active and says the one that applies. It does not name Deleted Items:
  where a deleted folder's mail lands is the server's business and is not the
  same everywhere.
- **A system folder gets no menu item**, rather than one that fails. That is
  the whole of `_FolderItem.onDelete` being nullable: the question is asked
  once, where `_isSystemFolder` already answers it for dragging. That match is
  by *display name*, not by any provider's well-known-folder id — so a user
  folder called "Archive" is undeletable here too. Pre-existing, and the
  conservative direction, but it is a name match and not a fact about the
  server.
- **No unconfirmed-delete grace, deliberately.** A create needs one because a
  tree fetch built a moment too early would *delete the new folder* from the
  list — unrecoverable, and invisible. The delete direction is benign: the
  worst a stale list can do is show a folder that really does still exist for
  that moment, and the next fetch takes it away again.
- **A selection pointing into the subtree moves before the answer comes back**,
  unlike everything else here — the alternative is a list pane sitting on a
  folder whose row has just left the panel. The dialog lives on
  `_FolderPanelState` rather than the row for this: only the panel holds the
  folder list, which is what says both what else is about to go and where the
  selection can safely land (the Inbox). Clearing the reading pane is left to
  `onFolderSelected`, which does it for every folder change already.

Cached rows for a deleted folder are **not** cleared. They are keyed by folder
id and nothing lists that folder any more, so they are dead weight rather than
a wrong answer; clearing them would mean a new bloc dependency and an account
id to go with it.

### Emptying One Is Gmail's Odd Case, and It Failed Silently

"Delete All" empties a folder's *mail*. `GmailDatasourceImpl.emptyFolder` threw
`UnimplementedError` — which `_executeLocal`'s bare `catch` turns into a
`ServerFailure` like any other — so on a Gmail account the action had never
worked, and nothing said so: the list blanked optimistically, the failure was
discarded, and the folder's counts were zeroed on the panel.

Gmail has no empty-folder endpoint, so this is list-then-batch:
`messages.list?labelIds=<folder>` for ids, then one `messages/batchModify`
adding `TRASH` and removing the folder's own label. Five things:

- **`includeSpamTrash` is not optional.** The listing hides both by default, so
  asking for `labelIds=SPAM` without it returns no ids at all — an empty that
  touches nothing and reports success, which is the failure this replaced.
- **The source label goes with the message.** A message that keeps `SPAM` is
  still listed under Spam by `threads.list`, which is what the folder on screen
  reads. Same rule `moveEmail` follows.
- **It re-lists rather than paginates.** Each batch stops carrying the label, so
  the next listing *is* the next page — and a page token minted before the
  labels moved out from under it is not. An *empty* listing ends the loop; one
  that comes back **unchanged** is a modify that answered 200 without taking,
  and that **fails** rather than ending it. The difference matters because
  success here is not inert: `EmailRepositoryImpl.emptyFolder` clears the
  folder's cache on it, so breaking out quietly would be the silent empty all
  over again, with the local copy of the surviving mail thrown away too.
- **A `__virtual__` folder is refused.** It is a path segment carrying no label
  of its own, so there is nothing to list by and nothing to remove.
  `deleteFolder` resolves the same id to its descendants — it can, because
  deleting a *label* takes no message anywhere — but emptying one would delete
  mail out of folders the user did not name.
- **The trash is `messages.batchDelete` instead, and asks for a scope first.**
  Emptying the trash is a *permanent* delete, and Gmail's only one accepts no
  scope short of `https://mail.google.com/` — see below. The datasource takes
  that route on the `TRASH` id **as well as** on the `permanentDelete` flag,
  because the two are decided in different places (the panel asks
  `AccountCubit`, this runs off `AccountManager.emailDatasource`) and the other
  reading of a trash empty is `addLabelIds: [TRASH]` alongside
  `removeLabelIds: [TRASH]` in one request, which Gmail resolves however it
  pleases.

#### Permanently deleting needs a scope a sign-in does not ask for

`GmailAuthService.fullMailScope` (`https://mail.google.com/`) is what
`messages.batchDelete` takes, and nothing less does — `gmail.modify` can move a
message to the trash but never destroy one. It is requested **incrementally**,
by the confirm dialog that empties the trash, for the same reason
`driveReadonlyScope` is (and `_roomDirectoryScope` before it): Google classes it
restricted and it is the broadest scope Gmail has, so naming it in `_scopes`
puts the heaviest consent screen Google shows — plus, on a client id that has
not been through verification, a warning interstitial — in front of **adding a
mail account**, over an action most accounts never take.

`AccountManager.hasFullMailAccess` / `requestFullMailAccess` are the pair,
shaped exactly like the cloud-drive ones: the stored token's `scope` **is** the
record of the grant (Google echoes granted scopes on the exchange and every
refresh), so there is no flag to fall out of step with it, and the
re-authorisation lands under the same per-account key with
`include_granted_scopes` carrying the mail scopes back.

Three things in the dialog:

- **It says Google will ask, before the destructive button**, rather than
  springing a browser on somebody who has just confirmed a delete.
- **It only says it when the scope is missing.** `hasFullMailAccess` is read
  ahead of the dialog, so an account that has already granted it sees the plain
  warning and no second step.
- **Declining empties nothing.** It is an answer, not an error — nothing has
  been deleted, and going on regardless would spend the whole listing to earn a
  403 per page. Graph and IMAP permanently delete under the scopes every account
  already holds, so none of this is on their path.

**A failure is now reported** (`EmailListActionFailure`, so it needs a
`sequence` like the move path), and the event carries the folder's display name
because the folder emptied is routinely not the one on screen — it is chosen
from the panel — so the state's own `currentFolderName` names the wrong one and
a raw `Label_12` names nothing. The panel's optimistic zeroed counts are left
to the next tree fetch: `FolderListFolderEmptied` does not register in
`_recentCountChanges`, so nothing re-applies them over the server's answer.

**The recovery fetch is re-checked after its await, not only before it.** A
failed empty re-fetches the folder so whatever the server still holds
reappears — a folder page, which on Gmail is a request per thread and takes
seconds. A user whose list has just blanked routinely clicks somewhere else
inside that window, and the emit that landed checked nothing: it painted the
emptied folder's mail into whichever folder was now on screen, and
`_serverOffset` with it. That is a list pane titled Inbox full of Spam, with
nothing but a manual refresh to take it away — no cache was poisoned, because
the fetch caches under the folder it asked for, which is why refreshing fixed
it.

