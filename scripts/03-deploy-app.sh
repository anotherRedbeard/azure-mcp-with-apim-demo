#!/usr/bin/env bash
# =============================================================================
# 03-deploy-app.sh
#
# Publishes the MCP server (src/McpServer) and zip-deploys it to the App
# Service Web App created by 02-deploy-infra.sh. This step alone takes
# roughly a minute or two — the Web App is usable as soon as it finishes,
# even while APIM (from step 2) is still provisioning.
#
# Usage:
#   ./scripts/03-deploy-app.sh <resource-group>
# =============================================================================
set -euo pipefail

# Always operate relative to the repo root, regardless of the caller's
# current directory, so .env.mcp-demo / .deploy-outputs.json are always read
# from and written to the same place no matter where this script is invoked from.
cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RESOURCE_GROUP="${1:?Usage: $0 <resource-group>}"

if [[ ! -f .deploy-outputs.json ]]; then
  echo "ERROR: .deploy-outputs.json not found. Run 02-deploy-infra.sh first." >&2
  exit 1
fi

WEB_APP_NAME=$(python3 -c "import json;print(json.load(open('.deploy-outputs.json'))['webAppName']['value'])")

echo "==> Publishing McpServer..."
PUBLISH_DIR=$(mktemp -d)
dotnet publish src/McpServer/McpServer.csproj -c Release -o "$PUBLISH_DIR"

echo "==> Zipping..."
ZIP_PATH=$(mktemp -t mcpserver-XXXXXX).zip
(cd "$PUBLISH_DIR" && zip -r -q "$ZIP_PATH" .)

echo "==> Deploying to Web App '$WEB_APP_NAME'..."
az webapp deploy \
  --resource-group "$RESOURCE_GROUP" \
  --name "$WEB_APP_NAME" \
  --src-path "$ZIP_PATH" \
  --type zip

rm -rf "$PUBLISH_DIR" "$ZIP_PATH"

echo ""
echo "==> Deployed. Health check:"
echo "    https://$WEB_APP_NAME.azurewebsites.net/healthz"
curl -sf "https://$WEB_APP_NAME.azurewebsites.net/healthz" && echo "" || echo "(app may still be starting up — retry in ~30s)"
