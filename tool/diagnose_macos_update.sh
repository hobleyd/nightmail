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
# "Unable to prepare update installation" is everything *before* the handoff:
# the stage failing verification inside the app, or the app failing to reserve
# its own restart. That reservation fails whenever the executable the process
# is running is no longer the file on disk — a bundle replaced underneath a
# running app by ditto, rsync, Finder or the ansible sharpblue role
# (2026-10-09) — and the helper's log then shows the transaction reach
# `prepared` and get cancelled within a few hundred milliseconds. "The running
# app" below is the check for it.
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
INSTALLED_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)+$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$APP/Contents/Info.plist" 2>/dev/null)"
note "version $INSTALLED_VERSION"

rule "The running app"
# Before committing, the app reserves its restart by spawning its own
# executable and comparing the child's file (device and inode) with the one it
# has mapped itself. They differ when every file in the bundle was replaced
# while the app ran, and the app then abandons the transaction the helper had
# already accepted. Nothing in the bundle or the stage is wrong; the process
# is. lsof's DEVICE and NODE columns are what the kernel reports for the
# mapping, in the same major,minor and inode form stat prints here.
EXE=$(/usr/libexec/PlistBuddy -c 'Print CFBundleExecutable' "$APP/Contents/Info.plist" 2>/dev/null)
EXE=${EXE:-NightMail}
PIDS=$(pgrep -x "$EXE" 2>/dev/null || true)
if [ -z "$PIDS" ]; then
  note "not running"
else
  ON_DISK=$(stat -f '%Hd,%Ld %i' "$APP/Contents/MacOS/$EXE" 2>/dev/null)
  for pid in $PIDS; do
    STARTED=$(ps -o lstart= -p "$pid" 2>/dev/null | sed 's/^ *//; s/ *$//')
    MAPPED=$(lsof -p "$pid" 2>/dev/null \
      | awk -v exe="$APP/Contents/MacOS/$EXE" '$4=="txt" && $9==exe {print $6" "$8; exit}')
    if [ -z "$MAPPED" ]; then
      note "pid $pid (started $STARTED): could not read what it has mapped"
    elif [ "$MAPPED" = "$ON_DISK" ]; then
      ok "pid $pid (started $STARTED) runs the executable that is on disk"
    else
      bad "pid $pid (started $STARTED) runs an executable that is no longer on disk"
      note "mapped device,inode $MAPPED — on disk $ON_DISK"
      note "The bundle was replaced underneath it. The restart step refuses"
      note "such a process before the commit, and the app reports 'Unable to"
      note "prepare update installation'. Quit NightMail, relaunch it from"
      note "/Applications, and install the update again."
    fi
  done
fi

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
  say "$HELPER_LOG — the last attempt:"
  python3 - "$HELPER_LOG" <<'PY'
import datetime
import json
import sys

entries = []
for line in open(sys.argv[1], encoding="utf-8"):
    line = line.strip()
    if not line:
        continue
    try:
        entries.append(json.loads(line))
    except ValueError:
        pass

# An attempt begins with the helper being launched to serve an install
# (detailCode oneShot or daemon), so the attempt being asked about is
# everything after the last such entry. Judging the whole log instead once
# found a refusal from three weeks earlier and blamed it for the day's. The
# app also launches the helper for a recovery pass every time it starts
# (detailCode recovery); one of those with nothing after it is routine, not a
# refusal, and only says the app has been relaunched since.


def when(entry):
    stamp = datetime.datetime.fromtimestamp(entry.get("timestampUnixMilliseconds", 0) / 1000)
    return stamp.strftime("%Y-%m-%d %H:%M:%S")


def scheduled(entry):
    return entry.get("event") == "helper scheduled"


starts = [i for i, e in enumerate(entries)
          if scheduled(e) and e.get("detailCode") != "recovery"]
attempt = entries[starts[-1]:] if starts else entries[-20:]
later_recoveries = [e for e in attempt[1:] if scheduled(e)]
attempt = [e for e in attempt if e is attempt[0] or not scheduled(e)]
for e in attempt:
    print("  %s  %-26s state=%-15s result=%-8s detail=%s" % (
        when(e), e.get("event", ""), e.get("state", ""),
        e.get("resultCode", ""), e.get("detailCode", "")))
print()


def ok(text):
    print("  ok    " + text)


def bad(text):
    print("  FAIL  " + text)


def note(text):
    print("        " + text)


states = [e.get("state") for e in attempt]
failed = [e for e in attempt if e.get("resultCode") == "failure"]
if failed:
    bad("the helper refused — detailCode %s names the check that failed:"
        % failed[-1].get("detailCode"))
    note("invalidHelperIdentity       the helper's own signature or sealed policy")
    note("targetAuthenticationFailed  the install target against the policy")
    note("callerAuthenticationFailed  the running app's identity")
    note("stageAuthenticationFailed   the staged update or its provenance")
    note("unsupportedStrategy         the artifact kind has no native strategy")
elif "cancelled" in states:
    bad("the app gave the reservation back after the helper had accepted it")
    note("Nothing the helper checks failed. Between 'prepared' and the commit")
    note("the app reserves its own restart; when that fails it abandons the")
    note("transaction and reports 'Unable to prepare update installation'.")
    note("The usual reason is under 'The running app' above. A commit the")
    note("helper rejected would show here as a failure, not a cancellation.")
elif any(s in ("commitAccepted", "executing", "backupCreated", "targetActivated",
               "completed") for s in states):
    ok("the handoff was accepted and the install went ahead")
elif "prepared" in states:
    note("prepared and never committed — the app may still be running, or it")
    note("exited before the commit was sent")
elif len(attempt) == 1:
    bad("nothing after 'helper scheduled': the helper refused without saying why")
    note("That is a build older than the one whose helper records its reason.")
else:
    note("no verdict for this sequence of states; read the entries above")
if later_recoveries:
    note("the app has launched %d time(s) since, last at %s, and ran its"
         % (len(later_recoveries), when(later_recoveries[-1])))
    note("recovery pass each time — so the process above is not the one that")
    note("made this attempt")
PY
else
  note "no log — the helper has never been launched by the app"
fi

rule "The staged update"
if [ ! -f "$MARKER" ]; then
  note "no pending install marker; nothing is staged"
else
  python3 - "$MARKER" "$INSTALLED_VERSION" <<'PY'
import sys, json, os, hashlib
marker = json.load(open(sys.argv[1]))
installed = sys.argv[2] if len(sys.argv) > 2 else ""
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
# The case every successful install ends in (2026-10-12): the helper renamed
# the bundle into /Applications, so the stage is only its three dot files and
# can never match the inventory again. The package confirms the installed
# version, insists on deleting the stage before it clears the marker, and
# fails — "Completed install stage cleanup failed." on every launch — and since
# 3.2.1 refuses the next install while the marker exists.
target = f"{marker.get('updateVersion')}+{marker.get('updateBuildNumber')}"
if os.path.basename(stage_app) in missing and installed == target:
    print(f"  FAIL  the install COMPLETED ({installed} is what is running) but its marker is stuck:")
    print(f"        the helper consumed the staged bundle, so the stage can never match its")
    print(f"        inventory again and desktop_updater refuses every later install.")
    print(f"        --reset clears it; NightMail builds after 1.39.4 clear it at launch")
    print(f"        (completed_install_marker.dart). Not a signing or helper problem.")
man = os.path.join(root, ".desktop_updater_release_manifest.json")
d = json.load(open(man))
print(f"        manifest appName={d['appName']!r} version={d['version']} build={d.get('buildNumber')}")
name_ok = d["appName"] == os.path.basename(stage_app)
print(f"  {'ok   ' if name_ok else 'FAIL '} manifest appName {'matches' if name_ok else 'does NOT match'} the staged bundle")
PY
  # macStageMode, applied to every entry of the staged bundle when the helper
  # hashes its tree. One group-writable file is enough to refuse the whole
  # update, and it is invisible in the installed app: Finder normalises
  # permissions copying from a DMG, so only the zip the updater downloads
  # keeps the mode the build produced.
  STAGED=$(python3 -c "import json,sys;print(json.load(open(sys.argv[1])).get('stagingPath',''))" "$MARKER")
  if [ -d "$STAGED" ]; then
    python3 - "$STAGED" <<'MODES'
import os, stat as st, sys
root = sys.argv[1]
bad = []
def check(path):
    s = os.lstat(path)
    if st.S_ISLNK(s.st_mode):
        return
    mode = s.st_mode & 0o7777
    why = []
    if getattr(s, "st_flags", 0): why.append("st_flags set")
    if mode & 0o7000: why.append("setuid/setgid/sticky")
    if mode & 0o022: why.append("group/other writable")
    if st.S_ISDIR(s.st_mode):
        if mode & 0o005 != 0o005: why.append("dir not other r-x")
    elif st.S_ISREG(s.st_mode):
        if mode & 0o004 != 0o004: why.append("not other-readable")
        if not (mode & 0o111 == 0 or mode & 0o101 == 0o101):
            why.append("odd exec bits")
    else:
        why.append("not a file, directory or symlink")
    if why:
        bad.append((oct(mode), ", ".join(why), os.path.relpath(path, root)))
check(root)
for base, dirs, files in os.walk(root):
    for name in dirs + files:
        check(os.path.join(base, name))
if bad:
    noun = "entry breaks" if len(bad) == 1 else "entries break"
    print(f"  FAIL  {len(bad)} {noun} the staged-bundle permission rule:")
    for mode, why, rel in bad[:10]:
        print(f"        {mode} {why}")
        print(f"          {rel}")
else:
    print("  ok    every entry satisfies the staged-bundle permission rule")
MODES
  fi
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
  would report "Unable to confirm update installation handoff" — except two.
  A running app whose executable is no longer on disk, and a transaction the
  app cancelled after 'prepared', are the restart step giving up before the
  commit, which the app reports as "Unable to prepare update installation".
  Quit the app and relaunch it; the stage is fine and is used as it is.

  All ok, and "helper scheduled" is the last thing in the helper's log: the
  refusal is in a check this script cannot see from outside — the caller's
  live process identity, or the signed release descriptor. Press Check for
  updates to re-stage (a stale stage is the common cause), then try again.
GUIDE

say ""
say "Report written to $REPORT"
