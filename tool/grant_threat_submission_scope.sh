#!/usr/bin/env bash
# Lets "Report phishing" reach Microsoft for a tenant.
#
# On a Microsoft account, Report phishing submits the message through Graph's
# threat submission API. Its delegated scope, ThreatSubmission.ReadWrite, is one
# Microsoft marks *admin consent required*: NightMail asks for it incrementally
# (the first time a user reports phishing — see
# MicrosoftAuthService.threatSubmissionScope), but a tenant whose administrator
# has not consented answers that request with AADSTS65001 and nothing can be
# reported. Run this once per tenant, signed in to the Azure CLI as an
# administrator of that tenant.
#
# Two cases, decided by where the app registration lives:
#   * The signed-in tenant *owns* the registration: the permission is added to
#     it and admin consent granted, both through the CLI.
#   * Another tenant (the registration is multi-tenant): the registration cannot
#     be edited from here, so the Entra admin-consent URL is opened instead and
#     the administrator consents in the browser. The redirect lands on the
#     app's own nightmail:// URI, which is expected — nothing is listening for
#     it, and the consent has already been recorded by then.
#
# Usage: tool/grant_threat_submission_scope.sh [APP_ID]
#   APP_ID defaults to $AZURE_CLIENT_ID — the same value the app is built with
#   (--dart-define=AZURE_CLIENT_ID=…).
set -euo pipefail

APP_ID="${1:-${AZURE_CLIENT_ID:-}}"
if [ -z "$APP_ID" ]; then
  echo "usage: $0 <application (client) id>   — or export AZURE_CLIENT_ID" >&2
  exit 2
fi
if ! command -v az >/dev/null 2>&1; then
  echo "The Azure CLI is required: brew install azure-cli" >&2
  exit 2
fi
if ! az account show >/dev/null 2>&1; then
  az login --allow-no-subscriptions >/dev/null
fi

GRAPH_APP_ID=00000003-0000-0000-c000-000000000000
SCOPE_NAME=ThreatSubmission.ReadWrite
TENANT_ID=$(az account show --query tenantId -o tsv)

if az ad app show --id "$APP_ID" >/dev/null 2>&1; then
  SCOPE_ID=$(az ad sp show --id "$GRAPH_APP_ID" \
    --query "oauth2PermissionScopes[?value=='$SCOPE_NAME'].id | [0]" -o tsv)
  if [ -z "$SCOPE_ID" ]; then
    echo "Microsoft Graph does not expose $SCOPE_NAME in this cloud." >&2
    exit 1
  fi
  # Idempotent: listing a permission the registration already carries changes
  # nothing. (The CLI prints a hint about `az ad app permission grant`; the
  # admin-consent step below is the one that matters here.)
  az ad app permission add --id "$APP_ID" --api "$GRAPH_APP_ID" \
    --api-permissions "$SCOPE_ID=Scope" >/dev/null
  # Needs Global Administrator or Privileged Role Administrator; anyone else
  # gets a 403 here, which is the tenant's answer rather than the script's.
  az ad app permission admin-consent --id "$APP_ID"
  echo "Granted $SCOPE_NAME (delegated) on $APP_ID with admin consent for tenant $TENANT_ID."
else
  URL="https://login.microsoftonline.com/$TENANT_ID/v2.0/adminconsent?client_id=$APP_ID&scope=https%3A%2F%2Fgraph.microsoft.com%2F$SCOPE_NAME&redirect_uri=nightmail%3A%2F%2Fauth-callback"
  echo "Tenant $TENANT_ID does not own app registration $APP_ID."
  echo "Consent is given in the browser instead — sign in there as an administrator of this tenant:"
  echo "  $URL"
  if command -v open >/dev/null 2>&1; then open "$URL"; fi
fi

echo "Accounts already signed in to NightMail will be asked to sign in once the first time they report phishing."
