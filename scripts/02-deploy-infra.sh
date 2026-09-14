#!/usr/bin/env bash
# =============================================================================
# 02-deploy-infra.sh
#
# Deploys infra/main.bicep: an App Service Plan + Web App for the MCP server,
# and an API Management (Basic v2) instance that proxies /mcp requests to it.
#
# NOTE: API Management Basic v2 is designed to provision in just a few
# minutes (unlike the classic tiers, which can take 45-70 min).
#
# Usage:
#   ./scripts/02-deploy-infra.sh <resource-group> [location]
#
# Requires .env.mcp-demo (created by 01-create-app-registration.sh) or the
# API_APP_CLIENT_ID / TENANT_ID environment variables to already be set.
# =============================================================================
set -euo pipefail

# Always operate relative to the repo root, regardless of the caller's
# current directory, so .env.mcp-demo / .deploy-outputs.json are always read
# from and written to the same place no matter where this script is invoked from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RESOURCE_GROUP="${1:?Usage: $0 <resource-group> [location]}"
LOCATION="${2:-westus2}"
NAME_PREFIX="${NAME_PREFIX:-mcpdemo}"

if [[ -f .env.mcp-demo ]]; then
  # shellcheck disable=SC1091
  source .env.mcp-demo
fi

: "${API_APP_CLIENT_ID:?Set API_APP_CLIENT_ID (run 01-create-app-registration.sh first)}"
: "${TENANT_ID:?Set TENANT_ID (run 01-create-app-registration.sh first)}"

read -rp "Publisher email for API Management (required): " APIM_PUBLISHER_EMAIL

echo "==> Creating resource group '$RESOURCE_GROUP' in $LOCATION..."
az group create --name "$RESOURCE_GROUP" --location "$LOCATION" --output none

echo "==> Deploying infra/main.bicep (App Service + APIM Basic v2, a few minutes)..."
az deployment group create \
  --resource-group "$RESOURCE_GROUP" \
  --template-file infra/main.bicep \
  --parameters \
      namePrefix="$NAME_PREFIX" \
      location="$LOCATION" \
      tenantId="$TENANT_ID" \
      apiClientId="$API_APP_CLIENT_ID" \
      apimPublisherEmail="$APIM_PUBLISHER_EMAIL" \
  --query "properties.outputs" -o json | tee .deploy-outputs.json

echo ""
echo "==> Deployment complete. Outputs saved to .deploy-outputs.json"
echo "==> Next: ./scripts/03-deploy-app.sh $RESOURCE_GROUP"
