#!/usr/bin/env bash
# =============================================================================
# 05-print-test-client-config.sh
#
# Prints the environment variables needed to run src/TestClient against the
# deployed MCP server through APIM.
#
# Usage:
#   ./scripts/05-print-test-client-config.sh <resource-group>
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
: "${TENANT_ID:?Set TENANT_ID (run 01-create-app-registration.sh first)}"

if [[ ! -f .deploy-outputs.json ]]; then
  echo "ERROR: .deploy-outputs.json not found. Run 02-deploy-infra.sh first." >&2
  exit 1
fi

APIM_NAME=$(python3 -c "import json;print(json.load(open('.deploy-outputs.json'))['apimName']['value'])")
MCP_ENDPOINT=$(python3 -c "import json;print(json.load(open('.deploy-outputs.json'))['apimMcpUrl']['value'])")

# Note: there is no `az apim subscription` command in the core CLI (only
# api/backend/product/etc. subgroups exist) — subscription keys must be
# fetched via the ARM REST API directly.
SUBSCRIPTION_ID=$(az account show --query id -o tsv)
SUBSCRIPTION_KEY=$(az rest --method post \
  --url "https://management.azure.com/subscriptions/$SUBSCRIPTION_ID/resourceGroups/$RESOURCE_GROUP/providers/Microsoft.ApiManagement/service/$APIM_NAME/subscriptions/mcp-demo-subscription/listSecrets?api-version=2023-09-01-preview" \
  --query primaryKey -o tsv 2>/dev/null || echo "<APIM still provisioning - retry later>")

cat <<EOF

# --- Run these before starting src/TestClient (or add to a .env file) ------
export API_APP_CLIENT_ID="$API_APP_CLIENT_ID"
export TENANT_ID="$TENANT_ID"
export MCP_ENDPOINT="$MCP_ENDPOINT"
export APIM_SUBSCRIPTION_KEY="$SUBSCRIPTION_KEY"
# -----------------------------------------------------------------------------

# One-time sign-in so DefaultAzureCredential can mint a token for this API:
az login --scope api://$API_APP_CLIENT_ID/access_as_user
EOF
