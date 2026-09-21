# NightMail — macOS Native Layer

Native-channel and TCC-permission details specific to the macOS build. See the [root guide](../CLAUDE.md) for architecture-wide rules, and [Desktop Sub-Windows & FFI Isolation](../lib/core/platform/CLAUDE.md) for the multi-window/FFI hazard this build shares with Windows.

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

## The Editor Webview Sits Above Flutter's Surface by zPosition, Not by Luck

`html_view`'s WKWebView (`packages/html_view/macos/Classes/WebKitView.swift`)
is a plain subview of the engine's `FlutterView`, and `FlutterView` paints
through a `CALayer` that `FlutterSurfaceManager` adds to the view's own layer
on the first frame it commits. Both end up as sibling sublayers of
`FlutterView.layer`, both at zPosition 0 — so whichever is added *later* is
drawn on top.

That order used to be decided by timing. The reading pane and a new-email
editor are created long after their window's first frame, so the webview
always landed on top. A **reply** mounts `HtmlEmailEditor` in the compose
sub-window's first build: `createView` runs while the first frame is still
being rasterised, and when Flutter's surface layer arrived second it covered
the webview. The page loaded, `setContent` ran, the DOM reported itself
visible with the right size — and the user saw the window background where
the toolbar and body should be, intermittently, only for replies, and only
in normal use (a debug run with probes attached happened to win the race).

Measured with a native probe in the compose sub-window:
`FlutterView.layer.sublayers == [CALayer z=0 (Flutter), WEBVIEW z=0]`.

The webview's layer now gets `zPosition = 1000`, above Flutter's surfaces
(`zIndex` 0, and small integers when platform views are present). Being above
Flutter is the intended relationship: Flutter content that must appear over
the webview — a `ModalRoute`, a typeahead dropdown, a hover card — already
asks for it to be hidden through `HtmlViewOverlayGuard` /
`HtmlViewWidget._applyVisibility`, because on Windows the WebView2 HWND is
always on top and the same rule was needed there.

Two things worth knowing before touching this:

- **`webView.layer` is only safe to address once `wantsLayer` is true** and the
  view is in the hierarchy it is ordered within, hence the placement right
  after `addSubview`.
- **Do not "fix" the order by re-adding the subview.** `FlutterSurfaceManager`
  removes and re-adds its layers whenever the surface count changes, so any
  insertion-order remedy is the same race again. zPosition is what Core
  Animation actually sorts by.

`test/presentation/widgets/editor_layer_order_test.dart` pins the line.

## macOS Privacy Permissions (TCC)

### Contacts

The contacts channel is implemented natively in `MainFlutterWindow.swift`
(`au.com.sharpblue.nightmail/contacts`). Do **not** use the `flutter_contacts`
package — its SPM artifacts do not link into the app bundle reliably.

**`com.apple.security.personal-information.addressbook` must not be in
*either* entitlements file now.** It is a sandbox-only entitlement, and on a
non-sandboxed build it causes `CNError.authorizationDenied` (code 100) without
ever showing a dialog. It used to live in `Release.entitlements` because that
file enabled the sandbox; **it no longer does** — see
[The App Is Not Sandboxed](#the-app-is-not-sandboxed) below — so the entitlement
went with it, and the same is true of
`com.apple.security.personal-information.calendars`.

Contacts and Calendar access now rest on the Info.plist usage strings alone:
`NSContactsUsageDescription`, and `NSCalendarsFullAccessUsageDescription` for
the EventKit channel, which calls `requestFullAccessToEvents` — TCC terminates
an app that asks without the matching string.

## The App Is Not Sandboxed

`Release.entitlements` sets `com.apple.security.app-sandbox` to **false**, and
`DebugProfile.entitlements` never enabled it. Both configurations are therefore
the same shape, which is worth knowing when a permission behaves differently
between them — it is no longer the sandbox that differs.

The reason is the in-app updater, which cannot work inside a sandbox at all:
`spctl` and `xcrun` fail there (the first with *"internal error in Code Signing
subsystem"*), and `SMAppService.daemon` cannot be registered. The full account is
in [../lib/infrastructure/update/CLAUDE.md](../lib/infrastructure/update/CLAUDE.md).

Two things survived the sandbox going away and are still load-bearing:

- **`keychain-access-groups`**, and the Developer ID provisioning profile the
  release workflow embeds so it can be claimed. Every account, OAuth token and
  IMAP password lives in the Keychain under that group.
- **Everything else the app writes moved** to `~/.nightmail` — see
  [../lib/core/platform/CLAUDE.md](../lib/core/platform/CLAUDE.md).

`flutter clean` after changing any of this. Entitlement and signing changes do
not reliably invalidate the incremental build.

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

