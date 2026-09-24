# Calendar Infrastructure

Meeting invites, RSVPs, the offline-first calendar cache, room booking, and Google's organizer/guest-notification quirks. See [../../../CLAUDE.md](../../../CLAUDE.md) for architecture-wide rules and [../notifications/CLAUDE.md](../notifications/CLAUDE.md) for how reminders are scheduled from this data.

## An ICS METHOD Decides Which Meeting Banner Appears

`icsInviteType` (`data/datasources/remote/ics_meeting_invite.dart`) maps
REQUEST/CANCEL/COUNTER/REPLY/PUBLISH onto `MeetingEmailType`: a REPLY draws no
banner and a PUBLISH offers only "Add to calendar". Graph classifies from its own
`meetingMessageType` and only consults an attached ICS when it did not — every
other banner's action is addressed to the message id, which needs a real
`eventMessage`.

An `invite.ics` on a message Exchange never processed into a meeting is a file,
not an invitation: a REQUEST there is reclassified as a published event
(`unprocessedRequest`) so it gets the one banner that needs no `eventMessage`.

## Forwarding Somebody Else's Meeting

Offered on the invite banner and in the read-only event form. The provider is
asked first (Graph `/events/{id}/forward`; Google adds the guest, which it
allows when `guestsCanInviteOthers` is on) so the recipient joins the
*organizer's* meeting; only `MeetingForwardUnsupportedException` — a settled
"no" — falls back to emailing a `METHOD:REQUEST` from this account, since a 500
may have forwarded it already and would invite them twice. The two outcomes are
not equivalent, so `MeetingForwardMode` is returned and the dialog says which.

## Answering a Gmail Invitation Never Creates an Event

`GoogleCalendarDatasourceImpl.respondToMeetingInvite` used to fall back to
`POST /calendars/primary/events` — the whole ICS roster, `sendUpdates: 'all'` —
whenever it could not find the meeting to RSVP to. That event is organized by
**this** account, so Google mailed everybody on the invitation "Invitation:
<title>" for a meeting they were already in, and since `IcsParser` reads no
`RRULE` what they were invited to was a single occurrence of what had been a
series. Accepting a recurring meeting sent a new one.

The lookup it depended on is `events.list?iCalUID=`, an exact string match, and
a recurring invitation is exactly what it misses: the ICS carries the series'
bare UID while Google files an expanded instance under
`<masterUid>_<instanceStart>@google.com` — the mangling `_uidKey`
(`core/utils/meeting_conflicts.dart`) already documents for the conflict check.
An invitation on a calendar set to add invitations only once they are answered
is not listed at all without `showHiddenInvitations`.

Four things now hold this together:

- **Nothing on the RSVP path creates an event.** A meeting that cannot be found
  throws, the same as `GraphApiDatasourceImpl.respondToMeetingInvite` does after
  its own three lookups. Making the create "safe" instead — no attendees, or
  `sendUpdates: 'none'` — was rejected: a copy with no attendees never delivers
  the RSVP to the organizer and still cannot carry the recurrence, which trades
  a loud wrong answer for a quiet one.
- **A missed UID falls back to the meeting's start time**, `_findInviteEvent` —
  the shape Graph uses as its last resort and `_findCachedMeeting` uses locally.
  A UID match within the window wins (normalised through `isSameMeetingUid`, so
  the instance suffix and domain do not matter); failing that, a *single*
  unambiguous event this account was invited to and does not organize. Two
  candidates finds nothing and the caller reports it — answering the wrong
  meeting is worse than answering none.
- **Declining takes that fallback only for an occurrence**
  (`allowStartTimeMatch: event.recurrenceId != null`). A decline answers *and*
  deletes; what it can remove off a heuristic match is therefore held to one
  occurrence, since a series invitation would be promoted to its master and
  "remove a recurring series" may not sit behind a guess. Not finding the
  meeting stays the silent no-op it has always been on that path — there is
  nothing to remove.
- **A master id that 404s retries the instance.** Editing a series as "this and
  following" splits it, and the instances after the split name a master
  `<id>_R<UTC occurrence start>` that an attendee's calendar holds no copy of
  when the split happened on the organizer's — the same 404 the recurrence
  lookup works around (`_recurrenceByMaster`). Reporting it instead would fail
  an RSVP that the instance would have accepted.
- **What the RSVP is addressed to turns on `RECURRENCE-ID`** (`_sendRsvp`).
  An invitation carrying one is about a *single occurrence* — "Updated
  invitation: Go/No-Go Fortnightly @ Thu 17 Sept" — and Google keeps a modified
  occurrence as its own resource with its own roster, so an answer sent to the
  series master never reaches it: the occurrence stays on `needsAction`, which
  `_parseStatus` draws as **tentative**. That is an accept that visibly does not
  take. A series invitation is the other way round and goes to the master
  (`recurringEventId`), or every occurrence but one is left unanswered.
  `IcsParser` parses `RECURRENCE-ID` for this and nothing else.
- **The roster PATCHed is the server's, with only this account's entry
  changed.** Building it from the ICS — which is what both the accept and the
  decline path did — hands Google a guest list that may differ from the one on
  the event, and `sendUpdates: 'all'` then delivers every difference to
  everybody as an invitation or a cancellation. An RSVP may only ever change the
  answer this account is giving. The rosters come off the same `events.list`
  response the lookup already made, so this costs no extra round trip.

**The not-found failure carries a 404**, which is the calendar outbox's drop
signal (`OutboxDrainService` treats 404/410 as "no retry can ever succeed").
That is what this is: an RSVP only reaches the queue when
`_findCachedMeeting` found a *cached* copy to answer optimistically, so the
provider not holding one is settled rather than propagation lag. Left untyped it
would be retried 25 times and then dropped just as quietly.

Graph needs none of this: every one of its paths posts `accept`/`decline` to a
message or event id, and it has never had anything that could create.

`test/data/datasources/remote/google_calendar_rsvp_test.dart` pins it — chiefly
that an accept whose lookups come up empty issues **no** POST.

## Answering an Invitation Deletes the Ones It Supersedes

A rescheduled or otherwise updated meeting arrives as a fresh invitation each
time, and the reading pane deleted only the one that was answered — every
earlier "Invitation:" for the same meeting stayed in the Inbox, still offering
Accept. After an RSVP, a counter-proposal or a processed cancellation, the pane
now runs `DeleteSupersededMeetingInvites` (`domain/usecases/`) against the
answered message's folder and drops what it removed from the list
(`EmailListGhostRemoved` — the use case has already deleted through the
repository, so the row is all that is left to remove).

Three things here are load-bearing:

- **Gmail does not thread an update with its original.** Checked against a
  real mailbox: an "Updated invitation: …" is a one-message thread of its own,
  so matching on `conversationId` finds nothing there. The ICS `UID` is the
  test where both messages carry one, normalised through `isSameMeetingUid`
  because Google files an instance under `<uid>_<start>@google.com`. Graph's
  event messages carry no ICS, so there — and only there — the conversation
  decides, which Exchange does keep per meeting.
- **A list row does not know its invite.** `meetingInvite` lives in the detail
  row with the body (`_detailJson`), because a thin list fetch has no ICS and
  must not overwrite one. So candidates are narrowed on list fields first —
  older, physically in the folder (`Email.isInFolder`), and in the same
  conversation or from the same sender — and each survivor is read through
  `getEmail`, cache-first, capped at `maxCandidates`. The cap is what stops a
  prolific organizer turning one Accept into a folder-wide fetch.
- **Only `MeetingEmailType.invitation` is ever removed, and only older ones.**
  A cancellation or a reply in the same thread is a different message with its
  own banner. Answering an older invitation while a newer one is unread deletes
  nothing: the newer one is the one that still wants an answer.

It runs after the answered message's own delete, so that delete is first in the
outbox behind the RSVP (see below on drain order), and a failure anywhere in it
is swallowed — the RSVP succeeded, and housekeeping may not say otherwise.

## Proposing a New Time Is the Event Form, Not a Dialog

"Propose New Time…" on a calendar tile, and dragging somebody else's meeting
to another slot, both open the **event form** in counter-proposal mode
(`EventEditForm.proposeNewTime`): the meeting is read-only apart from its
date and time, the guests' availability rows and the schedule grid are shown,
and the footer sends the proposal with an optional message to the organizer.
They used to open two small pickers-only dialogs in `calendar_page.dart`, which
could not answer the only question worth asking before proposing — is anyone
free then? Those are gone; do not bring them back.

Two consequences of where the form runs:

- **The proposal goes through `EventEditBloc`, not `CalendarBloc`.** On the
  desktop the form is its own window with its own engine, which has no
  `CalendarBloc` to dispatch to. `EventEditProposeSubmitted` calls the
  `ProposeNewTime` use case and emits `EventEditProposed`; both hosts treat
  that like `EventEditSaved` (notify the other windows, close), since a
  proposal declines this account's copy until the organizer answers.
- **The organizer is added to the availability roster by the form**
  (`_availabilityRoster`). Graph keeps the organizer out of `attendees`, and
  theirs is the one calendar a counter-proposal most has to suit, so
  `organizerEmail` travels in the sub-window's arguments for this.

An organizer dragging their *own* meeting opens the same form in ordinary
edit mode, pre-filled with the drop slot, for the same reason — Save then
sends the update. Only an appointment with no guests still moves directly
(`CalendarEventRescheduleRequested`); there is nobody to check. The form's
change-detection snapshot is taken from the meeting's *stored* slot, not the
one it opened on, or a dragged save would read as unchanged and notify nobody.

## Calendar Cache

The calendar is offline-first: it paints from `cached_calendar_events` and then
repaints from the provider. `CalendarCacheSyncService` keeps **today through four
weeks ahead** warm for every account and expires anything that finished more than
a **fortnight** ago. It runs in the **main window only** (started from
`HomePage.build`); the calendar sub-window reads the same SQLite file and writes
back whichever week it fetches.

Mutations go **cache first, then queue, then send** — the reverse of the mail
outbox, which enqueues before touching the cache. The asymmetry is deliberate: a
calendar row is entirely re-derived from the provider by every sync pass, so a
crash between the local write and the enqueue heals itself; mail read-state has
no such authority to fall back on.

Three things here are load-bearing:

- **A fetch is reconciled against the queue before it is cached or returned**
  (`CalendarPendingOpReconciler`). A mutation and the refresh that follows it go
  out together, so the response routinely predates the queued op reaching the
  provider. Writing it back un-reconciled is exactly what makes a just-declined
  meeting flick back to unanswered. Same role as
  `EmailRepositoryImpl._reconcileAgainstPendingOps`.
- **`OutboxDrainService` drains the calendar queue first.** An RSVP or a
  remove-from-calendar is addressed to the *invitation email's* id (Graph
  resolves `/messages/{id}/accept` itself; the others read the `UID` from that
  message's ICS), and the reading pane deletes the invitation as soon as it is
  answered. Draining mail first would delete the message the calendar op needs.
- **Not every mutation is queued.** Anything that emails other people
  (`proposeNewTimeFromEmail`, `acceptProposedTimeFromEmail`) stays network-first,
  because a blind retry would send the same proposal twice; `createCalendarEvent`
  stays network-first because the cache row needs the provider's id;
  `cancelMeetingFromEmail` carries no ICS, so there is no `UID` to find the
  cached copy by. See `PendingCalendarOperationType` for the full list.

Locating the cached copy of a meeting from an invitation uses the ICS `UID`
first, then falls back to an *unambiguous* start-time match (Microsoft
invitations carry no calendar part). Two meetings at the same instant are left
alone and the caller waits for the provider — moving the wrong meeting is worse
than being slow.

## Room Booking

The event form's Location field is a room picker as well as a text box
(`room_location_field.dart`). Booked rooms are chips; anything typed alongside
them stays free text.

**Selecting a room invites it.** A room is a mailbox (Exchange) or a resource
calendar (Google) with a booking policy, and only the invitation triggers that
policy — naming a room in `location` reserves nothing. So rooms travel as
`roomEmails` on Create/UpdateCalendarEventParams, apart from `attendeeEmails`,
and each datasource sends them as *resource* attendees (Graph `type: resource`,
Google `resource: true`). `CalendarEventAttendee.isResource` carries that back.

Because the two lists are sent differently, anything that rebuilds an event from
its own attendees has to split them apart again. `CalendarBloc`'s
drag-to-reschedule is the one that bites: sending a room back as a person
attendee silently unbooks it.

**Free/busy needs no new permission.** Graph `getSchedule` and Google `freeBusy`
answer for rooms exactly as for people, so the picker's dots come from
`CheckAttendeesAvailability` with `organizerEmail: null` — no organizer, because
a room's dot needs a status, not a list of what it is booked for. The room being
edited is excluded from its own clash the same way its guests are.

Listing rooms is where the providers diverge, and both paths degrade rather than
fail — an empty dropdown must never block saving an event:

| Provider | Primary | Fallback |
|---|---|---|
| Microsoft | `/places/microsoft.graph.room` (`Place.Read.All`) — capacity, building, floor | `beta/me/findRooms` — names and addresses only, covered by the calendar scopes already held |
| Google | Admin SDK `resources.calendars.list` | `calendarList` filtered to `@resource.calendar.google.com` — only rooms the user subscribed to |
| IMAP / CalDAV / EventKit | none — the field is plain text | |

Three things here are load-bearing:

- **The Google Admin SDK scope is requested per account, never unconditionally.**
  Google rejects the *whole* authorization request with `invalid_scope` when an
  `admin.directory.*` scope is asked for on a personal @gmail.com account, so
  putting it in `GmailAuthService._scopes` would break adding one at all. It is
  appended only when the account's domain is already known not to be a consumer
  one (`scopesForAccount`), which means: **adding** a Gmail account never
  requests it and falls back to `calendarList`; **re-authenticating** a Workspace
  account from Settings does. `login_hint` pins the flow to that account so a
  browser session cannot land the admin scope on a personal one. The endpoint is
  admin-only regardless, so a non-admin Workspace user 403s and takes the same
  fallback.
- **The dropdown never hits the network for the room list.** `getMeetingRooms`
  is memoised per account in `CalendarRepositoryImpl` for the process' lifetime
  (a room directory changes on the timescale of an office fit-out) and filtered
  in memory. The *future* is cached, not just the result, so two forms opening at
  once make one request; a failure is not cached. Free/busy is the deliberate
  exception, since it depends on the slot.
- **Only the visible rooms get a free/busy lookup.** The picker reports what it
  is showing via `onVisibleRoomsChanged`, capped at 12 rows, and answers are
  memoised per slot and cleared when the meeting moves. A tenant with hundreds of
  rooms would otherwise turn one keystroke into hundreds of lookups.
  `getAttendeesSchedule` also chunks (20 for Graph, 50 for Google), because a
  room batch is far longer than any guest roster.

`location` and `attendees` are now sent on **every** create and update, empty
included. An omitted field on a PATCH means "leave unchanged", so releasing the
last room or clearing a location would otherwise silently not take effect.

Reopening a meeting splits its roster back apart and strips the room names out of
the provider's `location` string (`_stripRoomNames`), or the room would be shown
— and saved — twice, once as a chip and once as typed-in text.

### A join link is not a place

`CalendarEvent` keeps them in **separate fields**: `location` is where you go,
`onlineMeetingUrl` is what you click. A meeting routinely has both — a room for
the people in the building and a Meet for the ones dialling in.

They used to be one field. Both parsers handed the provider's join URL up *as*
the location, so it overwrote whatever the user had typed, and everything that
asked "is this joinable" tested `location.startsWith('https://')`. That made
composing anything in front of it destructive: prefixing a room name onto a Meet
URL left a location that no longer started with `https://`, so **adding a room to
an online meeting silently took the Join Meeting item, the tile's join chip and
`_isJoinable` away**.

Everything that decides joinability now reads `CalendarEvent.hasOnlineMeeting`.

`core/utils/online_meeting_url.dart` holds the three pieces:

- `splitMeetingLocation` — what every parser runs its raw location through. The
  provider's own field wins (Graph `onlineMeeting.joinUrl`, Google
  `conferenceData`); failing that **a location that is itself a join URL is
  treated as one**, which is how events saved under the old convention — on the
  server *and* in the local cache — stay joinable without a migration pass. A
  location that is a join URL is never echoed back as a location, or it would
  land straight back in the form's location box and be saved as a place again.
- `isOnlineMeetingUrl` — the predicate, also used by both event body builders so
  a join URL is never composed into a location string.
- `onlineMeetingPlatformName` — "Microsoft Teams" / "Google Meet" / "Zoom", shown
  wherever the URL itself would be meaningless noise (the hover card's own row,
  the event form's join line).

**Google must send `conferenceDataVersion=1` on every create and update**, not
only when attaching a Meet. Version 0 declares that the client has no conference
support and Google then omits `conferenceData` from the *response* — and since
the cache is rewritten from that response, editing anything about a Meet meeting
made its join link disappear from the app until the next full sync.

**The online-meeting toggle is locked on a meeting that already has one.**
`isOnlineMeeting` on the save params means *attach one*, not *should have one*:
asking again is not idempotent, because Google answers a second `createRequest`
by minting a new conference and stranding everyone holding the old link. So the
form initialises the toggle from `hasOnlineMeeting`, sends the flag only on a
false→true transition, and disables the control otherwise rather than offering a
removal neither provider supports here.

### Two Flutter traps in the picker

Both of these broke "open an existing meeting and add a room", and neither shows
up when testing with a new meeting, whose Location field starts empty:

- **`OverlayPortalController.show()` flips `isShowing` but only materialises the
  overlay child if the portal's own subtree rebuilds in that frame.** Typing gets
  that for free — the controller notifies the TextField — so the recipient
  typeahead has never needed to care. A *button* press does not, so opening the
  dropdown from inside a tap handler leaves `isShowing == true` with nothing on
  screen. `_openBrowse` defers its refresh to a post-frame callback for exactly
  this reason.
- **`TextEditingController` notifies on selection changes, not just text
  changes.** Focusing the field or moving the caret fires the same listener as a
  keystroke. The browse button focuses the field, so its "browse" mode was being
  cancelled by its own focus request one microtask later. `_lastText` gates the
  listener on the text having actually changed.

The field's text is also the room query, so an existing location would poison the
search ("Level 3 kitchen" + "board" matches nothing). Two things resolve that: the
browse button ignores the text entirely, and the search retries on the last word
when the whole field matches nothing. `_queryUsed` records which of the two was
used, so selecting a room removes only the query and leaves the rest of the
location — clearing the whole field would delete what the user typed.

## Google Leaves the Organizer Out of the Guest List

`events.insert` sets `organizer` from the calendar posted to and takes
`attendees` **verbatim** — unlike Google's own web UI, which adds the organizer
to the guest list of every event it creates (`organizer: true`, `self: true`,
`responseStatus: 'accepted'` — visible on any event in a real calendar).

Every guest list on both sides is drawn from `attendees` alone. So an organizer
missing from it is missing from their own meeting *everywhere*: from the
invitation, from the list of who has accepted, and from this app —
`_parseEvent` has always noted that Google "inconsistently omits the organizer
from `attendees`", and this was the half of that we caused.
`GoogleCalendarDatasourceImpl` therefore sends the organizer itself
(`_buildEventBody`), which is what `_accountEmail` is for. Graph needs none of
this; Microsoft adds the organizer server-side.

Three things are load-bearing:

- **`responseStatus: 'accepted'` is explicit.** The default is `needsAction`,
  which lands in `_parseEvent`'s `selfStatus` and feeds
  `_parseStatus(selfResponseStatus:)` — so your own meetings would stop counting
  as busy for conflict detection. `organizer` and `self` are output-only and
  left to Google. The self entry *replaces* one the caller passed rather than
  being skipped when present: a roster read back off the server now contains
  the organizer, which is exactly what `CalendarBloc`'s drag-to-reschedule
  rebuilds `attendeeEmails` from, and letting that through the guest loop would
  send it bare and un-busy a meeting by dragging it.
- **Only when somebody else is invited.** An event with no guests and no rooms
  stays attendee-less, or every private appointment becomes a one-guest meeting
  — and `_parseEvent` calls out the empty-`attendees` case as the common shape
  for a self-created or recurring event.
- **Sent on the update too, and the form does not show it.** An omitted field on
  a PATCH means "leave unchanged", but the roster is always sent whole (same
  reason as `location`), so leaving it off an update would drop the organizer
  back out. The edit form's Guests field means *who I am inviting*, so
  `event_edit_dialog` strips the user's own address out of the chips on a
  meeting they organize — the datasource re-adds it regardless, and a chip that
  comes back however often it is removed reads as broken. A guest looking at
  somebody else's meeting still sees themselves in the list they were shown.

**A create also has to ask for the invitations to be sent.** Google's default
is `sendUpdates=false`, and `createCalendarEvent` was sending nothing: guests on
Google Calendar were still written silently onto their own calendars, so the
meeting looked like it had gone out and people could even accept it — but nobody
was emailed an invitation, and a guest who is not a Google user got nothing at
all. `updateCalendarEvent` had always mapped `notifyScope` onto it;
`CreateCalendarEventParams` carries no scope because a create always notifies
everyone, which is what `_computeNotifyScope` returns for one.

## Google Cannot Tell Only the Changed Guests, So the App Does

`sendUpdates` on a Google event PATCH is `all`, `externalOnly` or `none`, and
`all` re-emails **every** existing guest even when the attendee list is the only
thing that changed — adding one person to a meeting used to send the whole
roster an "Updated invitation". Graph scopes this natively; Google's web UI does
it through an endpoint the API does not expose.

So a `MeetingNotifyScope.changedAttendeesOnly` save on a provider whose
`notifiesChangedAttendeesItself` is false (only Google) takes a different path
in `CalendarRepositoryImpl.updateCalendarEvent`
(`_updateNotifyingChangedGuests`): fetch the provider's copy, diff its roster
against the save, PATCH with `sendUpdates=none`, then email a `METHOD:REQUEST`
to each guest added and a `METHOD:CANCEL` to each guest removed, from this
account. The same `buildRequestIcs` the forward fallback uses, plus
`buildCancelIcs`.

Five things here are load-bearing:

- **The diff is against the server's roster, not the form's snapshot.** The
  server is the authority on who was invited, and it is what makes a repeat
  harmless: once the PATCH has landed the diff is empty, so pressing Save again
  after a failed send emails nobody twice. The organizer's own address is
  excluded from both sides — Google lists them in `attendees` because
  `_buildEventBody` puts them there, and the form never shows them, so they
  would otherwise read as removed by every save.
- **It is network-first, not queued.** Same rule as `proposeNewTimeFromEmail`:
  an op that emails people cannot be replayed blindly. The cache is written
  from the PATCH response *before* any mail goes out, so a failed send still
  leaves the saved meeting on screen; the failure says the meeting was saved
  and names the guest that was not told.
- **`SEQUENCE` is the provider's, which is why `CalendarEvent.sequence` exists.**
  Google's own emails to a guest carry its `sequence`; a CANCEL claiming a lower
  one is discarded as stale by the guest's client, a REQUEST claiming a higher
  one makes the organizer's next real update look stale. It is parsed from
  Google (in both field masks), cached, and null for every other provider.
- **A single occurrence of a series is left to Google to notify — everyone.**
  An invitation to one occurrence needs a `RECURRENCE-ID` naming it, and
  neither the event nor the params holds the original start to build one from;
  without it the guest's client files the invitation against the whole series.
  That is the one case `changedAttendeesOnly` still reaches
  `GoogleCalendarDatasourceImpl.updateCalendarEvent`, where it maps to `all`.
- **The CANCEL lists only the removed guests.** RFC 5546 §3.2.5 uses exactly
  that shape for "attendee removed"; naming the remaining guests would withdraw
  *their* meeting.

A Google-hosted guest already has the meeting on their calendar by the time the
email arrives — the silent PATCH put it there — so for them the REQUEST is the
notification and Gmail's RSVP goes through Google as usual. For anyone else it
is the invitation itself, and their reply reaches the organizer as an iMIP
`REPLY`, which is how Google-organized meetings have always heard back from
Outlook. The Meet link travels in the `DESCRIPTION` and the message body; there
is no conference-URL property every client reads.

