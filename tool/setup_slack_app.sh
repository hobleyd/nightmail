#!/usr/bin/env bash
# Creates the NightMail Slack app in one Slack workspace, from
# tool/slack_app_manifest.json, and prints the Client ID to paste into
# NightMail (Settings > General > Slack > Connect workspace…).
#
# Why one app per workspace: an *internal* app (installed only where it was
# created) keeps Slack's Tier 3 limits on conversations.history/replies. A
# distributed app that is not in the Slack Marketplace is cut to one call a
# minute, 15 messages each, which the chat window cannot live with. So each
# workspace gets its own app, and NightMail stores the Client ID per
# workspace (see docs/claude/chat.md).
#
# The manifest turns PKCE on (a public client: no secret ships in NightMail)
# and asks for user scopes only — Slack refuses bot scopes on a desktop
# redirect. Its redirect URLs are the loopback sign-in on desktop
# (http://localhost:34573/slack) and nightmail://slack-callback on iOS and
# Android. The same list is SlackWorkspaces.userScopes; keep them in step.
#
# Usage:
#   SLACK_CONFIG_TOKEN=xoxe.xoxp-… tool/setup_slack_app.sh
#     Creates the app with apps.manifest.create. The configuration token is
#     per workspace: https://api.slack.com/apps > "Your App Configuration
#     Tokens" > Generate Token (it lasts 12 hours).
#   tool/setup_slack_app.sh
#     With no token, opens Slack's "Create an app from a manifest" page with
#     the manifest filled in instead.
#   SLACK_CONFIG_TOKEN=xoxe.xoxp-… tool/setup_slack_app.sh --update A0123…
#     Brings an app made earlier up to this manifest (apps.manifest.update) —
#     a scope NightMail added since (emoji:read, for custom emoji). The app
#     id is on the app's Basic Information page. Then reconnect the
#     workspace in NightMail (Settings > General > Slack > Reconnect): a
#     token only gains a scope by signing in again.
#   tool/setup_slack_app.sh --update A0123…
#     With no token, opens that app's manifest page to paste it in by hand.
#
# Then install the app to the workspace (OAuth & Permissions > Install). A
# workspace that requires app approval sends that to its admins first.
set -euo pipefail

cd "$(dirname "$0")/.."
MANIFEST="tool/slack_app_manifest.json"
command -v python3 >/dev/null 2>&1 || {
  echo "python3 is required" >&2
  exit 2
}

if [ "${1:-}" = "--update" ]; then
  APP_ID="${2:?usage: tool/setup_slack_app.sh --update <app id>}"
  if [ -z "${SLACK_CONFIG_TOKEN:-}" ]; then
    echo "Opening the app's manifest page. Replace the manifest with"
    echo "${MANIFEST} (or add the missing user scopes), save, then reinstall"
    echo "the app if Slack asks and reconnect the workspace in NightMail."
    URL="https://app.slack.com/app-settings/${APP_ID}/app-manifest"
    open "$URL" 2>/dev/null || xdg-open "$URL" 2>/dev/null || echo "$URL"
    exit 0
  fi
  RESPONSE="$(curl -sS https://slack.com/api/apps.manifest.update \
    -H "Authorization: Bearer ${SLACK_CONFIG_TOKEN}" \
    --data-urlencode "app_id=${APP_ID}" \
    --data-urlencode "manifest@${MANIFEST}")"
  python3 - "$RESPONSE" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
if not r.get("ok"):
    print("Slack refused the update:", r.get("error"), file=sys.stderr)
    for e in r.get("errors", []):
        print("  ", e.get("pointer", ""), e.get("message", ""), file=sys.stderr)
    sys.exit(1)
print("Updated the Slack app.")
if r.get("permissions_updated"):
    print("Its scopes changed: reinstall it if Slack asks, then in NightMail")
    print("Settings > General > Slack > Reconnect.")
PY
  exit 0
fi

if [ -n "${SLACK_CONFIG_TOKEN:-}" ]; then
  RESPONSE="$(curl -sS https://slack.com/api/apps.manifest.create \
    -H "Authorization: Bearer ${SLACK_CONFIG_TOKEN}" \
    --data-urlencode "manifest@${MANIFEST}")"
  python3 - "$RESPONSE" <<'PY'
import json, sys
r = json.loads(sys.argv[1])
if not r.get("ok"):
    print("Slack refused the app:", r.get("error"), file=sys.stderr)
    for e in r.get("errors", []):
        print("  ", e.get("pointer", ""), e.get("message", ""), file=sys.stderr)
    sys.exit(1)
app = r["app_id"]
print("Created Slack app", app)
print()
print("Client ID:", r["credentials"]["client_id"])
print()
print("Next:")
print(f"  1. Install it: https://api.slack.com/apps/{app}/install-on-team")
print("  2. In NightMail: Settings > General > Slack > Connect workspace…,")
print("     paste the Client ID, and sign in.")
print("  To make it NightMail's default, build with")
print(f"  --dart-define=SLACK_CLIENT_ID={r['credentials']['client_id']}")
PY
  exit 0
fi

URL="$(python3 -c '
import json, sys, urllib.parse
m = json.load(open(sys.argv[1]))
print("https://api.slack.com/apps?new_app=1&manifest_json=" +
      urllib.parse.quote(json.dumps(m, separators=(",", ":"))))
' "$MANIFEST")"
echo "Opening Slack's create-from-manifest page. Pick the workspace, create"
echo "the app, install it (OAuth & Permissions), then copy its Client ID"
echo "(Basic Information > App Credentials) into NightMail: Settings > General"
echo "> Slack > Connect workspace…"
open "$URL" 2>/dev/null || xdg-open "$URL" 2>/dev/null || echo "$URL"
