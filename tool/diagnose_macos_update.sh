#!/bin/bash
#
# Reports why an in-app update on macOS did not install.
#
#     tool/diagnose_macos_update.sh            # report
#     tool/diagnose_macos_update.sh --reset    # drop a stale pending install
#
# "Unable to confirm update installation handoff" is `desktop_updater`'s one
# message for *every* error the native handoff can raise: `MacInstallHelper`'s
# `prepareInstall` and `commitAfterExit` both end in a bare `catch` that
# converts anything at all to `installRecoveryRequired`. So the app can only
# ever repeat that sentence, and the install helper — which is where the
# rejection actually happens — records nothing when it refuses.
#
# This re-runs, from outside, the same chain of checks the helper performs, in
# the order it performs them, and names the first one that does not hold. It
# changes nothing: everything below is a read.

set -uo pipefail

APP=${NIGHTMAIL_APP:-/Applications/NightMail.app}
REPORT=${NIGHTMAIL_REPORT:-$HOME/nightmail-update-diagnosis.txt}
HELPER_LOG="$HOME/Library/Logs/DesktopUpdater/events.jsonl"
MARKER="$HOME/.nightmail/desktop_updater_pending_install.json"

say() { printf '%s\n' "$*"; }
rule() { printf '\n== %s ==\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
bad() { printf '  FAIL  %s\n' "$*"; }
note() { printf '        %s\n' "$*"; }

if [ ! -d "$APP" ]; then
  say "No app at $APP. Set NIGHTMAIL_APP=/path/to/NightMail.app and run again."
  exit 1
fi

# ---------------------------------------------------------------------------
# --reset: throw the half-finished install away so the next check re-stages.
#
# A stage is bound to the descriptor and artifact it was built from by three
# digests and a full file inventory, and the helper refuses it if any of them
# has moved. So a stage that was written by one attempt and reused by a later
# one is a live suspect, and this is the cheapest way to take it off the board.
# Nothing here is data: the marker records that an install is pending, and the
# stage is a downloaded copy the app will fetch again.
# ---------------------------------------------------------------------------
if [ "${1:-}" = "--reset" ]; then
  say "Quit NightMail first, then this clears the pending install."
  if [ -f "$MARKER" ]; then
    STAGE_ROOT=$(python3 -c 'import json,os,sys;print(os.path.dirname(json.load(open(sys.argv[1])).get("stagingPath","")))' "$MARKER")
    case "$STAGE_ROOT" in
      */desktop_updater_stage_*)
        rm -rf "$STAGE_ROOT" && say "removed stage $STAGE_ROOT" ;;
      *)
        say "stage path not recognised, left alone: ${STAGE_ROOT:-<none>}" ;;
    esac
    rm -f "$MARKER" && say "removed $MARKER"
  else
    say "nothing pending"
  fi
  say ""
  say "Now start NightMail, open Settings > About, press Check for updates,"
  say "and then Restart and install."
  exit 0
fi

# Re-exec once through a pipe rather than `exec > >(tee …)`: a process
# substitution leaves tee running with the script's stdout still open, so the
# script cannot wait for it and the report can lose its tail.
if [ -z "${NIGHTMAIL_TEEING:-}" ]; then
  NIGHTMAIL_TEEING=1 "$0" "$@" 2>&1 | tee "$REPORT"
  exit "${PIPESTATUS[0]}"
fi

say "NightMail macOS update diagnosis"
say "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
say "app:       $APP"
say "macOS:     $(sw_vers -productVersion) ($(sw_vers -buildVersion))"

# ---------------------------------------------------------------------------
# Which of the two install paths this machine takes.
#
# `PackagedMacInstallHelperTransport.defaultPrivilegeRequired` asks one
# question for a zipped .app: is the *parent* of the install target writable by
# this user? /Applications is normally root:admin drwxrwxr-x, so for an admin
# it is — and the whole privileged LaunchDaemon apparatus (SMAppService, the
# Mach service, Login Items approval) is then never used at all. The helper is
# spawned as an ordinary child process with a pipe instead.
#
# Knowing which path is in play is the difference between reading the right
# evidence and the wrong evidence, so it goes first.
# ---------------------------------------------------------------------------
rule "Which install path applies"
ls -ld /Applications
if [ -w /Applications ]; then
  say "  /Applications is writable by $(id -un)"
  say "  => unprivileged one-shot helper (no LaunchDaemon, no approval prompt)"
  PRIVILEGED=no
else
  say "  /Applications is NOT writable by $(id -un)"
  say "  => privileged LaunchDaemon path (SMAppService + Login Items approval)"
  PRIVILEGED=yes
fi

rule "Where the app is, and what it is"
# The directory entry's own spelling, not the one asked for: /Applications is
# case-insensitive, so an app installed over a differently-cased predecessor
# keeps the old name and every path comparison in the helper is exact.
ls -d /Applications/*.app 2>/dev/null | grep -i nightmail || note "(none listed)"
ls -d /private/var/folders/*/*/T/AppTranslocation/*/d/NightMail.app 2>/dev/null \
  && bad "the app is translocated" || note "not translocated"
note "version $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)+$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null)"

rule "The caller: what the helper checks about the running app"
REQ=$(/usr/libexec/PlistBuddy -c 'Print DesktopUpdaterInstallHelperRequirement' \
  "$APP/Contents/Info.plist" 2>/dev/null)
APP_REQ=${REQ/au.com.sharpblue.nightmail.helper/au.com.sharpblue.nightmail}
codesign -v --strict "$APP" 2>/dev/null \
  && ok "signature valid and unmodified" \
  || bad "codesign --strict rejects the installed bundle"
codesign -v -R="$APP_REQ" "$APP" 2>/dev/null \
  && ok "satisfies the sealed policy's application requirement" \
  || bad "does NOT satisfy: $APP_REQ"
xcrun stapler validate "$APP" >/dev/null 2>&1 \
  && ok "notarization ticket stapled" || bad "no stapled ticket"

rule "The helper: what it checks about itself before it will serve"
H="$APP/Contents/Helpers/DesktopUpdaterInstallHelper"
if [ ! -x "$H" ]; then
  bad "no install helper at Contents/Helpers — the build phase did not run"
else
  ok "present: $("$H" --version 2>&1)"
  codesign -v -R="$REQ" "$H" 2>/dev/null \
    && ok "satisfies the sealed policy's helper requirement" \
    || bad "does NOT satisfy: $REQ"
  # The helper refuses to start unless the policy sealed into its own
  # __TEXT,__info_plist is byte-canonical JSON whose digest matches the string
  # beside it. A reformatted policy builds and signs cleanly and fails here.
  python3 - "$H" <<'PY'
import sys, subprocess, plistlib, hashlib, json
raw = subprocess.run(["otool", "-P", sys.argv[1]], capture_output=True, text=True).stdout
try:
    s = raw.index("<?xml"); e = raw.index("</plist>", s) + 8
    pl = plistlib.loads(raw[s:e].encode())
    data = pl["DesktopUpdaterSealedPolicy"]
except Exception as error:
    print(f"  FAIL  cannot read the sealed policy: {error}"); sys.exit()
digest = hashlib.sha256(data).hexdigest()
stored = pl.get("DesktopUpdaterSealedPolicySHA256")
print(f"  {'ok   ' if digest == stored else 'FAIL '} sealed policy digest {'matches' if digest == stored else 'MISMATCH'}")
obj = json.loads(data)
canon = json.dumps(obj, sort_keys=True, separators=(",", ":")).encode()
print(f"  {'ok   ' if canon == data else 'FAIL '} sealed policy is {'' if canon == data else 'NOT '}canonical JSON")
print(f"  {'ok   ' if pl['CFBundleIdentifier'] == obj['helperServiceId'] else 'FAIL '} helper identifier matches helperServiceId")
print(f"        install roots: {obj['allowedInstallRoots']}")
print(f"        target classes: {obj['allowedTargetClasses']}")
PY
fi

rule "The helper's own diagnostics"
# When it is not root — which is every time on the unprivileged path — the
# helper writes here, not to /Library/Logs/DesktopUpdater. /Library/Logs is
# root-only, so an absent directory there says nothing at all.
if [ -f "$HELPER_LOG" ]; then
  say "$HELPER_LOG:"
  tail -20 "$HELPER_LOG"
  say ""
  note "'helper scheduled' means the helper launched and authenticated itself."
  note "Nothing after it means it refused the request and exited: the package"
  note "records no event for a refusal."
else
  note "no log — the helper has never been launched by the app"
fi

rule "The staged update"
if [ ! -f "$MARKER" ]; then
  note "no pending install marker; nothing is staged"
else
  python3 - "$MARKER" <<'PY'
import sys, json, os, hashlib
marker = json.load(open(sys.argv[1]))
stage_app = marker.get("stagingPath", "")
root = os.path.dirname(stage_app)
print(f"        staged: {stage_app}")
print(f"        {marker.get('appVersion')} -> {marker.get('updateVersion')}+{marker.get('updateBuildNumber')}")
if not os.path.isdir(root):
    print("  FAIL  the stage directory is gone; press Check for updates again")
    sys.exit()
prov = os.path.join(root, ".desktop_updater_stage_provenance.json")
raw = open(prov, "rb").read()
digest = hashlib.sha256(raw).hexdigest()
print(f"  {'ok   ' if digest == marker.get('stageProvenanceSha256') else 'FAIL '} provenance digest {'matches' if digest == marker.get('stageProvenanceSha256') else 'MISMATCH'}")
m = json.loads(raw)
canon = json.dumps(m, sort_keys=True, separators=(",", ":")).encode()
print(f"  {'ok   ' if canon == raw else 'FAIL '} provenance is {'' if canon == raw else 'NOT '}canonical JSON")
# The helper walks the stage and requires it to equal the marker exactly. A
# stage touched after it was written — by a backup pass, an indexer, anything
# — is refused, and this is the check most likely to be the reason.
expected = {e["path"] for e in m["entries"]}
actual = set()
for base, dirs, files in os.walk(root):
    for name in dirs + files:
        actual.add(os.path.relpath(os.path.join(base, name), root))
actual.discard(".desktop_updater_stage_provenance.json")
missing, extra = sorted(expected - actual), sorted(actual - expected)
if not missing and not extra:
    print(f"  ok    stage inventory matches the marker ({len(expected)} entries)")
else:
    print(f"  FAIL  stage inventory differs: {len(missing)} missing, {len(extra)} unexpected")
    for p in (missing[:5] + ["..."] if len(missing) > 5 else missing): print(f"          - {p}")
    for p in (extra[:5] + ["..."] if len(extra) > 5 else extra): print(f"          + {p}")
man = os.path.join(root, ".desktop_updater_release_manifest.json")
d = json.load(open(man))
print(f"        manifest appName={d['appName']!r} version={d['version']} build={d.get('buildNumber')}")
name_ok = d["appName"] == os.path.basename(stage_app)
print(f"  {'ok   ' if name_ok else 'FAIL '} manifest appName {'matches' if name_ok else 'does NOT match'} the staged bundle")
PY
  STAGED=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('stagingPath',''))" "$MARKER")
  if [ -d "$STAGED" ]; then
    codesign -v --strict "$STAGED" 2>/dev/null \
      && ok "staged bundle signature valid" || bad "staged bundle fails codesign --strict"
    codesign -v -R="$APP_REQ" "$STAGED" 2>/dev/null \
      && ok "staged bundle satisfies the application requirement" \
      || bad "staged bundle does NOT satisfy the application requirement"
  fi
fi

# ---------------------------------------------------------------------------
# Only meaningful on the privileged path, so it is asked for only there — an
# unnecessary password prompt is its own kind of wrong answer.
# ---------------------------------------------------------------------------
if [ "$PRIVILEGED" = yes ]; then
  rule "LaunchDaemon registration (needs your password)"
  SERVICE_ID=$(/usr/libexec/PlistBuddy -c 'Print DesktopUpdaterInstallHelperServiceID' \
    "$APP/Contents/Info.plist" 2>/dev/null)
  if ! sudo -v; then
    note "skipped — sudo declined, so nothing here could be read"
  else
    sudo /bin/launchctl print "system/$SERVICE_ID" 2>&1 | head -30
    say ""
    sudo /usr/bin/sfltool dumpbtm 2>&1 | grep -i -B4 -A20 nightmail \
      || note "no Background Task Management record — never registered"
  fi
fi

rule "Reading this"
cat <<'GUIDE'
  Every FAIL above is a reason the helper would refuse the handoff and the app
  would report "Unable to confirm update installation handoff".

  All ok, and "helper scheduled" is the last thing in the helper's log: the
  refusal is in a check this script cannot see from outside — the caller's
  live process identity, or the signed release descriptor. Press Check for
  updates to re-stage (a stale stage is the common cause), then try again.
GUIDE

say ""
say "Report written to $REPORT"
