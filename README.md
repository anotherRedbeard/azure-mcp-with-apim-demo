# MCP Server on Azure App Service, proxied by API Management

A minimal, learning-focused starter that shows how to:

- Build an [MCP](https://modelcontextprotocol.io) server in **.NET 10** using the official `ModelContextProtocol.AspNetCore` SDK
- Host it on **Azure App Service** as plain code (no containers)
- Front it with **Azure API Management (Basic v2)** as a gateway (subscription-key protected)
- Secure it with **Microsoft Entra ID** so only signed-in users/apps can call it
- Call it from a simple **console test client** using `DefaultAzureCredential`

The MCP server is themed as a fictional **health insurance member-services** assistant, with three simple tools:

| Tool | What it does |
|---|---|
| `get_claim_status` | Looks up a fake claim's status by claim ID |
| `find_in_network_provider` | Finds fake in-network providers by specialty + ZIP prefix |
| `estimate_member_cost` | Estimates a member's out-of-pocket cost for a procedure |

All data is fake and stored in-memory — this is a teaching sample, not production code.

> The MCP C# SDK exposes .NET method names as **snake_case** tool names (e.g. `GetClaimStatus` -> `get_claim_status`) — that's what MCP clients actually see and call.

## Architecture

```
Console TestClient  --(HTTPS + user token + subscription key)-->  APIM (Basic v2)  --(HTTPS + APIM's own token)-->  App Service (MCP server)
        |                                                                  |
        +---- Entra ID: user-delegated token for api://<appId>/access_as_user
                                                                            |
                                                          APIM's system-assigned managed identity
                                                          mints its own app-only token for the same
                                                          resource, and the backend trusts *only* that.
```

- **Auth model — two hops, two different tokens:**
  1. **User -> APIM.** A single Entra ID App Registration represents the MCP API. It exposes a delegated, *user-consentable* scope (`access_as_user`) - no client secret, no separate client app, no admin consent required. The test client signs in as the user (`az login`) and `DefaultAzureCredential` silently mints a token for that scope. **APIM validates this token itself** (a `validate-jwt` policy checking issuer + audience against this app registration) before forwarding anything.
  2. **APIM -> App Service.** APIM does **not** forward the user's token to the backend. Instead, it uses its own **system-assigned managed identity** to mint a fresh, app-only access token for the same API (an `authentication-managed-identity` policy), and swaps it into the `Authorization` header before calling the Web App. The backend (`McpServer/Program.cs`) requires that token to carry the **`Mcp.Backend` app role** - a role assigned only to APIM's managed identity (`scripts/04-assign-apim-role.sh`).
  - **Why:** the backend never has to know or care about the calling user's identity/scopes - it only trusts "a call that really came through APIM." Even if someone found the raw `azurewebsites.net` URL and had a perfectly valid user token, the backend rejects it (403) for lacking the `Mcp.Backend` role. This is defense-in-depth beyond just the network boundary.
  - The setup script *attempts* to pre-authorize the Azure CLI's first-party app so `az login --scope ...` skips the consent screen. Some locked-down tenants (e.g. Microsoft-internal MCAP tenants) don't allow this, in which case you'll simply see a **one-time interactive consent prompt** the first time you run `az login --scope api://<appId>/access_as_user` - click Accept and you're done.
- **APIM**: also requires a subscription key on every call (coarse-grained, per-client-app gating, independent of the JWT/role checks above). The MCP server is exposed as APIM's **native MCP server resource** (`Microsoft.ApiManagement/service/apis` with `type: 'mcp'`, in *passthrough* mode) rather than a generic REST API - this is a newer (preview) APIM capability purpose-built for MCP traffic. A few things we learned the hard way while wiring this up (documented in the Bicep comments too):
  - The client-facing URL is `<gatewayUrl>/<api.path><mcpProperties.endpoints[].uriTemplate>` - this template sets `path: 'my-mcp-demo'` (configurable via the `mcpApiPath` parameter) and endpoint `uriTemplate: '/mcp'`, so the public URL is `<gatewayUrl>/my-mcp-demo/mcp`. Set `mcpApiPath` to `''` for just `<gatewayUrl>/mcp`.
  - `mcpProperties.endpoints` must be a JSON **object** keyed by endpoint name (e.g. `{"message": {"uriTemplate": "/mcp"}}`), not the array shown in some Microsoft docs - the live ARM API only accepts the object form.
  - A passthrough MCP API needs an explicit `backendId` pointing at a `Microsoft.ApiManagement/service/backends` resource. Without it, every `tools/call` fails with an internal APIM gateway error.
  - APIM's MCP gateway answers `initialize`/`tools/list` itself and forwards each `tools/call` to the backend as an independent, session-less HTTP request - so the backend MCP server must run in **stateless** session mode (the SDK's default; just don't turn on `HttpServerSessionMode.Stateful`).
  - Bicep's triple-quoted (`'''`) strings are **raw literals** - they don't support `${...}` interpolation. The APIM policy XML is built with `{{PLACEHOLDER}}` tokens + `replace()` instead.
  - A `validate-jwt` policy's `<openid-config>` only supplies the issuer(s)/keys for **one** token version. `az account get-access-token` returns a **v1.0** token (`iss: https://sts.windows.net/<tid>/`), so the policy lists both the v1 and v2 issuers explicitly in `<issuers>` rather than relying solely on the v2.0 openid-config's inferred issuer.
  - App Insights + an APIM diagnostic (wired up in `main.bicep`) is what let us see all of this - see `appInsightsName` in the deployment output.
- **App Service Plan quota**: App Service SKU quota (any tier - F1/B1/S1/P1v3, etc.) is granted per-region per-subscription. Sandbox/sponsored subscriptions may show 0 quota for every tier in a popular region like `eastus` while a region like `westus2` has quota available. That's why this template defaults to `westus2` - if you hit `InternalSubscriptionIsOverQuotaForSku`, try a different region (or request a quota increase at https://aka.ms/antquotahelp for your preferred one).

## ⏱️ Timing expectations

- App Service Plan + Web App + code deploy: **a few minutes**
- API Management **Basic v2**: this v2 tier was purpose-built to provision in **a few minutes** (unlike the classic Developer/Basic/Standard/Premium tiers, which can take 45–70 minutes). Both the Web App and APIM should be ready shortly after `02-deploy-infra.sh` finishes.

## Prerequisites

- Azure CLI (`az`), logged in (`az login`) with rights to create app registrations and resources
- .NET 10 SDK
- `zip` and `python3` (used by the helper scripts)

## Quickstart

```bash
# 1. Create the Entra ID App Registration (the MCP API itself)
./scripts/01-create-app-registration.sh

# 2. Deploy infra: App Service Plan, Web App, APIM Basic v2 (a few minutes)
./scripts/02-deploy-infra.sh my-mcp-demo-rg westus2

# 3. Deploy the MCP server code to the Web App (usable in ~1-2 min, doesn't need to wait for APIM)
./scripts/03-deploy-app.sh my-mcp-demo-rg

# 4. Let APIM's managed identity call the backend (grants it the "Mcp.Backend" app role)
./scripts/04-assign-apim-role.sh my-mcp-demo-rg

# 5. Print the environment variables + sign-in command for the test client
./scripts/05-print-test-client-config.sh my-mcp-demo-rg
```

Copy/paste the `export` lines and `az login --scope ...` command printed by step 5, then run the test client:

```bash
cd src/TestClient
dotnet run
```

You should see the three tools listed and their fake results printed.

## Project layout

```
infra/main.bicep         Bicep for App Service Plan + Web App + APIM (Basic v2)
src/McpServer/            The MCP server (ASP.NET Core, Entra ID JWT auth, 3 demo tools)
src/TestClient/           Console app: DefaultAzureCredential -> MCP client -> APIM -> App Service
scripts/                  Helper scripts to create the app registration, deploy, and configure the client
```

## Running the MCP server locally

```bash
cd src/McpServer
# Edit appsettings.Development.json or use user-secrets to set:
#   AzureAd:TenantId, AzureAd:ClientId  (from step 1 above)
dotnet run
```

> The server always requires the caller to hold the `Mcp.Backend` app role (see
> [Architecture](#architecture)) — including when run locally. Only APIM's
> managed identity is assigned that role, so a direct call (even from
> `src/TestClient` pointed at `http://localhost:5080/mcp`) will authenticate
> fine but get a **403**. To exercise the server end-to-end, always go through
> APIM — there's no supported "skip APIM" path, by design.

## Cleaning up

```bash
az group delete --name my-mcp-demo-rg --yes --no-wait
```

APIM instances are **soft-deleted** by default - deleting the resource group frees up the name for a few minutes, but Azure keeps the APIM instance recoverable behind the scenes for a few days. If you want to fully purge it right away (e.g. to immediately reuse the same `namePrefix` or free up the name for good), run:

```bash
az apim deletedservice list -o table
az apim deletedservice purge --service-name <apim-name> --location <location>
```

Also consider deleting the Entra ID app registration if you no longer need it:

```bash
az ad app delete --id <API_APP_CLIENT_ID>
```

## Next steps (left out of this starter on purpose)

- Custom domain + TLS certificate on APIM
- CI/CD pipeline instead of the manual `az webapp deploy` step
- Replacing the in-memory demo data with a real data source
