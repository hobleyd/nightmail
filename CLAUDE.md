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

### flutter_inappwebview macOS patch (beta.3 + Xcode 16+)

`flutter_inappwebview_macos 1.2.0-beta.3` ships a `Package.swift` declaring
`.macOS("10.14")` but references `ASWebAuthenticationSession` (10.15 only), which
causes a compile error on Xcode 16+. The fix is a one-line patch in the pub cache:

```bash
# File: ~/.pub-cache/hosted/pub.dev/flutter_inappwebview_macos-1.2.0-beta.3/
#       macos/flutter_inappwebview_macos/Package.swift
# Change: .macOS("10.14") → .macOS("10.15")
sed -i '' 's/\.macOS("10.14")/.macOS("10.15")/' \
  ~/.pub-cache/hosted/pub.dev/flutter_inappwebview_macos-1.2.0-beta.3/macos/flutter_inappwebview_macos/Package.swift
```

Re-apply after `flutter pub cache repair`. Drop when 6.2.0 stable ships.

### desktop_drop Android patch (compileSdk 33 + androidx.fragment 1.7.1)

`desktop_drop 0.4.4` sets `compileSdk 33` but `androidx.fragment:fragment:1.7.1`
requires `compileSdk 34+`. The fix is a one-line patch in the pub cache:

```bash
# File: ~/.pub-cache/hosted/pub.dev/desktop_drop-0.4.4/android/build.gradle
# Change: compileSdk 33 → compileSdk 36
sed -i '' 's/compileSdk 33/compileSdk 36/' \
  ~/.pub-cache/hosted/pub.dev/desktop_drop-0.4.4/android/build.gradle
```

Re-apply after `flutter pub cache repair`. Drop when desktop_drop publishes a fix.

## Linux WebView

Linux uses `flutter_inappwebview` (WPE WebKit / `wpewebkit-1.0` ABI), the same plugin
as macOS and Windows. Ubuntu 24.04 does not ship WPEWebKit in its repos, so we build
it ourselves and publish it to a custom APT repo.

### Custom WPE WebKit PPA

Source: `../wpe-webkit-linux` (GitHub: hobleyd/wpe-webkit-linux)
APT repo: `http://wpe-webkit-linux.sharpblue.com.au/apt`
GPG key: `http://wpe-webkit-linux.sharpblue.com.au/wpe-webkit-linux.gpg`

The PPA provides `libwpewebkit-1.0-dev` built from WPEWebKit 2.42.x against glibc 2.39.
The critical build flag is `-D_FORTIFY_SOURCE=2` (Ubuntu 24.04's GCC defaults to
`FORTIFY_SOURCE=3`, which introduces glibc 2.42 symbol deps incompatible with the
Ubuntu 24.04 snap base).

CI installs from this PPA before building. `libWPEWebKit-1.0.so.3` and
`libWPEBackend-fdo*.so*` are bundled into the snap since they are not in Ubuntu's
default repos.

### flutter_inappwebview_linux CMakeLists patches

Two patches are applied in CI after `flutter pub get`:

1. **Library name**: `flutter_inappwebview_linux 0.1.0-beta.1` hardcodes
   `find_and_add_library("libWPEWebKit-2.0"...)` but with the `wpewebkit-1.0` ABI the
   library is `libWPEWebKit-1.0.so.3`. The patch derives the name dynamically from
   the pkg-config result instead.

2. **GCC compat**: `-Wno-deprecated-literal-operator` is Clang-only. GCC rejects it
   with a fatal error. The patch wraps it in `check_cxx_compiler_flag()`.

Both patches are applied via a Python script in the `build-linux` CI step.

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

## Contacts Typeahead Architecture

- `lib/domain/repositories/system_contacts_repository.dart` — abstract interface
- `lib/data/repositories/system_contacts_repository_impl.dart` — calls native channel
- `lib/domain/usecases/search_contacts.dart` — combines known senders + system contacts
- `lib/domain/entities/contact_suggestion.dart` — `{address, name, displayText}`
- `_RecipientField` in `compose_dialog.dart` calls `warmUp()` eagerly in `initState()`
  so the permission dialog appears when the compose window opens, not on first keystroke.
