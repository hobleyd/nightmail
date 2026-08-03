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
