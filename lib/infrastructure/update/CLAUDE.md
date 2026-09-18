# In-App Updates

The macOS/Windows/Android update mechanisms behind one `AppUpdateStatus`. See [../../../CLAUDE.md](../../../CLAUDE.md) for architecture-wide rules.

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

### macOS Ships Unsandboxed, Because the Updater Cannot Work Inside One

`macos/Runner/Release.entitlements` sets `com.apple.security.app-sandbox` to
**false**. That is load-bearing for updating, not a convenience:

- **Staging spawns command-line tools.** `desktop_updater` verifies a staged app
  in Dart (`update_client.dart` → `macos_update.dart`) by running `codesign`,
  `spctl` and `xcrun stapler`. Child processes inherit the sandbox, and two of
  the three cannot survive it: `spctl --assess` answers **"internal error in
  Code Signing subsystem"** and `xcrun` refuses outright with *"cannot be used
  within an App Sandbox"*. `codesign` alone is fine. No entitlement fixes
  `xcrun` — the refusal is xcrun's own check, not the kernel's.
- **Installing registers a privileged helper.** The handoff goes through
  `SMAppService.daemon`, which a sandboxed app may not do at all.

That failure reached the user as a bare `ProcessException`: the package's
`_runChecked` puts the child's stderr into the exception message and
[_describeUpdateError] falls back to `error.toString()`, so `spctl`'s own
wording was what the About panel printed. If an update failure ever names a
command-line tool, that is the path it came down.

`../inkworm` and `desktop_updater`'s own example app both ship unsandboxed for
the same reason.

What went with the sandbox: `network.client`/`network.server` (the Gmail
loopback bind at 127.0.0.1:34572 needs no permission outside one) and
`files.user-selected.read-write`. `personal-information.addressbook` and
`.calendars` had to go too — see [../../../macos/CLAUDE.md](../../../macos/CLAUDE.md).
**`keychain-access-groups` stays**, with the provisioning profile the release
workflow embeds for it: every account, OAuth token and IMAP password lives in
the Keychain under that group, so dropping it would sign the user out of
everything. Where the app's *files* went is
[../../core/platform/CLAUDE.md](../../core/platform/CLAUDE.md).

### The Install Helper Is Embedded by a Build Phase, or the Install Fails Last

`prepareAndCommitInstall` reads the sealed release-key policy out of
`Contents/Helpers/DesktopUpdaterInstallHelper`'s **signature** before it will
accept a staged update. Nothing builds that binary by default, so without the
build phase an update downloads, verifies, stages — and then reports "Unable to
prepare update installation" with `details: nil`, which is a worse error than
the one it replaced.

`macos/embed_update_helper.sh` is the "Embed Desktop Updater Install Helper"
build phase. It wraps the package's own `embed_install_helper.sh` and does the
three things that script leaves to the host project:

- **Finds the package** through `Flutter/ephemeral/.symlinks/plugins/`, which
  `flutter pub get` rebuilds, so a version bump needs no path edited here.
- **Derives `DESKTOP_UPDATER_SEALED_POLICY_SHA256` from the policy file.** The
  example project hardcodes that digest in `project.pbxproj`, where it silently
  drifts the first time anyone edits the policy.
- **Skips every configuration but Release.** Nothing installs an update from a
  `flutter run` build, a per-architecture `swift build` on every debug build is
  a real tax on the edit loop, and an ad-hoc signed debug build cannot satisfy
  the Developer ID requirement the sealed policy names anyway.

**`macos/Runner/DesktopUpdaterHelperPolicy.json` must stay canonical JSON** —
compact, keys sorted. The build script digests the file with one trailing
newline stripped; the *app* re-serialises the JSON through `JSONSerialization`
with sorted keys and digests that. They agree only while the file is already in
that form, so a reformatted policy builds and signs cleanly and then fails on
the user's machine with nothing to point at. The wrapper checks it and says so
at build time instead.

The policy names the pinned Ed25519 release key — it must match
`kTrustedReleasePublicKeys`, or every release is refused — the app and helper
designated requirements, and `/Applications` as the only install root. The build
phase runs **last** on the Runner target: Xcode seals the bundle after every
phase, so the helper has to be in `Contents/Helpers` before that.

### macOS Has Two Install Paths, and Which One Runs Is Decided by a File Mode

`PackagedMacInstallHelperTransport.defaultPrivilegeRequired` asks one question
of a zipped `.app`: is the **parent of the install target writable by this
user**? `/Applications` is `root:admin drwxrwxr-x` on a stock Mac, so for an
administrator it *is* — and `MacInstallRequestEvidence.targetClass` is
`applicationBundle` rather than `protectedApplication` for the same reason.

So on an admin account the whole privileged apparatus — `SMAppService`, the
`Contents/Library/LaunchDaemons` plist, the Mach service, the Login Items
approval and [AppUpdatePhase.helperApprovalRequired] — **is never reached**.
The helper is spawned as an ordinary child process
(`DesktopUpdaterInstallHelper --one-shot-service`) and talked to over a
length-prefixed pipe on its stdin/stdout. A standard (non-admin) account takes
the LaunchDaemon path instead. The embedded daemon plist is still required: it
is what the *other* path uses, and the app's Info.plist keys are validated
before either.

Knowing which path is in play is most of the diagnosis, because the evidence
for the two lives in different places and reading the wrong one is worse than
reading nothing.

### Every Install Failure Reports the Same Sentence

"Unable to confirm update installation handoff" is
`MacInstallClientError.installRecoveryRequired`, and `MacInstallHelper`'s
`prepareInstall` and `commitAfterExit` both end in a bare `catch` that converts
*everything* to it. That one sentence therefore covers a refused stage, a
caller whose signature did not check out, a daemon awaiting approval, an XPC
endpoint that never came up and a torn wire frame alike — the package discards
the underlying error before the method channel sees it.

The helper records nothing either. `MacOneShotServiceRuntime.run` logs
`helper scheduled` as it starts and then nothing until a commit is *accepted*,
so a refusal is silent by construction. Two things follow:

- **`~/Library/Logs/DesktopUpdater/events.jsonl` is the log that exists.**
  `MacHelperDiagnosticsRecorder.defaultLogURL` only uses
  `/Library/Logs/DesktopUpdater` when `geteuid() == 0`, and `/Library/Logs` is
  root-only — so on the unprivileged path that directory can never appear, and
  its absence says nothing at all. A `helper scheduled` entry in the user-domain
  log means the helper launched, loaded its sealed policy and authenticated its
  own signature; nothing after it means it refused the request and exited.
- **The build phase patches `main.swift` so a refusal says which check failed.**
  `macos/embed_update_helper.sh` builds the helper from a copy under
  `DERIVED_FILE_DIR` with four lines added to its final `catch`: the thrown
  error's own description goes into the diagnostics the helper already writes,
  and onto the stderr it already inherits from the app
  (`ProcessMacOneShotProcessLauncher` sets
  `process.standardError = FileHandle.standardError`). Behaviour is otherwise
  identical — same error, same exit code. The `detailCode` is then one of
  `invalidHelperIdentity`, `targetAuthenticationFailed`,
  `callerAuthenticationFailed`, `stageAuthenticationFailed` or
  `unsupportedStrategy`, which is the whole difference between a fixable
  failure and an unfixable one. The patch is applied to a *copy*, never to
  `~/.pub-cache`, and the build **fails loudly** if the text it rewrites has
  moved — a silently un-instrumented helper would put this back where it was.
- **`tool/diagnose_macos_update.sh` re-runs the helper's checks from outside**,
  in the order the helper runs them, and names the first that does not hold:
  which path applies, the installed bundle against the sealed policy's
  application requirement, the helper against its own, the sealed policy's
  digest and canonical form, the helper log, and the staged update — its
  provenance digest, its full inventory against that marker, its release
  manifest and its signature. It asks for a password only on the privileged
  path, where alone the answer needs one.

**A first `SMAppService.daemon(…).register()` always fails** — measured, not
inferred: `SMAppServiceErrorDomain` code 1, "Operation not permitted", leaving
`status == .requiresApproval`, because installing a LaunchDaemon needs the user
to approve the background item. The package checks that status and raises
`PrivilegedHelperApprovalRequired`, which is why that phase exists. It is only
ever seen on a non-admin account.

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

`AppUpdateStatus.hasActionableUpdate` — `available`, `freshInstallRequired`,
`readyToInstall` or `helperApprovalRequired`. A download already running does
**not** light it: the user has acted, and a dot beside a progress bar reads as a
second, separate thing still wanting attention.

**`helperApprovalRequired` is the macOS first-install path, and is not a
failure.** `SMAppService.daemon` registration asks the user to approve the
privileged install helper the first time, and `prepareAndCommitInstall` reports
that as `PlatformException(PrivilegedHelperApprovalRequired)` carrying the
remedy in its own `details`. Left in the `failed` bucket it printed a raw
PlatformException — code, message and details map — into the About panel with no
route to the toggle, which after a string of genuine failures reads as one more.
It gets its own phase, its own line and a button that opens Login Items &
Extensions; the stage is untouched, so pressing it returns to `readyToInstall`
and Restart and install is what finishes the job. `_describeUpdateError` also
unwraps a PlatformException to its `message` now, so the *other* native install
errors read as sentences rather than as a dump.

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

