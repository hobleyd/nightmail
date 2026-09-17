#!/bin/bash
#
# Reports why an in-app update on macOS did not install.
#
#     tool/diagnose_macos_update.sh            # everything, asks for sudo once
#     tool/diagnose_macos_update.sh --watch    # live log while you press Update
#
# The failure this exists for is "Unable to confirm update installation
# handoff", which is `desktop_updater`'s one message for *every* error the
# privileged handoff can raise — the package catches them all and throws the
# same thing, so the app can only ever repeat that sentence. The three states
# that tell them apart (whether the LaunchDaemon is registered, whether it is
# loaded, and whether launchd will vend its Mach service) are all readable only
# as root, which is why this is a script to run rather than something the app
# could report about itself.
#
# It changes nothing. Everything below is a read.

set -eu

APP=${NIGHTMAIL_APP:-/Applications/NightMail.app}
REPORT=${NIGHTMAIL_REPORT:-$HOME/nightmail-update-diagnosis.txt}

say() { printf '%s\n' "$*"; }
rule() { printf '\n== %s ==\n' "$*"; }
# Report rather than abort: a missing piece is the finding, not a reason to
# stop before the sections that would explain it.
try() { "$@" 2>&1 || say "  (command failed: $*)"; }

if [ ! -d "$APP" ]; then
  say "No app at $APP."
  say "Set NIGHTMAIL_APP=/path/to/NightMail.app and run again."
  exit 1
fi

# ---------------------------------------------------------------------------
# --watch: stream the log while the update is attempted.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--watch" ]; then
  WATCH_LOG=${NIGHTMAIL_WATCH_LOG:-$HOME/nightmail-update-log.txt}
  say "Streaming to $WATCH_LOG."
  say "Press Restart and install in NightMail now, wait for the failure,"
  say "then press Ctrl-C here."
  say ""
  # launchd, smd and backgroundtaskmanagementd are the three that answer for a
  # LaunchDaemon; the app's own process carries the code-signing checks.
  sudo /usr/bin/log stream --level debug --style compact \
    --predicate 'process == "launchd" OR process == "smd" OR process == "backgroundtaskmanagementd" OR process == "NightMail" OR eventMessage CONTAINS[c] "nightmail"' \
    | tee "$WATCH_LOG"
  exit 0
fi

exec > >(tee "$REPORT") 2>&1

say "NightMail macOS update diagnosis"
say "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "app:       $APP"
say "macOS:     $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

rule "Where the app actually is"
# The directory entry's own spelling, not the one we asked for: /Applications is
# case-insensitive, so `ls -d` echoes whatever case you typed and an app
# installed over a differently-cased predecessor keeps the old name.
ls -d "$(dirname "$APP")"/*.app 2>/dev/null | grep -i nightmail || say "  (none listed)"
say "translocated (should be empty):"
ls -d /private/var/folders/*/*/T/AppTranslocation/*/d/NightMail.app 2>/dev/null || say "  (not translocated)"
say "quarantine on the bundle:"
try xattr -p com.apple.quarantine "$APP" || say "  (none)"
say "quarantine on the helper:"
try xattr -p com.apple.quarantine "$APP/Contents/Helpers/DesktopUpdaterInstallHelper" || say "  (none)"

rule "Version"
try /usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist"
try /usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist"

rule "Signing and notarization"
try codesign --verify --deep --strict --verbose=2 "$APP"
try spctl --assess --type execute -vv "$APP"
try xcrun stapler validate "$APP"

rule "Embedded privileged helper"
SERVICE_ID=$(/usr/libexec/PlistBuddy -c 'Print DesktopUpdaterInstallHelperServiceID' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo "")
PLIST_NAME=$(/usr/libexec/PlistBuddy -c 'Print DesktopUpdaterInstallHelperLaunchDaemonPlistName' \
  "$APP/Contents/Info.plist" 2>/dev/null || echo "")
say "service id:  ${SERVICE_ID:-<missing>}"
say "plist name:  ${PLIST_NAME:-<missing>}"
try /usr/libexec/PlistBuddy -c 'Print DesktopUpdaterInstallHelperRequirement' "$APP/Contents/Info.plist"
try /usr/libexec/PlistBuddy -c 'Print DesktopUpdaterInstallPolicyID' "$APP/Contents/Info.plist"
say ""
try ls -l "$APP/Contents/Helpers/"
try ls -l "$APP/Contents/Library/LaunchDaemons/"
if [ -n "$PLIST_NAME" ]; then
  say ""
  try plutil -p "$APP/Contents/Library/LaunchDaemons/$PLIST_NAME"
fi
say ""
say "helper signature:"
codesign -dv --verbose=4 "$APP/Contents/Helpers/DesktopUpdaterInstallHelper" 2>&1 \
  | grep -E 'Identifier|TeamIdentifier|Authority=|flags=' || say "  (unsigned?)"
say "helper runs:"
try "$APP/Contents/Helpers/DesktopUpdaterInstallHelper" --version

rule "Helper's own log directory"
# The helper creates this the first time it runs as root. Absent means the
# privileged side was never reached, whatever the app reported.
ls -la /Library/Logs/DesktopUpdater/ 2>/dev/null || say "  (absent — the helper has never run)"

rule "Pending install marker"
MARKER="$HOME/.nightmail/desktop_updater_pending_install.json"
if [ -f "$MARKER" ]; then
  try python3 -m json.tool "$MARKER"
else
  say "  (none — no install is half-finished)"
fi

# ---------------------------------------------------------------------------
# Root-only. This is the part that actually answers the question.
# ---------------------------------------------------------------------------
rule "LaunchDaemon registration (needs your password)"
if [ -z "$SERVICE_ID" ]; then
  say "  (no service id in Info.plist — nothing to look up)"
elif ! sudo -v; then
  # Say so rather than letting each grep below report "not listed": an
  # unanswered password prompt reads exactly like a clean machine otherwise,
  # which is the wrong answer in the most important section of the report.
  say "  (skipped — sudo declined, so nothing here could be read)"
else
  say "launchctl print system/$SERVICE_ID:"
  try sudo /bin/launchctl print "system/$SERVICE_ID"
  say ""
  say "disabled in the system domain?"
  sudo /bin/launchctl print-disabled system 2>&1 | grep -i nightmail \
    || say "  (not listed — not disabled)"
  say ""
  say "Background Task Management record:"
  sudo /usr/bin/sfltool dumpbtm 2>&1 | grep -i -B4 -A20 nightmail \
    || say "  (no BTM record — the daemon has never been registered)"
fi

rule "What to read first"
cat <<'GUIDE'
  * "Could not find service" from launchctl print, and no BTM record:
    SMAppService never registered the daemon. The app should have reported
    that it needs approval in Login Items & Extensions.

  * A BTM record marked "disabled" or "requires approval":
    approve NightMail in System Settings > General > Login Items & Extensions,
    then press Restart and install again.

  * A BTM record marked enabled, but launchctl print says the job is not
    loaded: the registration is stale — macOS is holding a record pointing at
    a copy of the app that has been replaced. Deleting NightMail, emptying the
    Trash and reinstalling from the DMG clears it.

  * Everything present and loaded: run this again with --watch and press
    Restart and install, so the failing call is in the log.
GUIDE

say ""
say "Report written to $REPORT"
