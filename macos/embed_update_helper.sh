#!/bin/sh
#
# Builds, signs and embeds desktop_updater's privileged install helper into the
# app bundle. Run as an Xcode build phase on the Runner target.
#
# Without it `Contents/Helpers/DesktopUpdaterInstallHelper` does not exist, and
# the in-app updater fails at the very last step: the native side reads the
# sealed release-key policy out of that binary's signature before it will accept
# a staged update, so an update downloads and verifies and then reports "Unable
# to prepare update installation" with no detail.
#
# This is a thin wrapper around the package's own embed_install_helper.sh. It
# exists to do the three things that script leaves to the host project:
#
#   * find the package, wherever pub put it;
#   * derive DESKTOP_UPDATER_SEALED_POLICY_SHA256 from the policy file instead
#     of carrying a copy of the digest in project.pbxproj, where the two would
#     silently drift the first time somebody edited the policy;
#   * stay out of the way of debug builds.

set -eu

fail() {
  echo "error: embed_update_helper: $*" >&2
  exit 1
}

# `--locate` prints where the helper sources were found and stops, so the
# lookup below can be checked from a shell (or CI) without a signed build.
locate_only=false
[ "${1:-}" = "--locate" ] && locate_only=true

if [ "$locate_only" = false ]; then
# Release only. The helper is what *installs* an update, and nothing installs
# one from a `flutter run` build — while a per-architecture `swift build` on
# every debug build is a large tax on the edit loop. It also keeps the helper's
# signature matched to one policy: an ad-hoc signed debug build cannot satisfy
# the Developer ID requirement the sealed policy names, so a debug build that
# embedded a helper would need a second policy to go with it.
if [ "${CONFIGURATION:-}" != "Release" ]; then
  echo "embed_update_helper: skipping in ${CONFIGURATION:-unknown} configuration"
  exit 0
fi

# An ad-hoc or unsigned build gets no helper. The sealed policy names a
# Developer ID designated requirement, so the package's own layout check would
# refuse the helper it had just signed and fail the build — and a fork PR, or
# anyone building release locally without the certificate, is meant to keep
# building exactly as it did before. Such a build cannot install an in-app
# update regardless: staging verifies the downloaded app against the *running*
# app's team identifier.
identity=${EXPANDED_CODE_SIGN_IDENTITY:-${CODE_SIGN_IDENTITY:-}}
case "$identity" in
  "" | "-")
    echo "embed_update_helper: skipping, this build is not signed with an identity"
    exit 0
    ;;
esac
fi

project_dir=${PROJECT_DIR:?PROJECT_DIR is required}
policy="$project_dir/Runner/DesktopUpdaterHelperPolicy.json"
[ "$locate_only" = true ] || [ -f "$policy" ] || fail "sealed policy is missing: $policy"

# Where pub put the package. Three ways in, tried in order; each is rebuilt by
# `flutter pub get`, so all of them follow a version bump without this file
# being touched.
#
#  1. Flutter's Swift Package Manager integration links every plugin's package
#     directory under Flutter/ephemeral/Packages/.packages/<name>-<version> —
#     for desktop_updater that is <pkg>/macos/desktop_updater, and the helper
#     sources are its sibling <pkg>/macos/install_helper. This is the live path
#     now that the project has no CocoaPods integration.
#  2. The CocoaPods symlink farm, for a checkout that still carries one.
#  3. .dart_tool/package_config.json, which pub writes pretty-printed — read
#     as JSON, not grepped for a single-line shape that has not been written
#     for years. The CI build after CocoaPods was removed failed on exactly
#     that: the symlink farm was gone and the one-line regex never matched.
helper_dir=""
for link in "$project_dir"/Flutter/ephemeral/Packages/.packages/desktop_updater-*; do
  [ -d "$link" ] || continue
  package_dir=$(cd "$link" 2>/dev/null && pwd -P) || continue
  candidate="$(dirname "$package_dir")/install_helper"
  if [ -d "$candidate" ]; then
    helper_dir=$candidate
    break
  fi
done
if [ -z "$helper_dir" ]; then
  legacy="$project_dir/Flutter/ephemeral/.symlinks/plugins/desktop_updater/macos/install_helper"
  [ -d "$legacy" ] && helper_dir=$legacy
fi
if [ -z "$helper_dir" ] && [ -x /usr/bin/python3 ]; then
  config="$project_dir/../.dart_tool/package_config.json"
  root=$(/usr/bin/python3 - "$config" 2>/dev/null <<'PY' || true
import json, os, sys
path = sys.argv[1]
for p in json.load(open(path, encoding="utf-8"))["packages"]:
    if p["name"] == "desktop_updater":
        uri = p["rootUri"]
        if uri.startswith("file://"):
            print(uri[len("file://"):])
        else:
            # Relative roots are relative to the config file's directory.
            print(os.path.normpath(os.path.join(os.path.dirname(path), uri)))
        break
PY
  )
  [ -n "$root" ] && [ -d "$root/macos/install_helper" ] && helper_dir="$root/macos/install_helper"
fi
[ -n "$helper_dir" ] && [ -d "$helper_dir" ] ||
  fail "cannot locate desktop_updater's install_helper; run flutter pub get"

if [ "$locate_only" = true ]; then
  echo "$helper_dir"
  exit 0
fi

# The digest the package script checks against, and the digest the *app* checks
# at install time, are computed differently: the script hashes the file with one
# trailing newline stripped, while DesktopUpdaterPlugin re-serialises the JSON
# through JSONSerialization with sorted keys and hashes that. They agree only
# while the file is already in that canonical form — compact, keys sorted — so a
# reformatted policy would sail through the build and fail on the user's machine
# with nothing to point at. Check it here, where it is cheap to say so.
if [ -x /usr/bin/python3 ]; then
  /usr/bin/python3 - "$policy" <<'PY' || fail "DesktopUpdaterHelperPolicy.json is not canonical JSON; re-emit it with sorted keys and no whitespace"
import json, sys
raw = open(sys.argv[1], encoding="utf-8").read()
if raw.endswith("\n"):
    raw = raw[:-1]
canonical = json.dumps(
    json.loads(raw), sort_keys=True, separators=(",", ":"), ensure_ascii=False
)
sys.exit(0 if raw == canonical else 1)
PY
fi

policy_sha256=$(/usr/bin/perl -0pe 's/\r?\n\z//' "$policy" |
  /usr/bin/shasum -a 256 | /usr/bin/awk '{print $1}')
[ -n "$policy_sha256" ] || fail "could not digest $policy"

# --------------------------------------------------------------------------
# Build from a copy whose main.swift says *why* it refused.
#
# Every way the helper can turn a request down — a caller whose signature did
# not check out, a stage that no longer matches its provenance, an unsupported
# strategy — throws a `MacOneShotAuthorizationError` that reaches main.swift's
# final `catch`, which writes the single word "helperBootstrapFailure" and
# exits. Nothing is recorded: `MacOneShotServiceRuntime` logs `helper
# scheduled` when it starts and then nothing until a commit is *accepted*, so
# a refusal is silent by construction. Meanwhile the app converts every error
# the handoff can raise into one sentence ("Unable to confirm update
# installation handoff"), so between the two there is no way at all to learn
# which check failed — which is exactly how a macOS update failure became
# unfixable by inspection.
#
# The patch is four lines and changes no behaviour: the same error, the same
# exit code, with the error's own description carried into the diagnostics the
# helper already writes to ~/Library/Logs/DesktopUpdater/events.jsonl and onto
# the stderr it already inherits from the app.
#
# It is applied to a copy under DERIVED_FILE_DIR rather than to the package in
# ~/.pub-cache, which is shared and is rebuilt by `flutter pub get`. If the
# text it rewrites is not found — a package upgrade moved it — the build fails
# here rather than silently shipping a helper that has gone quiet again.
# --------------------------------------------------------------------------
derived=${DERIVED_FILE_DIR:-${TARGET_TEMP_DIR:-}}
[ -n "$derived" ] || fail "DERIVED_FILE_DIR or TARGET_TEMP_DIR is required"
build_dir="$derived/install_helper_instrumented"
rm -rf "$build_dir"
mkdir -p "$(dirname "$build_dir")"
cp -R "$helper_dir" "$build_dir"

/usr/bin/python3 - "$build_dir/Sources/DesktopUpdaterInstallHelper/main.swift" <<'PY' \
  || fail "could not instrument main.swift; check whether desktop_updater moved its error handling"
import sys

path = sys.argv[1]
source = open(path, encoding="utf-8").read()
old = '''} catch {
    FileHandle.standardError.write(Data("helperBootstrapFailure\\n".utf8))
    Darwin.exit(70)
}'''
new = '''} catch {
    let reason = "\\(error)"
    MacHelperDiagnosticsRecorder().record(
        .helperScheduled,
        state: "refused",
        resultCode: "failure",
        detailCode: reason
    )
    FileHandle.standardError.write(
        Data("helperBootstrapFailure: \\(reason)\\n".utf8)
    )
    Darwin.exit(70)
}'''
if old not in source:
    sys.exit(1)
open(path, "w", encoding="utf-8").write(source.replace(old, new, 1))
PY

DESKTOP_UPDATER_HELPER_INFO_TEMPLATE="$build_dir/Configuration/Helper-Info.plist" \
DESKTOP_UPDATER_SEALED_POLICY_PATH="$policy" \
DESKTOP_UPDATER_SEALED_POLICY_SHA256="$policy_sha256" \
  "$build_dir/embed_install_helper.sh"
