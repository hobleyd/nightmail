# NightMail — Claude Code Guide

## Architecture

Clean Architecture, 4 layers. Never bypass layers.

```
core/       — Failure, UseCase, Exception types
domain/     — Entities, Repository interfaces, Use cases
data/       — Models, Datasources, Repository impls
presentation/ — BLoCs/Cubits, Pages, Widgets
```

- DI via `get_it` (`sl<T>()` in `injection_container.dart`)
- Error handling: `fpdart` `Either<Failure, T>` (not `dartz`)
- State: `flutter_bloc`
- Bundle IDs: always `au.com.sharpblue` prefix (never `com.sharpblue`)
- An `AuthException` from a token refresh means "replace these credentials": it
  flags the account for re-auth and makes `AuthBloc` discard the token. Offline
  is a `NetworkException` — see `infrastructure/auth/token_refresh_error.dart`

## Building

```bash
flutter pub get
flutter build macos --debug
flutter run
```

Always `flutter clean` after changing entitlements or code signing settings.

## macOS Native Channels

Custom platform channels live in `macos/Runner/MainFlutterWindow.swift`.

**Critical rule: store every `FlutterMethodChannel` as an instance property.**
`FlutterMethodChannel` unregisters its handler in `dealloc`. A local variable is
released when the function returns → `MissingPluginException` on every call.

```swift
// WRONG — channel is released when awakeFromNib() returns
let ch = FlutterMethodChannel(name: "...", binaryMessenger: messenger)
ch.setMethodCallHandler { ... }

// CORRECT — stored property keeps the channel alive
private var myChannel: FlutterMethodChannel?
myChannel = FlutterMethodChannel(name: "...", binaryMessenger: messenger)
myChannel?.setMethodCallHandler { ... }
```

**`desktop_multi_window` creates a separate `FlutterEngine` per window.**
Register every channel on the main window AND inside `setOnWindowCreatedCallback`
so secondary windows (e.g. the compose window) can reach the handler:

```swift
registerMyChannel(messenger: flutterViewController.engine.binaryMessenger)

FlutterMultiWindowPlugin.setOnWindowCreatedCallback { [weak self] controller in
    RegisterGeneratedPlugins(registry: controller)
    self?.registerMyChannel(messenger: controller.engine.binaryMessenger)
}
```

Use an array to retain all channel instances:
```swift
private var allChannels: [FlutterMethodChannel] = []
```

## Sub-Windows and FFI Plugins

**Critical rule: an FFI plugin may only be initialized in the main window.**

`desktop_multi_window` re-enters `main()` with a fresh `FlutterEngine` for every
sub-window, so each one gets its own isolate, service locator and statics.
FFI plugins hand the native side a `NativeCallable` trampoline **owned by the
isolate that registered it**. When a sub-window closes, its isolate dies and the
trampoline is deleted — but the native library keeps the pointer. The next time
native code fires it, the VM aborts:

```
error: Callback invoked after it has been deleted.
isolate_group=(nil), isolate=(nil)
Lost connection to device.
```

That is a **`FATAL` in the VM, not a Dart exception** — no `try`/`catch` can
contain it, and it kills the whole process including the main window. Note the
`isolate=(nil)`: the callback ran on a native thread with no owning isolate,
which is the signature of this bug. Nothing in the Dart stack will point at the
plugin, and the symbolized frame is usually meaningless
(`InternalFlutterGpu_Texture_AsImage` or similar nearest-symbol noise).

Check `windows/flutter/generated_plugins.cmake` for what is affected —
`FLUTTER_FFI_PLUGIN_LIST` is the list of plugins with this hazard.
`flutter_local_notifications_windows` is the live one; it never disposes its
`NativeCallable` and the app never calls its `dispose()`.

`AppWindow.isMain` (`lib/core/platform/window_utils.dart`) is how code tells
which engine it is in. It is set from `main()` **before**
`configureDependencies()`, because lazy singletons decide at construction time
whether they may touch process-wide native resources.

### How the notification plugin applies the rule

`NotificationService._plugin` returns null outside the main window, so every
call through it is a no-op — including `initialize`, so the `NativeCallable` is
never registered in a sub-window at all. Beware that the plugin is easy to
reach by accident: `NotificationService` self-initializes in its constructor and
is pulled in transitively by `CalendarBloc`, `TasksBloc` and `EventEditBloc`, so
merely opening the Calendar, Tasks or Event-Edit window used to be enough.

Reminders are not lost. `CalendarReminderService`/`TaskReminderService` run in
the main window only (started from `HomePage.build`), reconcile every account's
events against the persisted schedule tables, and are the authority for what the
OS actually holds. Sub-windows nudge them via `ReminderReconcileChannel` (a
`unidirectional` `WindowMethodChannel` — the app's only cross-window channel)
so a change applies at once instead of waiting up to 15 min for the next cycle.
`reconcileAll()` therefore coalesces rather than drops a request that lands
mid-cycle. Because the reconcilers re-derive state by *fetching* the account,
anything that nudges must commit to the server first.

macOS is exempt: its notifications go through a bespoke
`UNUserNotificationCenter` method channel that is process-wide and works from
any engine, so sub-windows there schedule directly.

**Known remaining hole:** hot restart replaces the root isolate, deleting the
main window's trampoline while the native plugin created by the old isolate
lives on — the same fatal abort, debug builds only. Upstream limitation; if you
hit this crash in `flutter run` and no sub-window was involved, that is why.

## macOS Privacy Permissions (TCC)

### Contacts

The contacts channel is implemented natively in `MainFlutterWindow.swift`
(`au.com.sharpblue.nightmail/contacts`). Do **not** use the `flutter_contacts`
package — its SPM artifacts do not link into the app bundle reliably.

**Do not add `com.apple.security.personal-information.addressbook` to
`DebugProfile.entitlements`.** This entitlement is for sandboxed apps only.
On a non-sandboxed debug build it causes `CNError.authorizationDenied` (code 100)
without ever showing a dialog.

The entitlement belongs only in `Release.entitlements` (which enables the sandbox).

### TCC permission dialogs require real code signing

For macOS TCC to show a permission dialog the binary must have a real **Team ID**.
Ad-hoc signing (`CODE_SIGN_IDENTITY = "-"`) produces `TeamIdentifier=not set`
and TCC auto-denies all requests silently.

Checklist to get a working Team ID in debug builds:
1. Install the **Apple WWDR G3** intermediate certificate (the G1 expired 2023):
   ```bash
   curl -O https://www.apple.com/certificateauthority/AppleWWDRCAG3.cer
   open AppleWWDRCAG3.cer
   ```
2. Create an Apple Development certificate in **Xcode → Settings → Accounts →
   Manage Certificates → + → Apple Development**.
3. Verify: `security find-identity -v -p codesigning` should show 1 valid identity.
4. Remove `CODE_SIGN_IDENTITY = "-"` from the **project-level** Debug
   `XCBuildConfiguration` in `Runner.xcodeproj/project.pbxproj` (xcconfig
   overrides don't work — project-level settings win over xcconfig).
5. Verify after build: `codesign -d --verbose=4 NightMail.app | grep TeamIdentifier`
   should show your team ID, not "not set".

### Testing TCC permissions

**Launch via Finder or `open`, not `flutter run`.**

`flutter run` uses an intermediate launcher process that can confuse macOS 15's TCC
into returning `authorizationDenied` even when the app is correctly signed and the
status is `notDetermined`. Running the `.app` directly bypasses this:

```bash
open build/macos/Build/Products/Debug/NightMail.app
```

If the permission dialog has been denied and won't appear again:
```bash
sudo tccutil reset Contacts          # reset all apps (no bundle ID needed)
# or
sudo tccutil reset Contacts au.com.sharpblue.nightmail
```

Use `sudo` — system-level TCC entries require it. Without `sudo`, `tccutil reset`
may silently fail.

### Use the completion-handler form of `requestAccess`

On macOS 15 the `async/await` form of `CNContactStore.requestAccess(for:)` throws
`CNError.authorizationDenied` for `notDetermined` apps. The completion-handler form
works correctly:

```swift
store.requestAccess(for: .contacts) { granted, error in
    DispatchQueue.main.async { result(granted ? "granted" : "denied") }
}
```

## AI Subsystem

The AI slice (compose reply, provider catalog, inference) introduces two
deliberate deviations from the repo's default Clean-Architecture conventions.
They are intentional — do not "fix" them back to the default shape.

### Streaming repositories return `Stream<Either<Failure, AiChunk>>`

`AiInferenceRepository.stream(...)` returns `Stream<Either<Failure, AiChunk>>`
(`lib/domain/repositories/ai_inference_repository.dart`) rather than the usual
`Future<Either<Failure, T>>`. This is a deliberate new repo shape for streaming:
each emitted item is an `Either`, so a mid-stream failure surfaces as a `Left`
on the stream instead of throwing. Single-shot AI repo methods keep the normal
`Future<Either<Failure, T>>` form. Future streaming repos should follow this
same `Stream<Either<Failure, T>>` shape.

### AI wire adapters return `Either<Failure, T>` directly

Unlike the catalog datasources (which throw `ServerException`/`NetworkException`
for the repository to convert), the inference wire adapters
(`lib/data/datasources/ai/inference/ai_adapter.dart` and impls) return
`Either<Failure, T>` directly rather than throwing. This is intentional:
streaming forces it — you cannot "throw then convert in the repo" across an
async stream, so the adapter must emit `Left(failure)` inline. For consistency
the single-shot adapter path returns `Either` the same way rather than mixing
throw-and-convert with emit-`Left` in one class.

## Message Parsing Runs Off the UI Isolate

**Parsing a fetched message never happens on the UI isolate.** Each provider
hands the **undecoded** response body to `compute()`:

| Provider | Parser | Entry points |
|---|---|---|
| Gmail | `gmail_message_parser.dart` | `parseGmailFullMessage`, `parseGmailThreads`, `parseGmailMetadataMessages`, `parseGmailForwardSource` |
| Microsoft | `graph_message_parser.dart` | `parseGraphFullMessage`, `parseGraphMessageCollection(s)`, `parseGraphDeltaPages` |
| IMAP | `ImapDatasourceImpl.parseFullImapMessage` | raw MIME in, `EmailModel` out |

Three things here look incidental and are not:

- **`ResponseType.plain` is load-bearing.** `jsonDecode` is a large share of the
  cost — a `format=full` Gmail message and a Graph message both carry the body
  and every inline image as base64 inside the JSON. Letting Dio decode the
  response puts that half back on the UI isolate no matter what the parser does.
  This mirrors the contacts fetchers; same reason.
- **One `compute()` per batch, not per message.** Each call spawns an isolate, so
  a 25-thread page parsed one call at a time pays isolate setup 25 times and
  loses most of the gain. List paths fetch concurrently, then parse once.
- **A parser cannot make a network call, so it reports what it could not
  finish.** `GmailFullMessage` carries `icsAttachmentId` and `pendingInline`;
  `GraphFullMessage` carries `pendingInlineAttachmentIds`. The alternative —
  decoding the response again on the UI isolate just to find them — is the thing
  being avoided. Merge fetched extras by *rebuilding* the model, not re-parsing.

Deliberate exceptions:

- IMAP **list** rows (`ENVELOPE`/`BODYSTRUCTURE`, no `BODY[]`) parse inline.
  There is no raw source to reconstruct a `MimeMessage` from, and without a body
  there is nothing expensive to decode. Only `getEmail` (which fetches `BODY[]`)
  moves, via `renderMessage()`/`parseFromText` — a documented round-trip.
  `uid` and the `\Seen` flag come from the FETCH, not the MIME, so they travel
  beside the source text.
- Reply/forward MIME **building** stays on the calling isolate: `MessageBuilder`
  needs the original as a live `MimeMessage`, and these are user-initiated
  one-offs rather than the polling path.

Mockito cannot tell `get<Map>` from `get<String>` — a Dart `Invocation` does not
carry the type argument, so the stubs collide and the last one registered wins.
That is why the whole Gmail message path uses one response type (the thread and
search *indexes* are plain too, decoded locally since they are only ids), and why
these tests stub `get<String>` with `jsonEncode`d bodies.

## Graph Never Says Whether a Body Was Plain Text

`body.contentType` reports the format Graph *rendered*, not the one the sender
wrote, so it always echoes the request. `getEmail` therefore probes the
message's own `Content-Type` header alongside the main fetch
(`declaresPlainTextBody`); a plain-text message with an attachment is
`multipart/mixed` and still renders as HTML.

## Bare URLs in a Message Body

A URL a sender typed as text is turned into a real link at render time
(`core/utils/linkify.dart`). Both body renderers use it and each needs its own
half, because they have nothing else in common:

- **HTML** — `linkifyHtml` writes `<a href>` into the document `HtmlBodyView`
  hands the webview. That is the whole reason it happens there rather than at
  parse time: link hover reporting, click-to-open-externally and copy-link are
  already wired to anchors in the page, so a linkified URL picks up all three
  for free. It is a *scanner*, not a parse — the body is about to be handed over
  as text, so re-serialising a DOM would risk changing far more than the links —
  and it runs before the `cid:` substitution so it scans the sender's body
  rather than the same body with every inline image expanded into it. Text
  inside `<a>`, `<script>`, `<style>`, `<title>` and comments is left alone;
  nesting an anchor loses the outer link.
- **Plain text** — `PlainTextBodyView` builds spans, and uses `SelectionArea` +
  `Text.rich` rather than `SelectableText.rich`: `SelectableText` renders through
  `RenderEditable`, which never dispatches to a span's `recognizer`, so the links
  would look right and do nothing. It carries its own `BodyStatusBar` so hover
  offers copy-link in the same place the webview path does.

The fiddly part is not matching `https://` but deciding where the URL *ends* —
the full stop after `.../timesheets.` closed the sentence, the `)` closed the aside
(unless the URL's own brackets are unbalanced), and in HTML an escaped `&nbsp;`
or `&gt;` is made of URL-legal characters, so it ends the URL wherever it
appears rather than only at the tail. `&amp;` is deliberately not a boundary —
that is how a query string's own separators arrive.

Only `http`/`https` and `www.`-prefixed hosts are linked. Guessing at bare
`example.com/x` turns file names and version numbers into links. Email
addresses and `mailto:` URLs are linked too, but the last label must be
alphabetic, or `package@1.2.3` becomes a way to mail somebody.

## A mailto: Link Is Answered Here, Not by the OS

Every body link goes to `launchUrl` except `mailto:`, which `openBodyLink`
(`presentation/widgets/body_link_opener.dart`) sends to
`ComposeWindowApp.openMailto` — the same entry point the OS uses when another
app hands NightMail a `mailto:` URI. `bcc=` is dropped: nothing downstream
carries a BCC list.

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

## Which Folder an Account Switch Lands On

`HomePage`'s `AccountCubit` listener owns the whole switch — it files the
outgoing folder under the account being left (`_accountShowing`) and drops the
selection; `folderToAutoSelect` restores it when the new folder list *lands*, so
the saved id is checked against real folders and falls back to the Inbox.
Nothing may select a folder at switch time: that listener clears it a beat
later, which is what made the old restore in `folder_panel.dart` a no-op.

## An ICS METHOD Decides Which Meeting Banner Appears

`icsInviteType` (`data/datasources/remote/ics_meeting_invite.dart`) maps
REQUEST/CANCEL/COUNTER/REPLY/PUBLISH onto `MeetingEmailType`: a REPLY draws no
banner and a PUBLISH offers only "Add to calendar". Graph classifies from its own
`meetingMessageType` and consults an attached ICS **only** for PUBLISH — every
other banner's action is addressed to the message id, which needs a real
`eventMessage`.

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
