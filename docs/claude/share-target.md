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
- `launchMode` is `singleTop` with `taskAffinity=""`, as for `mailto:`. A share
  can therefore start a second activity in the sharing app's task rather than
  raising the running one. That is unchanged from how `mailto:` already behaves.
