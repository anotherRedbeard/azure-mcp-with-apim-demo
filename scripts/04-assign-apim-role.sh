#!/usr/bin/env bash
# =============================================================================
# 04-assign-apim-role.sh
#
# Grants APIM's system-assigned managed identity the "Mcp.Backend" app role on
# the MCP API's app registration. This is what lets APIM authenticate to the
# MCP server as itself (see infra/main.bicep's mcpApiPolicy, which swaps the
# end user's token for one of APIM's own before forwarding to the backend) and
# have that call actually authorized (McpServer/Program.cs requires this
# role on every request).
#
# Must be run AFTER 02-deploy-infra.sh (APIM's managed identity must exist)
# and after 01-create-app-registration.sh (the "Mcp.Backend" role must exist).
#
# Usage:
#   ./scripts/04-assign-apim-role.sh <resource-group>
# =============================================================================
set -euo pipefail

# Always operate relative to the repo root, regardless of the caller's
# current directory, so .env.mcp-demo / .deploy-outputs.json are always read
# from and written to the same place no matter where this script is invoked from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RESOURCE_GROUP="${1:?Usage: $0 <resource-group>}"

if [[ -f .env.mcp-demo ]]; then
  # shellcheck disable=SC1091
  source .env.mcp-demo
fi
: "${API_APP_CLIENT_ID:?Set API_APP_CLIENT_ID (run 01-create-app-registration.sh first)}"

if [[ ! -f .deploy-outputs.json ]]; then
  echo "ERROR: .deploy-outputs.json not found. Run 02-deploy-infra.sh first." >&2
  exit 1
fi

APIM_PRINCIPAL_ID=$(python3 -c "import json;print(json.load(open('.deploy-outputs.json'))['apimPrincipalId']['value'])")

echo "==> Looking up the MCP API's service principal and 'Mcp.Backend' role..."
API_SP_ID=$(az ad sp show --id "$API_APP_CLIENT_ID" --query id -o tsv)
ROLE_ID=$(az ad app show --id "$API_APP_CLIENT_ID" \
  --query "appRoles[?value=='Mcp.Backend'].id | [0]" -o tsv)

if [[ -z "$ROLE_ID" || "$ROLE_ID" == "None" ]]; then
  echo "ERROR: 'Mcp.Backend' app role not found on app $API_APP_CLIENT_ID." >&2
  echo "       Re-run ./scripts/01-create-app-registration.sh to add it." >&2
  exit 1
fi

echo "==> Assigning 'Mcp.Backend' role to APIM's managed identity ($APIM_PRINCIPAL_ID)..."
az rest --method post \
  --uri "https://graph.microsoft.com/v1.0/servicePrincipals/$APIM_PRINCIPAL_ID/appRoleAssignments" \
  --headers "Content-Type=application/json" \
  --body "{
    \"principalId\": \"$APIM_PRINCIPAL_ID\",
    \"resourceId\": \"$API_SP_ID\",
    \"appRoleId\": \"$ROLE_ID\"
  }" >/dev/null 2>/tmp/role-assign-error.log \
  && echo "==> Done. APIM can now call the MCP backend as itself." \
  || {
    if grep -q "Permission being assigned already exists" /tmp/role-assign-error.log; then
      echo "==> Already assigned. Nothing to do."
    else
      echo "ERROR assigning role:" >&2
      cat /tmp/role-assign-error.log >&2
      exit 1
    fi
  }
