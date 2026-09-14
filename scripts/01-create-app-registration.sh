#!/usr/bin/env bash
# =============================================================================
# 01-create-app-registration.sh
#
# Creates a single Entra ID App Registration that represents the MCP server
# API. It exposes a user-consentable delegated scope ("access_as_user") so
# that DefaultAzureCredential (via `az login`) can obtain a user token for it
# without needing a separate client app registration, secret, or admin
# consent.
#
# Usage:
#   ./scripts/01-create-app-registration.sh
#
# Requires: az CLI logged in (az login) with permission to create app
# registrations in the tenant.
# =============================================================================
set -euo pipefail

# Always operate relative to the repo root, regardless of the caller's
# current directory, so .env.mcp-demo / .deploy-outputs.json are always read
# from and written to the same place no matter where this script is invoked from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

APP_NAME="${APP_NAME:-mcp-insurance-demo-api}"

echo "==> Creating app registration '$APP_NAME'..."
APP_ID=$(az ad app create \
  --display-name "$APP_NAME" \
  --sign-in-audience AzureADMyOrg \
  --query appId -o tsv)

echo "==> App registration created: $APP_ID"

# Set the Application ID URI (must be set before scopes referencing it).
echo "==> Setting identifier URI..."
az ad app update --id "$APP_ID" --identifier-uris "api://$APP_ID"

# Define a user-consentable delegated scope: access_as_user.
# Idempotency: if this app already has an "access_as_user" scope (e.g. from a
# prior run of this script), reuse its existing ID. Graph rejects attempts to
# replace an existing *enabled* scope's ID in place ("cannot be deleted or
# updated unless disabled first"), so we must not generate a fresh one here.
EXISTING_SCOPE_ID=$(az ad app show --id "$APP_ID" \
  --query "api.oauth2PermissionScopes[?value=='access_as_user'].id | [0]" -o tsv)

if [[ -n "$EXISTING_SCOPE_ID" && "$EXISTING_SCOPE_ID" != "None" ]]; then
  SCOPE_ID="$EXISTING_SCOPE_ID"
  echo "==> Reusing existing delegated scope 'access_as_user' (id: $SCOPE_ID)..."
else
  SCOPE_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  echo "==> Adding delegated scope 'access_as_user' (id: $SCOPE_ID)..."
  az ad app update --id "$APP_ID" --set api="{
    \"oauth2PermissionScopes\": [
      {
        \"id\": \"$SCOPE_ID\",
        \"adminConsentDescription\": \"Allow the app to call the MCP insurance demo API on behalf of the signed-in user.\",
        \"adminConsentDisplayName\": \"Access MCP insurance demo API\",
        \"userConsentDescription\": \"Allow this app to access the MCP insurance demo API on your behalf.\",
        \"userConsentDisplayName\": \"Access MCP insurance demo API\",
        \"value\": \"access_as_user\",
        \"type\": \"User\",
        \"isEnabled\": true
      }
    ]
  }"
fi

# Define an application (app-only) role: "Mcp.Backend". This is what lets APIM's
# system-assigned managed identity call the MCP server as *itself* (a trusted
# service-to-service caller) rather than forwarding the end user's own token.
# allowedMemberTypes=["Application"] means only service principals (not users)
# can ever be assigned this role.
EXISTING_ROLE_ID=$(az ad app show --id "$APP_ID" \
  --query "appRoles[?value=='Mcp.Backend'].id | [0]" -o tsv)

if [[ -n "$EXISTING_ROLE_ID" && "$EXISTING_ROLE_ID" != "None" ]]; then
  ROLE_ID="$EXISTING_ROLE_ID"
  echo "==> Reusing existing app role 'Mcp.Backend' (id: $ROLE_ID)..."
else
  ROLE_ID=$(python3 -c "import uuid; print(uuid.uuid4())" 2>/dev/null || uuidgen | tr '[:upper:]' '[:lower:]')
  echo "==> Adding app role 'Mcp.Backend' (id: $ROLE_ID)..."
  az ad app update --id "$APP_ID" --set appRoles="[
    {
      \"id\": \"$ROLE_ID\",
      \"allowedMemberTypes\": [\"Application\"],
      \"description\": \"Allows APIM's managed identity to call the MCP backend as a trusted service, after APIM has validated the end user's own token.\",
      \"displayName\": \"MCP Backend Caller\",
      \"value\": \"Mcp.Backend\",
      \"isEnabled\": true
    }
  ]"
fi

# Ensure a service principal (enterprise app) exists for this app registration
# so a Graph app role assignment can target it (04-assign-apim-role.sh needs
# this app's service principal object ID as the assignment's "resource").
az ad sp create --id "$APP_ID" >/dev/null 2>&1 || true

# Give Graph a moment to propagate the new scope/role before referencing them.
sleep 10

# Best-effort: pre-authorize the Azure CLI's well-known first-party client app
# so `az login --scope api://<appId>/access_as_user` skips the consent prompt.
# This requires a service principal for the Azure CLI app to already exist in
# this tenant, which some locked-down tenants (e.g. Microsoft-internal MCAP
# tenants) don't allow creating on demand. If it fails, that's fine — the
# scope's consent type is "User", so `az login --scope ...` will simply show a
# one-time interactive consent prompt instead, which the signed-in user can
# accept themselves (no admin needed).
AZURE_CLI_CLIENT_ID="04b07795-8ddb-461a-bbee-02f9e1bf7b46"
echo "==> Attempting to pre-authorize Azure CLI client app ($AZURE_CLI_CLIENT_ID) (best-effort)..."
if az ad app update --id "$APP_ID" --set api="{
  \"preAuthorizedApplications\": [
    {
      \"appId\": \"$AZURE_CLI_CLIENT_ID\",
      \"delegatedPermissionIds\": [\"$SCOPE_ID\"]
    }
  ]
}" 2>/tmp/preauth-error.log; then
  echo "    Pre-authorized. az login will not prompt for consent."
else
  echo "    Skipped (not permitted in this tenant) — you'll see a one-time"
  echo "    consent prompt the first time you run 'az login --scope ...'."
  echo "    Details: $(cat /tmp/preauth-error.log)"
fi

TENANT_ID=$(az account show --query tenantId -o tsv)

echo ""
echo "================================================================"
echo " App registration ready!"
echo "   API_APP_CLIENT_ID = $APP_ID"
echo "   TENANT_ID         = $TENANT_ID"
echo ""
echo " Save these — you'll pass them to 02-deploy-infra.sh and use them"
echo " to configure src/TestClient (API_APP_CLIENT_ID, TENANT_ID env vars)."
echo "================================================================"

# Persist for the other scripts to pick up automatically.
cat > .env.mcp-demo <<EOF
API_APP_CLIENT_ID=$APP_ID
TENANT_ID=$TENANT_ID
EOF
echo "Wrote values to .env.mcp-demo"
