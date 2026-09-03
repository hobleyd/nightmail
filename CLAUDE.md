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

**A relay channel needs its handler on the main window too, not just the
sub-windows.** `calendar_refresh`/`drafts_refresh` broadcast one window's change
to every other engine, and the main window was given a handler-*less* channel on
the assumption that it only ever receives. But the **calendar pane lives in the
main window**, so cancelling or rescheduling there invokes `notifyEventSaved` on
that messenger: `MissingPluginException`, and the calendar sub-window was never
told. `drafts_refresh` got the same treatment for symmetry — compose is a
sub-window on desktop, so that invoke rarely comes from main, but a handler-less
relay channel is the bug either way.

The broadcast deliberately includes the originating channel (Windows has always
done this). The extra refetch is wasted work, not a loop — `eventSaved` triggers
`CalendarWeekNavigated`, which fetches and emits without notifying — and
excluding the origin would be a third behaviour to keep in step with the other
platforms.

The Dart callers are best-effort regardless: only macOS and Windows implement
these relays at all, so Linux, Android and iOS raise `MissingPluginException`
every time as a matter of course.

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

### Closing a sub-window is a request, not an act

`windowManager.close()` *posts* the close (Windows `SC_CLOSE`) and reports
success either way, so a dropped one leaves a window on screen that has already
turned its `setPreventClose` guard off — see `_close` in `compose_window.dart`,
which retries and puts the guard back. `destroy()` is never an option in a
sub-window: it is `PostQuitMessage`/`NSApp.terminate` and takes the app with it.

### Where a window opens

`WindowBoundsService` persists geometry per display; the main window and each
*kind* of sub-window get their own file (`WindowBoundsService.forWindowKind`).
Compose and event-edit are the sub-windows that record one — `main()` restores it
instead of centring on the parent's screen, and `_close` saves before closing
because the close tears the engine down and a debounced save would never fire.
Event-edit saves the width *without* its schedule pane (`_withoutSchedulePane`),
since the pane opens closed and the form column doesn't grow to fill the window.

Bounds are logical pixels at the window's *current* scale factor, so restoring
onto a monitor at another scale takes a second `setBounds` once Dart's ratio
catches up (`_settleBounds`), while the window is still hidden — or it opens in
the wrong place and visibly jumps.

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

## Nothing May Close the Cache Database

**`sqlite3_close_v2` is never called on `nightmail_cache.sqlite`.**
`AppDatabase._openConnection` passes drift a `setup` hook that calls
`Database.leak()` on every connection, which detaches the closing finalizer and
marks the connection borrowed. The process holds the handle until it exits.

Two generations of macOS crash reports are the same SIGSEGV in `sqlite3Close` on
a background `DartWorker` while quitting. The faulting instruction is `blr x8`
with `x8` = `sqlite3GlobalConfig.mutex.xMutexEnter` — NULL — while the handle
itself still passes `sqlite3SafetyCheckSickOrOk`. So the close was running
against a *mapping of libsqlite3 whose `sqlite3_initialize()` never ran*: the
crash log has `sqlite3.framework` mapped **twice**, two base addresses, one
UUID. Open through the initialised mapping, close through the other, and the
first mutex call dies. Same family as the sub-window FFI rule above — a native
resource outliving the isolate/mapping that set it up.

Both ways in had to be closed, which is why the fix is at *open* time:

- `package:sqlite3` attaches a `NativeFinalizer` whose callback **is**
  `sqlite3_close_v2`, and Dart fires native finalizers when an isolate group is
  torn down. That is the crash from before anything closed the database
  explicitly.
- Closing it explicitly at quit — the fix tried instead, and the reason
  `AppDelegate` holds `.terminateLater` over an `app_lifecycle` channel — only
  moved the same call earlier. That is the crash from after it.

`AppDatabase.close()` is still called at quit and still worth calling: it drains
in-flight queries and shuts the drift isolate down. It just stops short of
native sqlite3 now. An unclosed database at process exit is not data loss —
replaying an unclosed journal is the case SQLite is built for.

`test/data/database/leaked_sqlite_handle_test.dart` pins the two
`package:sqlite3` properties this rests on, because a version bump that changed
either would restore the crash silently.

**Prepared statements take the same route and are deliberately left alone.**
`package:sqlite3` attaches a second `NativeFinalizer` calling `sqlite3_finalize`
to every statement, and that opens with the same `sqlite3_mutex_enter(db->mutex)`
that dies here. Nothing is done about it because nothing has ever crashed there:
every report is `sqlite3Close`, including the whole pre-fix generation, when
statement finalizers were firing at every quit with nothing closing anything —
and `AppDatabase.close()` disposes drift's statement cache while the library is
still healthy. The gap left is the `.timeout(3 s)` in `_prepareForShutdown`,
where the close does not finish. A SIGSEGV in `sqlite3_finalize` at quit is that
gap, not a new bug.

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

## Gmail Sign-In Opens Chrome, Not Safari

On macOS, Gmail's OAuth flow **bypasses `flutter_web_auth_2`** and runs its own
loopback server (`LoopbackAuthFlow`, `infrastructure/auth/`), handing the
authorization URL to Chrome through a native channel
(`au.com.sharpblue.nightmail/browser_launcher`).

The plugin cannot be asked to do this. Its macOS implementation is the method
channel alone — `ASWebAuthenticationSession`, which always renders in Safari's
WebKit; `useWebview: false` is inert there because its Dart loopback server is
registered for Windows and Linux only. And that server calls `launchUrl`, i.e.
the *default* browser, so it could not be pointed at Chrome either. The point is
to land in the browser the user is already signed into Google with.

Four things here are load-bearing:

- **The redirect URI and the branch in `signIn()` must agree.** macOS is now in
  `_useLoopbackRedirect` (so Google is told `http://127.0.0.1:34572`) *and* in
  `_useOwnLoopback` (so the code waits on that port). Flipping only the first
  points Google at a socket nothing is listening on, and sign-in hangs silently
  until it times out rather than failing.
- **`NSWorkspace`, never `open -a "Google Chrome"`.** Release builds are
  sandboxed and the sandbox denies spawning a process while permitting
  LaunchServices, so the shell route works in debug and ships broken.
  `openInChrome` returns `false` rather than erroring when Chrome is absent, and
  `AuthBrowserLauncher` falls back to `launchUrl`.
- **`com.apple.security.network.server` in `Release.entitlements`** — the
  sandbox refuses the `HttpServer.bind` without it. Debug/profile are
  unsandboxed, so a passing `flutter run` proves nothing about this.
- **The port is closed in a `finally` and the app re-activated by hand.** An
  abandoned sign-in that left 34572 bound would fail every later attempt on
  "address already in use", and nothing brings the window back from Chrome
  otherwise — the plugin path got that from `WindowToFront`.

Which request on that port is the redirect is decided twice over. A request
carrying neither `code` nor `error` is answered 404 and ignored: the browser
asks for `/favicon.ico` off the back of the landing page, and completing on the
first request regardless resolves the flow with a URL carrying no authorization
code. A request carrying a `code` must also echo the `state` this flow minted,
or it is answered 400 and the sign-in fails — see below.

**Microsoft, Windows, Linux and Android are untouched.** Azure accepts the
`nightmail://` custom scheme for public clients, so macOS Microsoft sign-in still
goes through `ASWebAuthenticationSession`; Windows and Linux still use the
plugin's own loopback server and the default browser.

## Both OAuth Flows Send a `state`, and Refuse a Redirect Without It

`state` (RFC 6749 §10.12) is minted per sign-in in `signIn()`, carried in the
authorization URL and checked on the way back — `oauth_state.dart` holds both
halves, and both `GmailAuthService` and `MicrosoftAuthService` use it.

PKCE already stops a code somebody else injected from being *exchanged*: the
exchange carries this client's verifier and an injected code was issued against
a different challenge. What `state` adds is the step before that — a redirect
that did not come from the authorization URL this client opened is refused
rather than acted on, and in the loopback flow it is what decides which request
on the port *is* the redirect. Before it, anything that could reach
127.0.0.1:34572 during the window could resolve the flow with its own code.

Four things here are load-bearing:

- **A missing `state` is a failure, not a skipped check.** That is the whole of
  the bypass, and it is also what keeps the request side honest: leave `state`
  out of an authorization URL and the provider echoes nothing back, so the very
  first sign-in fails loudly rather than quietly losing the defence.
- **`LoopbackAuthFlow.authenticate` takes `expectedState` as a required named
  parameter.** A nullable one reinstates "absent means skip the check" at the
  call site.
- **A mismatch fails immediately rather than waiting for the real redirect.**
  Ignoring the request and carrying on would turn any genuine mismatch — a bug
  in this file, a provider quirk — into a five-minute silent hang, which is the
  failure mode this whole section otherwise exists to avoid. The attack traded
  away is somebody who can already reach the port cancelling a sign-in, which
  gains them nothing.
- **An `error` response is let through unchecked.** `state` protects the code;
  an error carries nothing to spend, and requiring one there would turn a
  legible `access_denied` into a mismatch message.

`signIn()` checks it on *every* path, not just the loopback one: neither
`flutter_web_auth_2`'s own loopback server (Windows/Linux), nor the
`nightmail://` intercept, nor the web popup does it for us — the plugin's
server resolves on the first request carrying a code, exactly as ours used to.
The value is a local in `signIn()` rather than a field: nothing serialises
sign-ins, and a redirect may only ever be checked against the state the flow it
belongs to sent. It is never derived from the PKCE verifier, which is the secret
half of PKCE and would end up in the URL and the browser's history.

On web the redirect lands on `callback.html`, which posts `window.location.href`
verbatim over the `BroadcastChannel`, so `state` arrives with the code — both
providers answer with a query (`response_mode: query` is explicit for Microsoft,
and the default for Google's `response_type=code`), and nothing in that path
rewrites the URL.

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
| Gmail | `gmail_message_parser.dart` | `parseGmailFullMessage`, `parseGmailThreads`, `parseGmailMetadataMessages`, `parseGmailForwardSource`, `parseGmailHistoryPages` |
| Microsoft | `graph_message_parser.dart` | `parseGraphFullMessage`, `parseGraphMessageCollection(s)`, `parseGraphDeltaPages` |
| IMAP | `ImapDatasourceImpl.parseFullImapMessage` | raw MIME in, `EmailModel` out |
| `.eml` | `eml_parser.dart` | `parseEmlBytes` — an attached or forwarded message |

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

## A Folder Listing Expands Its Threads Across Folders

Both providers return a thread's copies from *other* folders alongside the folder
page — that is what puts the Sent replies `EmailConversation.anchor` reads in
reach. Deleted Items/Junk (Graph `_expansionExcludedFolderIds`) and TRASH/SPAM
(Gmail `excludeLabels`) are excluded, or a deleted message comes back on every
refresh: a delete *moves* it, so it keeps its `conversationId` and gets a **new
id** the outbox's pending-op and tombstone reconciliation cannot recognise.

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

## An Attached Email Is Previewed In Place

A `message/rfc822` attachment — a forward, or a message somebody attached to
another — is drawn in the reading pane's own preview surface
(`_EmlPreview`/`_EmlBodyView` in `reading_pane.dart`), the same surface the PDF,
image and cloud-document previews use. `_AttachmentChip._previewKind` claims it
on `rfc822` in the content type or an `.eml` extension.

Four things here are load-bearing:

- **The parse goes through `compute()`, like every other message parser.**
  `EmlParser.parse` is `Uint8List` in, `Email` out — the same shape as
  `ImapDatasourceImpl.parseFullImapMessage` — and for the same reason: the MIME
  carries the body *and* every inline image as base64, so the decode is the
  expensive half and must not run on the UI isolate. Both callers
  (`_EmlPreviewState._load` and `EmailDetailBloc._onLoadedFromEml`) are already
  async, so this cost nothing at the call sites.
- **Inline images are collected by a direct tree walk, not `findContentInfo`.**
  That helper matches `Content-Disposition` *exactly*, so it answers neither the
  `inline` nor the `attachment` query for a part carrying a `Content-Id` and no
  disposition header at all — a very common shape. Disposition is the wrong
  signal twice over: Gmail tags pasted inline images `attachment` while still
  referencing them by `cid:`, and a forwarded Gmail message is the common case
  for an `.eml`. A Content-Id on a non-text part is what decides membership.
  Without this list every inline image drew as a broken glyph: `HtmlBodyView`
  resolves `cid:` tokens from `inlineAttachments` alone, and the reading pane's
  CSP is `img-src data: file:`, so an unresolved token is a reference the policy
  refuses as well as one nothing satisfies.
- **A nested `message/rfc822` is not descended into.** enough_mail hangs an
  encapsulated message's parts directly off the rfc822 part with no node in
  between, so the walk would pull a forward-inside-the-forward's images up into
  the list. They are referenced by *its* body, not the one being rendered, so
  that is megabytes of base64 spent on cid tokens nothing asks for.
- **The nested message's own attachments come through a bytes-provider seam.**
  A part inside a previewed `.eml` has no server-side id to download by, so
  `_AttachmentsSection`/`_AttachmentChip`/`_SaveAllButton` take an optional
  `bytesLoader` and use it in place of `sl<DownloadAttachment>()`. The choice is
  made on the loader being **non-null, never by inspecting the id** — a MIME
  path like `2` is a perfectly plausible provider id, and a heuristic there
  fails silently towards hitting the network with a garbage id.
- **Two attachments on one message routinely share a name**, so the scratch
  file each is written to is named from a directory keyed on the *attachment
  id* (`_scratchFile`), not from the name alone. Five `Undeliverable:` bounces
  off one send is the case that found this, and the second of the two bugs is
  the one that reads as nothing having happened: the preview is keyed
  `ValueKey(_previewPath)`, so an unchanged path reuses the existing State,
  `initState` never runs again, and picking a different attachment goes on
  showing the first. The discriminator is on the directory rather than the file
  so the name stays what the sender called it — the preview header shows it, and
  the mobile share sheet offers it as the name to save.

### A part inside a previewed `.eml` is addressed by its own MIME path

`EmlParser` numbers parts itself (`2`, `3.1`) rather than reading enough_mail's
`fetchId`, because that one **collapses**: `collectContentInfo` hands a child of
a `message/rfc822` part the *parent's* id instead of appending an index, so
every attachment inside a forwarded message ends up sharing one id. That is
`attachmentParseVersion` 2 in the cache — the chips look right and every one of
them fetches the same wrong bytes. `_collectAttachments` and
`extractEmlAttachmentBytes` run the *same* walk, so the path a chip carries and
the path its bytes are fetched by cannot drift.

Three more things here:

- **Ids are namespaced `<emlId>#<partId>`.** Two previewed messages both have a
  part `2`, and a bare path would collide in the reading pane's scratch
  directory (`_scratchFile` keys on the attachment id) and in the active-chip
  check. `emlPartIdOf` recovers the tail.
- **The walk does not descend into an encapsulated message.** That message is
  offered whole as its own `.eml`; descending would flatten its attachments into
  its parent's list, which is the shape the numbering exists to avoid. Nesting
  is not depth-limited — a bounce chain is a real thing, and each level is
  reached by previewing the level above.
- **Bytes are re-read and re-parsed on demand**, in an isolate, rather than held
  from the original parse. A previewed message is opened far more often than its
  attachments are, and keeping them resident would make every preview cost the
  size of the whole message.

`hasAttachments` is derived from the collected list rather than
`MimeMessage.hasAttachments()`, which matches on `Content-Disposition` and so
disagrees with the walk for a part named only by `Content-Type; name=` — a chip
on screen while the flag said there were none.

**`EmailDetailLoaded.emlSource` is the same seam for the other surface.** A
`.eml` opened from a task attachment renders through the *main* reading pane,
which has no file on disk to read parts back out of — so the raw bytes travel
with the state. Without it that path draws chips it cannot honour, which is
strictly worse than the empty list it used to draw. The bytes are kept out of
`props` (Equatable would deep-compare a whole message on every emit); the length
stands in.

**Save All de-duplicates names.** Five `Undeliverable:` bounces off one send all
have the same name, and every one of them used to be written to the same path —
four of the five silently lost behind a progress bar that counted all five.

### Outlook attaches an email as an `itemAttachment`, which is not a file

Graph answers "attach an email" with a `#microsoft.graph.itemAttachment`. It has
no `contentBytes` — that property is on the `fileAttachment` subtype — and its
`name` is the attached message's *subject*, so it arrives with no extension to
read a type off. Left alone it got no preview, no icon, and `downloadAttachment`
threw outright, so the chip could not be opened or saved either.

Two halves, and the split matters:

- `GraphApiDatasourceImpl.downloadAttachment` falls back to `/$value` when
  `contentBytes` is absent *or* empty, which serves the item as raw MIME.
  Reached **only where the old code threw**, so the fileAttachment path is
  untouched: an attachment that really has no content still fails, one round
  trip later.
- `EmailModel._isEmbeddedMessage` claims it on `@odata.type` containing
  `itemattachment` **or** a content type containing `rfc822`, and
  `_emlFileName` gives it a `<subject>.eml` name (capped at 120 characters,
  mirroring the IMAP path's `_forwardedMessageName`).

**`@odata.type` survives the `$select`, and `contentType` is `null`.** Verified
against a live tenant, on a message carrying five `Undeliverable:` bounces:

```json
{ "@odata.type": "#microsoft.graph.itemAttachment",
  "name": "Undeliverable: REQUEST FOR VOLUNTEERS",
  "contentType": null, "size": 35588, "isInline": false }
```

So the type annotation is the discriminator that works, and it arrives even
under `$expand=attachments($select=id,name,contentType,size,isInline)` — the
caveat about `$select` stripping it applies to `eventMessage` on a
single-resource GET, not to an expanded attachment collection.

**The match must not be widened to "no content type", even though every
itemAttachment shows one.** `null` there is not exclusive to attached mail, and
an attachment Graph merely declined to *type* would then be offered as an
email, parse to an empty one, and lose the open-externally behaviour that works
today. The annotation is exact; the absence of a content type is a guess.

Gmail and IMAP need none of this — Gmail names the part `<subject>.eml` with
`Content-Type: message/rfc822`, and IMAP's `_forwardedMessageName` already does
the same.

### The cache is why a fix here needs a stamp bump

The reading pane decides whether to offer a preview from the **cached**
`name`/`contentType`, and a full-bodied cached row short-circuits the network.
So the parse fix above changed nothing for any message already read: the chip
kept its pre-fix metadata and would never preview, however many times it was
reopened. `EmailLocalDatasourceImpl.attachmentParseVersion` is what forces the
one-time refetch — it went to **6** for this. Any future change to what
`_parseAttachments` produces needs the same, or it only ever applies to mail
that arrives afterwards.

## Graph Never Says Whether a Body Was Plain Text

`body.contentType` reports the format Graph *rendered*, not the one the sender
wrote, so it always echoes the request. `getEmail` therefore probes the
message's own `Content-Type` header alongside the main fetch
(`declaresPlainTextBody`); a plain-text message with an attachment is
`multipart/mixed` and still renders as HTML.

## The Reading Pane's CSP Goes First, or It Governs Nothing

`script-src 'none'` is the whole reason a mail body can be handed to a webview
that has script enabled (which the desktop ones do — mobile disables it
outright). **A `<meta>` policy only governs what is parsed after it**, so it was
spliced in before `</head>`, behind whatever the sender wrote — and a `<script>`
in the sender's own head had already run by then, with the page's bridge to the
host in reach.

`installContentSecurityPolicy` puts it at the very start of the document
instead. Three things about that position:

- **It cannot simply follow the literal `<head>`.** A `<script>` written
  *before* `<head>` is malformed and the parser hoists it into an implicit head,
  ahead of a policy placed inside the sender's head tag. Starting the document
  is the only position that covers both.
- **Behind a leading doctype, never in front of it.** Anything before the
  doctype makes the parser ignore it and lay the document out in quirks mode,
  which moves the tables in most of the mail people read.
- **Ahead of `<html>` is fine** — the parser hoists a leading meta into the
  implicit head, the same property `forceUtf8Charset` already relies on, and the
  charset prescan reads bytes rather than the tree.

**The injected styles stay at the end of the head.** They are `!important`
throughout, and at equal specificity the later `!important` wins, so hoisting
them with the policy would hand a sender's `img { width: 600px !important }` the
argument over the `max-width` clamp and the blocked-image chip. That is why the
policy is a separate splice rather than the first line of `injected`.

Host `evaluateJavaScript` is not subject to the page's policy, in either desktop
engine — which is how this is testable at all, and worth knowing before treating
a CSP as a limit on what the app itself can do to the document.

What is *in* the policy is the section above; `script-src 'none'` is only the
part of it that made a mail body inert.

## What Holds a Remote Image Back Is the Policy, Not the Rewrite

**`contentSecurityPolicy(allowExternal: …)` is the enforcement.**
`blockExternalImages` only decides what the reader *sees*. That division is the
point: an `<img src>` is one of at least eight ways a mail body reaches a
tracker, and element rewriting used to be the whole of the defence — so
`style="background:url(https://…)"`, a `<style>`'s `@import`, an `@font-face`, a
`srcset`, a `<picture><source>`, a `<video poster>`, a `<link rel=stylesheet>`,
an `<input type=image>`, a `<table background>` and an `<iframe>` all still
phoned home with blocking switched on. Measured, before the policy carried it:
**14 requests** from one body, in both desktop engines. Naming the schemes a
subresource may come from is one line and cannot be got round; rewriting each
route in turn is a parser written in regular expressions.

So `img-src`/`font-src`/`media-src` are `data: file:` while blocking, and gain
`https: http:` when the reader presses Download once / Always. `data:` is the
inline-attachment route and the substituted pixel, `file:` is the same
attachments once the document is written to disk. **Not `'self'`** — a `file:`
document's origin is opaque, so `'self'` matches nothing and would hold back the
message's own images.

Three directives never open, at either setting:

- `script-src`/`object-src` — a mail body has no business executing.
- `frame-src` — an `<iframe>` is a document this policy does not govern: it runs
  its own script under its own origin, and in WKWebView a subframe can reach the
  host's `messageHandlers` bridge. Both webmail providers strip iframes; this
  refuses to fetch them, which is the same answer with an empty box left behind.
  It stays refused after Download once, which is deliberate — the reader asked
  for the pictures, not for a third party's document.
- `base-uri` — a `<base href="https://…">` re-points every *relative* URL, and
  a file-delivered message's inline images are referenced relatively. That turns
  the sender's own attachments into a call home. Verified: it fires under the old
  policy and is refused under this one.

What `blockExternalImages` is still for:

- **A held-back `<img>` gets the pixel, not an empty `src`** — no `src` at all
  makes the engine draw its own broken glyph and the sender's `alt` over the
  placeholder. The `src` is *renamed* to `data-blocked-src` because the injected
  stylesheet keys the chip off it. Images declaring ≤3px either way are trackers
  and stay hidden (`data-blocked-spacer`).
- **`srcset` has to go with it.** A candidate list outranks `src`, so leaving one
  would mean a request the policy refuses and then the broken glyph the pixel
  exists to avoid. Same for a `<picture>`'s `<source>`, which is chosen ahead of
  the `<img>` inside it — held back, the fallback `<img>` applies, and that is
  the one already carrying the chip.
- **Reporting.** The status bar's "Download once" is offered off the returned
  flag, so a message whose only remote content is a CSS background has to count
  as blocked even though nothing was rewritten (`_remoteSubresource`). A
  background that never loads leaves nothing to draw, which is why the policy
  alone is enough for the rest.

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

## A Quoted Reply Is Somebody Else's Markup

The compose editor is a webview with **script enabled** and a method channel to
the host, and `ComposeBodyBuilder.buildInitialHtmlBody` loads the original
sender's HTML into it — `extractHtmlBodyContent` only slices out the `<body>`.
So the reading pane's answer (`script-src 'none'`) is not available here, and
`editor.innerHTML = html` was giving a sender a script context: `<script>` does
not run from an `innerHTML` assignment, but `<img src=x onerror=…>` and
`<svg onload=…>` do, which is enough to rewrite the message about to be sent
(`onContentChanged`), attach bytes of the sender's choosing (`onImagePasted`),
and on Android read app-private files.

`setContent` therefore sanitises, and it is the **one** route inbound HTML
takes into the document — a quoted reply or forward, a draft fetched from the
provider, a signature change all arrive there — which is why the sanitiser
belongs at that end rather than in `ComposeBodyBuilder`. Paste goes through the
same rules (`_sanitizeHtmlFragment`), which is where they used to live and all
they used to cover.

Four things in `assets/editor/editor.html` are load-bearing:

- **The parse is inert.** `DOMParser.parseFromString` builds a document that
  fetches nothing and fires nothing. Assigning to a *detached* element's
  `innerHTML` — the shape the paste-only sanitiser used — is not inert: the
  image load starts there, and only the attribute stripping happening in the
  same task keeps `onerror` from firing.
- **Nothing is re-parsed after being cleaned.** `setContent` adopts the cleaned
  nodes (`importNode`) instead of serialising them back to a string, because
  that second parse is the mutation-XSS class: `svg`, `math` and `noscript`
  switch the parser's namespace, so a payload can survive
  serialise-then-reparse as something else. The paste path cannot avoid the
  string — `execCommand('insertHTML')` takes one — which is why those elements
  are dropped outright rather than stripped of handlers.
- **`data:` is refused outside an image.** Inline images in a quote arrive as
  `data:` URLs that `resolveCidImages` builds out of the attachment's own
  `Content-Type` — the sender's choice — so `data:text/html` is reachable from
  a crafted message.
- **The CSP caps a bypass; it cannot stop script.** The page needs its own
  inline `<script>`, so `script-src` has to allow inline and the policy's real
  work is `connect-src 'none'` (script that did run cannot send anything off
  the machine) plus `object-src`/`frame-src`/`base-uri`/`form-action`. Dropping
  `default-src 'none'`'s companion `script-src 'unsafe-inline'` stops the
  editor loading at all. `img-src` must keep `data:` and `http(s):`, or quoted
  images vanish.

`style` attributes are deliberately kept — they are most of a quoted body's
formatting, and this app's own quote wrapper is a styled `<blockquote>`.

**The Android WebView's `allowFileAccessFromFileURLs` /
`allowUniversalAccessFromFileURLs` must stay off** (`HtmlViewPlugin.kt`). Both
default to false and both were on, which gave the editor — loaded from
`file:///android_asset`, the one document here that runs script — the run of
app-private storage and a same-origin channel to every other origin.
`allowFileAccess` stays **on**: the reading pane loads its document from a real
file when a message has inline images.

`test/presentation/widgets/editor_html_sanitization_test.dart` pins the shape of
all of this, since the behaviour itself only exists inside a real engine.

## A mailto: Link Is Answered Here, Not by the OS

Every body link goes to `launchUrl` except `mailto:`, which `openBodyLink`
(`presentation/widgets/body_link_opener.dart`) sends to
`ComposeWindowApp.openMailto` — the same entry point the OS uses when another
app hands NightMail a `mailto:` URI. `bcc=` is dropped: nothing downstream
carries a BCC list.

## A Cloud Document Link Is Previewed, Not Followed

A SharePoint/OneDrive or Google Drive link in a body is an attachment in all but
name, so `openBodyLink` fetches it and draws it in the reading pane's preview
surface — the same one the attachment chips use — instead of handing it to a
browser that would ask the reader to sign in to a second thing to read their own
mail. Everything else still goes to `launchUrl`.

**Which mailbox the mail arrived in says nothing about who holds the file.** A
OneDrive link turns up in Gmail and a Drive link in Exchange as a matter of
course, so the provider is read off the *URL* (`CloudDocumentLink.provider`) and
`CloudDriveRepositoryImpl` then picks an account signed in to *that* service,
active account first, trying each in turn — two tenants, and only one of them
was shared the file.

Five things here are load-bearing:

- **The scanner is biased towards not matching.** A false positive is the
  expensive mistake: a SharePoint *site* link or a Drive *folder* link opens
  fine in a browser today, and claiming it replaces that with a spinner and an
  apology. So `/:f:/`, `/_layouts/`, `.aspx`, `/Lists/`, site roots,
  `/drive/folders/`, `/forms/` and published `/d/e/` documents are excluded by
  name, consumer OneDrive (`1drv.ms`, `onedrive.live.com`) is deliberately not
  claimed at all, and anything unrecognised falls through unchanged.
- **The file scopes are requested incrementally, never at sign-in.** Neither
  `Files.Read.All` nor `drive.readonly` may go in `_scopes`: an authorization
  request naming a scope nobody has consented to fails *outright* — Microsoft
  AADSTS65001 where a tenant reserves `Files.Read.All` for admin consent, and
  Google treats `drive.readonly` as a restricted scope — so the casualty would
  be **adding a mail account**, over a feature that account may never use. Same
  reasoning as `GmailAuthService._roomDirectoryScope`, one step further.
  `AccountManager.requestCloudDriveAccess` runs the flow that asks, on a prompt,
  when a reader first follows a cloud link. `Sites.Read.All` is not requested
  either: the sharing-link route does not need it, and it is the scope most
  likely to need an administrator.
- **The granted scope lives on the token, and a Microsoft refresh must re-ask
  for it.** Both providers echo granted scopes back on every token and refresh
  response, so `AuthToken.scope` *is* the record of the grant and there is no
  flag to fall out of step with it (`grantsFileAccess`). But a Microsoft refresh
  names the scopes it wants: refreshing with the base list alone would hand back
  a token *without* file access an hour after the grant, which would read as the
  permission lapsing. `_refreshScopes` adds it back only when the token proves
  it was consented to — asking for an unconsented scope fails the refresh.
  Google's refresh takes no scope, but its authorization request needs
  `include_granted_scopes=true`, or the flow comes back holding Drive access
  *instead of* the mail scopes.
- **A pre-authenticated URL must not carry an `Authorization` header.** Graph
  answers `/driveItem/content` with a 302 to a short-lived signed blob URL that
  refuses a request carrying credentials as well ("only one authentication
  mechanism allowed"), so `GraphDriveDatasourceImpl` sets
  `followRedirects: false` and fetches the `Location` with a *separate,
  interceptor-free* Dio. Reusing the Graph client — whose `AuthInterceptor` adds
  the header to everything it sees — is exactly the failure.
- **Falling back is the normal case, not the error path.**
  `CloudDocumentPreviewHost.onPreview` returning false means "open it in the
  browser after all", and covers no account, a declined permission, a file type
  that cannot be drawn, a document too large, and mobile (whose preview
  surfaces are the desktop native webview). Only a *server or network* failure
  says anything on screen; the rest just behave as the link did before. The
  standalone email window publishes no host at all, which is why a link there
  still opens in the browser.

Office formats come back as a **server-rendered PDF** (Graph
`content?format=pdf`, Drive `files/{id}/export?mimeType=application/pdf`):
higher fidelity than the bundled JS viewer and it needs no LibreOffice on the
machine. `OfficePreviewService` is the fallback, for the one case the providers
will not convert — an *uploaded* Office file in Drive, which needs write access
to copy-and-export. Google editor files have no bytes of their own and are only
ever an export, capped at 10 MB by Google. `CloudDocument.convertedToPdf` is
what tells the preview to treat a document titled `.docx` as the PDF it now is;
`cloudDocumentFormatFor` (`core/utils/cloud_document_format.dart`) is the one
rule both the datasources and the pane read, so a file is never downloaded and
*then* found to be unpreviewable.

**The preview bar's title is the way back to the file.** Drawing the document
here is *instead of* the browser tab the reader clicked, so the header
(`_PreviewHeader`) carries the source URL and opens it externally on a tap —
otherwise previewing a document would be the one thing that took away the
ability to comment on it, edit it or share it on. It calls `launchUrl`
directly rather than `openBodyLink`: the header is drawn **inside** the
`CloudDocumentPreviewHost` the pane publishes, so going through the opener
would match the link, find that host, and fetch the document again instead of
leaving the app. `_previewSourceUrl` is assigned on every `_showPreview`,
including the attachment paths that pass none — a preview opened after a cloud
document would otherwise inherit its link and offer the wrong file. The title
underlines only under the pointer, so an `open_in_new` icon beside the close
button carries the same tap: a reader who never hovers the exact text would
otherwise never learn the link is there.

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
  carries into `folderIds` — `UNREAD`, `IMPORTANT`, `CATEGORY_PERSONAL` among
  them — and a Graph folder id means nothing to a reader. Anything that does not
  resolve against `FolderListBloc`'s tree is skipped, and a row with nothing
  left to resolve gets no brackets rather than a `Label_123`. Resolving against
  the tree is what drops the non-folder labels, for free.
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

Failures are reported on `lastPollAt`/`lastPollErrors`, including the
offline skip. A silent `catch (_)` here is how a deterministic failure came to
look like a quiet mailbox for the life of an install.

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

## The Overdue-Tasks Badge

The red dot on the folder panel's Tasks icon counts `scheduled_task_reminders`
rows (`OverdueTasksCubit`), not `TasksBloc` — the bloc holds one list of one
account, and `TaskReminderService` already walks every list on a 15-min cycle.
`isTaskOverdue` (`core/utils/task_due.dart`) is the shared rule, so the dot and
the pane's red due line can't disagree.

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

## In-App Updates

Two mechanisms behind one status, because no single one covers the platforms.

| Platform | Mechanism | Where it comes from |
|---|---|---|
| macOS, Windows | `desktop_updater` — download, verify, stage, hand to a native installer | signed `app-archive.json` on GitHub Pages |
| Android | APK handed to the system package installer | newest GitHub release's `.apk` asset |
| Linux | none — the snap self-updates | |
| iOS, web | none | |

`AppUpdateService` (`infrastructure/update/`) is the only place that knows
which; everything above it reads one `AppUpdateStatus`. `UpdateCubit` is the
bloc-shaped window onto it, the same shape as `OverdueTasksCubit` over
`TaskReminderService`.

**Linux is excluded deliberately, not overlooked.** The Linux build ships as a
snap and there is no Linux entry in the app-archive, so a controller there would
sit in a permanent no-update state while snapd did the actual work.

Checking is automatic — at launch and every 6 h after, since a mail client is
left open for days and a launch-only check would mean never. **Only the check
is.** Nothing downloads or installs without the user pressing the button, which
is what lets the timer be quiet and unattended. It skips a cycle once an update
has been found: there is nothing further to learn until the user acts, and
re-checking would clear and re-set the status the dot is drawn from.

### The service starts at launch, not when Settings opens

`../inkworm` — which this is modelled on — builds its `DesktopUpdaterController`
inside the About widget's `initState`. NightMail cannot: the dot on the folder
panel's Settings icon has to appear before the user has gone looking. So the
service is a singleton started from `HomePage.build` (`UpdateCubit.start()`) and
the About panel *attaches* to a status that is already being published.

That has a consequence worth knowing: **Settings opens as its own route**, so
`HomePage`'s provider subtree is out of scope inside it and every cubit its
sections read is re-provided by hand in `SettingsDialog.open`'s `wrap()`.
Registering `UpdateCubit` only under `HomePage` gets the dot and then throws
`ProviderNotFoundException` the moment About is opened. Both the desktop dialog
and the mobile page go through `wrap()`, so one entry covers both. `UpdateCubit`
and `AppUpdateService` are `registerLazySingleton` for the same reason — the dot
and the panel must be reading the same status.

**Main window only.** `AppWindow.isMain` gates the whole service. `desktop_updater`
is a plain method-channel plugin, so this is *not* the fatal `NativeCallable`
hazard above — the reason is the recovery marker: a second engine would run its
own `recoverPendingInstall()` over the same file and could start a second native
install handoff concurrently with the first. In a sub-window the status is
`unsupported` and every action is a no-op.

### The dot means "there is something to press"

`AppUpdateStatus.hasActionableUpdate` — `available`, `freshInstallRequired` or
`readyToInstall`. A download already running does **not** light it: the user has
acted, and a dot beside a progress bar reads as a second, separate thing still
wanting attention.

**`freshInstallRequired` is a separate phase for a reason.** A release marked
fresh-install-only cannot be staged, and `DesktopUpdaterController.downloadUpdate()`
*throws* outright in that state — so folding it into `available` gives the About
panel a "Download update" button that reliably fails. It gets its own phase and
its own button (`openFreshInstallDownload()`), which is the only action the
controller supports there. `UpdateBlockedBySupportPolicy` is the opposite case and
does map onto `available`: the controller accepts a download there, treating it as
mandatory.

### Release notes are generated, not GitHub's

`generate_release_notes: true` builds its body out of *merged pull requests*, and
this repo pushes straight to `main` — so that body comes back empty (inkworm's
does). The commit subjects are strictly conventional, which is the structure the
notes want, so `tool/release_notes.dart` groups the subjects between the previous
version tag and this one into `desktop_updater`'s rich release-notes schema and
the deploy job publishes it as `release-notes.json`.

`chore`, `docs`, `ci`, `build`, `style` and `test` never reach it: a release-notes
list is what changed *for the user*, and a version bump is not that. A breaking
`!` is lifted out of its type into its own leading section.

**Both platforms read that one document**, fetched by the app itself rather than
through `desktop_updater`'s own release-notes machinery — which only works while
the controller holds an active descriptor, so it yields nothing on Android and
nothing on a machine that is already up to date. The notes are wanted in both
cases, since the file always describes the newest published release: with an
update pending it is what you are about to get, without one it is what you have.
Nothing about them is signature-verified, and needn't be — they are text shown to
a human. What gets *installed* is chosen from the signed archive and descriptor.

**The document carries every release, not just the newest.** The top level is
the newest one, in `desktop_updater`'s schema exactly as before, plus a
`previous` array of the same shape for the releases before it (capped at 20 —
a reader wants the versions they skipped, not the history of the app). The
panel draws every release published since the running build
(`releaseNotesToShow`), so skipping two versions shows what changed in each
rather than only in the one being installed. Both directions degrade: a reader
that does not know `previous` still shows the top-level release, and a document
published before the key existed parses to a one-entry list.

**When nothing is newer it falls back to the newest release, never to nothing.**
The document describes the newest published release either way — with an update
pending it is what you are about to get, without one it is what you have — so an
empty block would take "What's new" off the panel for everyone who is current.
The same fallback covers an installed version that will not parse, and a release
that names no version is left out of a filtered list rather than guessed at.

Build metadata does not affect the ordering, which is what lets `1.22.3+157` be
compared against a release named `1.22.3` without the reader being offered their
own build.

**The history is regenerated from tags on every deploy**, not accumulated onto
the previously published document: there is one source of truth, and a lost
`release-notes.json` rebuilds complete. It is therefore not an immutable record
— `EndBug/latest-tag` *moves* a tag, so a push at an unchanged pubspec version
extends that version's range after its notes were first published, and the later
regeneration covers more commits than what shipped at the time. More complete,
not wrong.

**They are re-read on every check, not once per process.** "The newest published
release" is a moving target, so the first answer goes stale the moment one is
published — and a mail client is left open for days. Holding it left a
long-running app showing the notes for the release it was already on beside a
status line offering a newer one: "Version 1.22.4 is available" over "What's new
in 1.22.3". A check is a network round trip to the archive already, and this is
one small document beside it. A failed re-read changes nothing, leaving whatever
was on screen.

### Trust

`tool/setup_updater.sh` does the whole out-of-repo half of this — keypair,
secrets, `gh-pages`, Pages — and is safe to re-run; `--check` reports the state
without changing anything.

`kTrustedReleasePublicKeys` in `app_update_service.dart` pins the Ed25519 public
key from `desktop_updater.keys.json`. That pin is the whole of the update chain's
security: an attacker who serves a different archive from the same URL cannot
sign it. The public profile is committed; the private bundle lives in the local
key store and, base64'd, in the `DESKTOP_UPDATER_KEY_BUNDLE_B64` GitHub secret.
`*.dukey` is gitignored so an exported bundle cannot be committed by accident.

**Rotating the key means changing both** the profile and the constant, in the
same release — a build pinning only the new key cannot verify an archive still
signed by the old one. `setup_updater.sh` refuses to go on when the two have
drifted, and `--force` re-issues the secrets after a rotation.

### The Build Number Is the Whole of the Desktop Comparison

**`desktop_updater` decides "newer" on the build number alone.** When both the
candidate and the running app have one — and they always do; every archive item
carries one and macOS reads `CFBundleVersion` back — `compareDesktopVersions`
returns on that comparison and **never reaches the semver**
(`lib/src/version_info.dart`). So build numbers have to rise monotonically
across the entire published archive, forever: `1.20.0+145` beats `1.22.3+22`,
and the client would offer the older release as an upgrade.

That counter is `pubspec.yaml`'s `+BUILD`, read by the `prepare` job and passed
to `flutter build --build-number` (which is what sets `CFBundleVersion`), to
`desktop_updater:package` and to `app_archive upsert`. It used to be
`github.run_number`, which is an unrelated sequence: a locally built app carried
pubspec's `+21` while the archive carried the run counter's `+155`, so the app
reported "Version 1.22.2 is available" against its own 1.22.2 — the same code,
built twice, under two counters. `pubspec.yaml` jumps past the run numbers the
old scheme had already published, or an install carrying one of those would
never be offered another release. **Never move the counter down**,
and never let a fresh start lose it: a build number below what is published
silently serves an old release as the newest one.

A missing or non-numeric `+BUILD` fails the `prepare` job rather than defaulting
to 0, which would publish a release every install compares as older than what it
already has.

**Desktop and Android now agree: bumping `pubspec.yaml` is what publishes an
update.** Android gets there differently — it compares the GitHub tag, which the
workflow strips to the semver part (`1.20.0`, not `1.20.0+17`) and
`EndBug/latest-tag` *moves*. So on both, a re-push at an unchanged pubspec
version publishes no update: the archive `upsert` replaces the same
platform/channel/version/build slot and gh-pages overwrites that release's zip
and descriptor together, leaving clients on that build correctly seeing nothing.
Same as inkworm; not a bug.

### What the About Panel Reports

**The controller has no "up to date" state.** A check that finds nothing newer
leaves `desktop_updater` on `UpdateIdle` — the same state it holds before
anything has been checked — so only the typed result of `checkForUpdates()`
(`ManualUpdateCheckUpToDate`) says a check finished with nothing to offer.
`desktopStatusFor` therefore reports *no change* for `UpdateIdle` rather than a
phase, and `_checkDesktop` emits `AppUpdatePhase.upToDate` off that result.
Mapping idle onto `checking` instead is what left "Checking for updates…"
spinning forever for anyone whose installed build was level with the archive —
which is every install running the newest published build, so the desktop path
could never report being up to date at all.

**A waiting release is named `1.22.3+157`, not `1.22.3`**
(`formatReleaseVersion`). The About panel prints the installed version as
`version+build`, so naming the available one by its semver alone left the two
lines comparing different things — the complaint that surfaced all of this was
"Version 1.22.2 is available" against an installed "1.22.2+21". The build number
is also the whole of the comparison, so on a same-semver release it is the only
part that explains why an update is being offered. Android is the exception and
reports the semver alone: it compares the GitHub tag, which the workflow strips
to its semver part, so there is no build number to report.

### Where the Android APK Goes

The APK goes to the app's own cache directory, which is the only path
`res/xml/file_paths.xml` grants the `FileProvider` — so `REQUEST_INSTALL_PACKAGES`
is the only permission involved and no storage permission is needed.

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
