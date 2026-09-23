# iOS Runner

What the App Store needs from the `ios/` folder and why it is shaped this way.
See [../CLAUDE.md](../CLAUDE.md) for architecture-wide rules and
[../macos/CLAUDE.md](../macos/CLAUDE.md) for the macOS runner, whose Swift
this one deliberately duplicates (no shared target exists between them).

## Naming

The product is **NightMail** — capital M — everywhere a person can see it:
`CFBundleDisplayName`, `CFBundleName`, usage strings, the App Store profile
name. The bundle id `au.com.sharpblue.nightmail` is lower-case and is the one
place that is not, because Apple never shows it and changing it would be a
new app.

## Privacy Strings and Manifest

`SceneDelegate.swift` requests calendar access through the iOS 17 full-access
API, so `Info.plist` needs `NSCalendarsFullAccessUsageDescription` **as well
as** the legacy `NSCalendarsUsageDescription`. Missing the new key is not a
denied prompt, it terminates the app when the prompt would appear. Contacts
has no string because contact sync is macOS-only (`system_contacts_repository_impl.dart`).

`Runner/PrivacyInfo.xcprivacy` is the app's privacy manifest, listed in the
Runner target's Resources phase. It declares no tracking and no collected
data — mail is processed on the device and nothing goes to us — and the
required-reason API categories that the app binary and the plugins **without
their own manifest** touch: file timestamps and disk space (sqlite3, shipped as
a native asset, and `path_provider`), user defaults, and system boot time.
Plugins that ship a manifest (Flutter itself, `flutter_local_notifications`,
`workmanager_apple`, the `url_launcher`/`share_plus`/`webview` family) are
covered by their own. `printing`, `flutter_web_auth_2`, `open_file_ios` and our
`html_view` ship none, which is why the app-level one is generous rather than
minimal. App Store Connect reports a missing declaration as an ITMS-91053
warning on upload; that is the signal to extend this file.

`UIBackgroundModes` is `fetch` only. `AppDelegate.swift` registers a
`BGAppRefreshTask` and nothing else; `processing` was declared with no task
behind it, which is the kind of thing review asks about.

## Launch Screen

`Base.lproj/LaunchScreen.storyboard` is the app's base surface colour with the
logo centred as a 120pt rounded tile. The colour is the `LaunchBackground`
colour set in `Assets.xcassets`, light `#F5F6FA` and dark `#0F1117`, matching
`AppColors.surfaceBase` so the first frame of the app does not flash a
different shade. A launch screen cannot run code and the logo PNG is a square
with its starfield baked in, so the rounded corners are baked into the
`LaunchImage` PNGs by `scripts/launch_tile.swift` — re-run it after changing
`assets/logo.png`.

## App Icon Variants

`Assets.xcassets/AppIcon.appiconset/Contents.json` carries the legacy per-size
entries `flutter_launcher_icons` writes **plus** three `universal`/`ios`
1024px entries for the iOS 18 appearances: light (the marketing icon itself),
dark and tinted. `scripts/icon_variants.swift` renders the dark and tinted
files from the marketing icon. Re-running `flutter_launcher_icons` rewrites
the Contents.json without the three entries — re-run the script and re-add
them (the script's header shows the entries) before the next release build.

## iOS Look Without Touching the Desktop

`AdaptiveAlertDialog` and `AdaptiveSwitch` (`lib/presentation/widgets/`) give
the phone a Cupertino alert and switch and leave every other platform on the
Material widgets the app already styles. They test `defaultTargetPlatform ==
iOS` themselves rather than using `AlertDialog.adaptive` / `Switch.adaptive`,
because those switch on `Theme.platform`, which is **macOS on a Mac** — the
desktop would silently change look. Android stays Material, its own
convention. The alert only goes Cupertino for a plain alert (text title, text
body, text-button actions); a dialog with a form in it keeps the Material
dialog on iOS, since a Cupertino alert has no room for controls.

## Signing: Xcode Automatic, CI Manual

The committed project uses `CODE_SIGN_STYLE = Automatic` with the team set,
which is what makes Xcode and `flutter run` on a device work without profile
juggling. TestFlight builds cannot use that (no Apple ID session on a runner),
so the `build-ios` job in `.github/workflows/release.yml` patches the Runner
**Release** configuration to manual signing with the "NightMail App Store"
profile before `flutter build ipa`, and `ExportOptions.plist` governs the
export step. The patch flips the existing `CODE_SIGN_STYLE` line in place —
adding a second key to a pbxproj dict is undefined — and asserts on its
anchors, so a project-file change that moves them fails the job loudly rather
than producing a badly signed archive. Dry-run it locally by extracting the
Python from the workflow and pointing it at a copy of the project file.

## iPad

`TARGETED_DEVICE_FAMILY = "1,2"`: the app is universal and multitasking is
allowed (no `UIRequiresFullScreen`), which is why the iPad orientation list
has to carry all four orientations. No iPad-specific layout exists or is
wanted: `HomePage` draws the three-panel desktop layout at 600pt and up and
the phone shell below, so a full-screen iPad gets the desktop layout with
touch metrics (`isTouchPlatform` is true there) and a narrow Split View pane
falls back to the phone shell. App Store submission needs iPad screenshots
for every listed iPad size class.
