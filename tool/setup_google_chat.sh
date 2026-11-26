#!/usr/bin/env bash
# Turns on Google Chat — and Google Meet, for calls from a chat avatar — for
# NightMail's Google Cloud project.
#
# The Chat pane and window reach Google Workspace accounts through the Google
# Chat API as the signed-in user (see docs/claude/chat.md). Google refuses
# every call with "Google Chat app not found" until the project that owns the
# OAuth client has
#   1. the Chat API enabled — done here with gcloud, and
#   2. a Chat app configured on the API's Configuration page — Google has no
#      API or CLI for that page, so this opens it with the values to enter.
# Run once per Cloud project, signed in to gcloud as an owner or editor.
#
# The chat scopes (chat.spaces.readonly, chat.spaces.create, chat.messages,
# chat.memberships.readonly, chat.users.readstate —
# GmailAuthService.chatScopes) are sensitive. On a
# project whose consent screen is published and verified, add them under
# Google Auth Platform > Data Access before shipping; until then Workspace
# users see the unverified-app warning on the chat consent.
#
# A call from a chat avatar makes a Google Meet meeting through the Meet REST
# API (meet.googleapis.com), under meetings.space.created
# (GmailAuthService.meetScope, asked for on the first call). That scope is
# sensitive too: add it under Data Access alongside the chat scopes. Without
# the API enabled, the call fails with "Google Meet is not set up for
# NightMail yet".
#
# Usage: tool/setup_google_chat.sh [OAUTH_CLIENT_ID]
#   OAUTH_CLIENT_ID defaults to $GOOGLE_CLIENT_ID — the value the app is built
#   with (--dart-define=GOOGLE_CLIENT_ID=…). Its leading number is the
#   project number.
set -euo pipefail

CLIENT_ID="${1:-${GOOGLE_CLIENT_ID:-}}"
if [ -z "$CLIENT_ID" ]; then
  echo "usage: $0 <OAuth client id>   — or export GOOGLE_CLIENT_ID" >&2
  exit 2
fi
PROJECT_NUMBER="${CLIENT_ID%%-*}"
if ! [[ "$PROJECT_NUMBER" =~ ^[0-9]+$ ]]; then
  echo "Cannot read a project number from client id '$CLIENT_ID'" >&2
  exit 2
fi
if ! command -v gcloud >/dev/null 2>&1; then
  echo "The Google Cloud CLI is required: brew install --cask google-cloud-sdk" >&2
  exit 2
fi
if ! gcloud auth print-access-token >/dev/null 2>&1; then
  gcloud auth login
fi

echo "Enabling the Google Chat API on project $PROJECT_NUMBER…"
gcloud services enable chat.googleapis.com --project "$PROJECT_NUMBER"

echo "Enabling the Google Meet REST API on project $PROJECT_NUMBER…"
gcloud services enable meet.googleapis.com --project "$PROJECT_NUMBER"

CONFIG_URL="https://console.cloud.google.com/apis/api/chat.googleapis.com/hangouts-chat?project=$PROJECT_NUMBER"
cat <<EOF

Now configure the Chat app (no API exists for this page). Enter:
  App name:        NightMail
  Avatar URL:      any https PNG, e.g. the app icon on the releases site
  Description:     Chat from NightMail
  Interactive features: OFF (NightMail is not a bot; it acts as the user)
  Visibility:      leave as is
Save. Chat works for Workspace accounts as soon as it saves.

Opening $CONFIG_URL
EOF
open "$CONFIG_URL" 2>/dev/null || true
