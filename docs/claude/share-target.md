# Share Target (Android, iOS)

NightMail appears in the phone's share sheet. Text, links and files shared to it
open a compose screen: the text becomes a plain-text body, Android's
`EXTRA_SUBJECT` (a browser's page title alongside a link) the subject, and the
files attachments.

## One Channel, Pulled

Both platforms talk to `ShareIntentService`
(`lib/infrastructure/share/share_intent_service.dart`) over
`au.com.sharpblue.nightmail/share_intent`, with the same map:
`{subject, text, files: [{path, name, mimeType}]}`.

The native side **holds** the latest share and only pings `shareReceived`; Dart
always pulls it with `takePendingShare`, which clears it. `_HomeViewState` pulls
once in `initState` (a share that launched the app) and again on every ping.
This is what keeps a cold-start share from racing the Dart handler, and means a
share is never opened twice. The home page only mounts once accounts have
loaded, so a share waiting natively simply waits until there is a sender.

Files arrive as copies the native side made in storage NightMail owns. Dart reads
each into a `LocalAttachment` eagerly — compose never touches the filesystem
again — and deletes the copy.

## Why Not `receive_sharing_intent`

It was evaluated and rejected. Its Android side resolves `content:` URIs to raw
`/storage/emulated/0/...` paths (the old `getDataColumn` approach), which scoped
storage will not let the app read; it also turns every `ACTION_VIEW` into a
"shared URL", which would have opened compose a second time for every `mailto:`
link that `app_links` already handles; and its iOS host links `Photos` with no
usage string behind it.

## Android

`MainActivity` takes `ACTION_SEND` / `ACTION_SEND_MULTIPLE` with `*/*`. It keeps
the **intent**, not its files, and copies the streams on a background thread
only when Dart takes the share.

- Only `content:` URIs are copied. A `file:` URI from another app could name one
  of NightMail's own private files, which would then be sent as an attachment.
- A recreated activity (rotation) and a relaunch from Recents carry the original
  intent again; `onCreate` ignores both so an old share does not reopen.
- Copies go to `cacheDir/shared/<time>/<index>/<display name>` — the index
  directory because two shared files can carry the same name. The whole
  `shared` directory is cleared at the start of each read.
- `launchMode` is `singleTask`, so a share (or a `mailto:` link) into a
  running NightMail goes to the existing activity through `onNewIntent` rather
  than starting a second activity — and a second Flutter engine — in the sharing
  app's task. It was `singleTop` until sharing made that the common path.
  `taskAffinity=""` stays: it keeps other apps from planting activities in
  NightMail's task. The cost of `singleTask` is that tapping the launcher icon
  clears anything above the activity in its task, so a sign-in Custom Tab the
  user left (to fetch a 2FA code, say) is closed if they come back through the
  icon rather than Recents.

## iOS

`ios/ShareExtension` is an app extension embedded in `Runner.app/PlugIns`
(bundle id `au.com.sharpblue.nightmail.ShareExtension`). It has **no Flutter
dependency** and shows no UI:

1. Copies each shared file into the App Group container
   (`group.au.com.sharpblue.nightmail`) under `share/<uuid>/<index>/<name>`;
   links and text are collected as text, `attributedTitle` as the subject.
2. Writes `share/pending.json` (the channel map) and opens `nightmail-share://`,
   a scheme registered in `Runner/Info.plist`, by walking the responder chain
   to the `UIApplication` — an extension has no `UIApplication.shared`.
3. `SceneDelegate` answers `takePendingShare` by reading and deleting
   `pending.json`, and pings `shareReceived` on that URL **and** on every
   `UIScene.didActivateNotification` while the file exists. The second ping is
   the fallback if iOS ever stops the extension opening its app: the share is
   still waiting, and opens when the user next switches to NightMail.

The App Group id is a literal in `ShareViewController.swift`,
`SceneDelegate.swift` and both `.entitlements` files — change all four together.

The extension's `CFBundleVersion`/`CFBundleShortVersionString` come from the
same `FLUTTER_BUILD_*` variables as the app (its configurations are based on
the Flutter xcconfigs). App Store upload rejects an extension whose version
differs from its parent's.
