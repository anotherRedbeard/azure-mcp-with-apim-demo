// =============================================================================
// main.bicep — MCP server on App Service, proxied through APIM (Basic v2)
//
// Deploys:
//   - App Service Plan (Linux, B1) + Web App running the .NET 10 MCP server
//   - API Management (Basic v2) instance
//   - A native APIM "MCP server" resource (Microsoft.ApiManagement/service/apis
//     with type: 'mcp') configured as a *passthrough* server pointing at the
//     Web App, using the streamable HTTP transport. This is the APIM-native
//     way to expose an MCP server (as opposed to modeling it as a generic
//     REST API), giving MCP-aware discovery/tooling in APIM. Requires API
//     Management REST API version 2025-09-01-preview or later.
//
// NOTE: Unlike the classic APIM tiers (Developer/Basic/Standard/Premium,
// which can take 45-70 min to provision), the v2 tiers (Basic v2/Standard v2)
// are designed to provision in just a few minutes.
//
// NOTE: App Service Plan quota (of ANY tier - F1/B1/S1/P1v3, etc.) is granted
// per-region, per-subscription. Some regions (e.g. eastus, in some sandbox/
// sponsored subscriptions) can report 0 quota for every App Service SKU while
// other regions (e.g. westus2) have quota available. If deployment fails with
// "InternalSubscriptionIsOverQuotaForSku", try a different `location`.
// =============================================================================

@description('Short prefix used to name all resources, e.g. mcpdemo')
param namePrefix string = 'mcpdemo'

@description('Azure region for all resources')
param location string = 'westus2'

@description('Entra ID tenant ID used to validate tokens presented to the MCP server')
param tenantId string

@description('Client ID (Application ID) of the App Registration that represents this API')
param apiClientId string

@description('Publisher email required by API Management')
param apimPublisherEmail string

@description('Publisher name required by API Management')
param apimPublisherName string = 'MCP Demo'

@description('App Service Plan SKU name. B1 (Basic, Linux) is the default; switch to F1 (Free, Windows-only) if your subscription has no Basic-tier quota.')
param appServicePlanSkuName string = 'B1'

@description('App Service Plan SKU tier, matching appServicePlanSkuName (e.g. Basic for B1, Free for F1).')
param appServicePlanSkuTier string = 'Basic'

@description('Whether the App Service Plan/Web App runs on Linux. F1 (Free) is Windows-only, so this must be false when using F1.')
param appServicePlanIsLinux bool = true

@description('URL path segment under the APIM gateway for the MCP API, e.g. "my-mcp-demo" gives a client-facing URL of "<gatewayUrl>/my-mcp-demo/mcp". Leave empty for just "<gatewayUrl>/mcp".')
param mcpApiPath string = 'my-mcp-demo'

var appServicePlanName = '${namePrefix}-plan'
var webAppName = '${namePrefix}-mcp-${uniqueString(resourceGroup().id)}'
var apimName = '${namePrefix}-apim-${uniqueString(resourceGroup().id)}'
// Client-facing MCP URL segment: "<gatewayUrl>/<mcpApiPath>/mcp" (or just
// "<gatewayUrl>/mcp" if mcpApiPath is left empty).
var mcpPathSegment = empty(mcpApiPath) ? '' : '${mcpApiPath}/'

// -----------------------------------------------------------------------------
// App Service Plan
// -----------------------------------------------------------------------------
resource appServicePlan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: appServicePlanName
  location: location
  sku: {
    name: appServicePlanSkuName
    tier: appServicePlanSkuTier
  }
  kind: appServicePlanIsLinux ? 'linux' : 'app'
  properties: {
    reserved: appServicePlanIsLinux
  }
}

// -----------------------------------------------------------------------------
// App Service (Web App) hosting the MCP server, plain code (no container)
// -----------------------------------------------------------------------------
resource webApp 'Microsoft.Web/sites@2023-12-01' = {
  name: webAppName
  location: location
  properties: {
    serverFarmId: appServicePlan.id
    httpsOnly: true
    siteConfig: union(
      {
        alwaysOn: appServicePlanSkuName != 'F1' // F1 (Free) does not support Always On
        ftpsState: 'Disabled'
        minTlsVersion: '1.2'
        metadata: appServicePlanIsLinux ? [] : [
          {
            name: 'CURRENT_STACK'
            value: 'dotnetcore'
          }
        ]
        appSettings: [
          {
            name: 'AzureAd__TenantId'
            value: tenantId
          }
          {
            name: 'AzureAd__ClientId'
            value: apiClientId
          }
          {
            name: 'ASPNETCORE_ENVIRONMENT'
            value: 'Production'
          }
        ]
      },
      appServicePlanIsLinux ? { linuxFxVersion: 'DOTNETCORE|10.0' } : {}
    )
  }
}

// -----------------------------------------------------------------------------
// API Management (Basic v2)
// -----------------------------------------------------------------------------
resource apim 'Microsoft.ApiManagement/service@2023-09-01-preview' = {
  name: apimName
  location: location
  sku: {
    name: 'BasicV2'
    capacity: 1
  }
  // System-assigned managed identity: lets APIM authenticate to the MCP
  // backend as *itself* (see mcpApiPolicy below), instead of forwarding the
  // end user's own token straight through to the backend.
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    publisherEmail: apimPublisherEmail
    publisherName: apimPublisherName
  }
}

resource mcpApi 'Microsoft.ApiManagement/service/apis@2025-09-01-preview' = {
  parent: apim
  name: 'mcp-insurance-api'
  properties: {
    type: 'mcp'
    displayName: 'MCP Insurance Demo API'
    description: 'Passthrough MCP server proxying the .NET MCP insurance demo hosted on App Service.'
    // Client-facing URL = gatewayUrl + path + mcpProperties.endpoints[].uriTemplate.
    // With mcpApiPath = "my-mcp-demo" and endpoint uriTemplate "/mcp", the public
    // URL is "<gatewayUrl>/my-mcp-demo/mcp".
    path: mcpApiPath
    protocols: [
      'https'
    ]
    subscriptionRequired: true
    serviceUrl: 'https://${webApp.properties.defaultHostName}'
    // backendId is REQUIRED for passthrough MCP tool calls to route correctly.
    // Without an explicit Backend resource, APIM's MCP gateway throws an internal
    // "Value cannot be null (Parameter 'source')" error on every tools/call.
    backendId: mcpBackend.name
    mcpProperties: {
      transportType: 'streamable'
      endpoints: {
        message: {
          uriTemplate: '/mcp'
        }
      }
    }
  }
}

resource mcpBackend 'Microsoft.ApiManagement/service/backends@2023-09-01-preview' = {
  parent: apim
  name: 'mcp-insurance-backend'
  properties: {
    title: 'mcp-insurance-backend'
    url: 'https://${webApp.properties.defaultHostName}'
    protocol: 'http'
  }
}

resource mcpProduct 'Microsoft.ApiManagement/service/products@2023-09-01-preview' = {
  parent: apim
  name: 'mcp-demo-product'
  properties: {
    displayName: 'MCP Demo Product'
    description: 'Grants access to the MCP insurance demo API with a subscription key.'
    subscriptionRequired: true
    approvalRequired: false
    state: 'published'
  }
}

resource mcpProductApiLink 'Microsoft.ApiManagement/service/products/apis@2025-09-01-preview' = {
  parent: mcpProduct
  name: mcpApi.name
}

// -----------------------------------------------------------------------------
// MCP API policy: APIM does the real authentication of the caller (validating
// the end user's Entra ID token against this app registration), then swaps
// that token out for one of its own before forwarding to the backend. The
// backend therefore never sees the user's token at all — it only ever trusts
// calls from APIM's own managed identity (see McpServer/Program.cs, which
// requires the "Mcp.Backend" app role). This decouples backend trust from the
// end user's identity/scopes entirely (defense in depth: even if the backend
// URL were reachable directly, a bare user token would be rejected).
// -----------------------------------------------------------------------------
resource mcpApiPolicy 'Microsoft.ApiManagement/service/apis/policies@2023-09-01-preview' = {
  parent: mcpApi
  name: 'policy'
  properties: {
    format: 'xml'
    // NOTE: Bicep's triple-quoted (''') strings are RAW literals - they do NOT
    // support ${...} interpolation. So the XML below uses {{PLACEHOLDER}}
    // tokens, substituted via replace() when building the final value.
    value: replace(replace('''
<policies>
  <inbound>
    <base />
    <validate-jwt header-name="Authorization" failed-validation-httpcode="401" failed-validation-error-message="Unauthorized. A valid Entra ID access token for this API is required." require-expiration-time="true" require-signed-tokens="true">
      <openid-config url="https://login.microsoftonline.com/{{TENANT_ID}}/v2.0/.well-known/openid-configuration" />
      <audiences>
        <audience>api://{{API_CLIENT_ID}}</audience>
        <audience>{{API_CLIENT_ID}}</audience>
      </audiences>
      <issuers>
        <issuer>https://login.microsoftonline.com/{{TENANT_ID}}/v2.0</issuer>
        <issuer>https://sts.windows.net/{{TENANT_ID}}/</issuer>
      </issuers>
    </validate-jwt>
    <authentication-managed-identity resource="api://{{API_CLIENT_ID}}" output-token-variable-name="msi-access-token" ignore-error="false" />
    <set-header name="Authorization" exists-action="override">
      <value>@("Bearer " + (string)context.Variables["msi-access-token"])</value>
    </set-header>
  </inbound>
  <backend>
    <base />
  </backend>
  <outbound>
    <base />
  </outbound>
  <on-error>
    <base />
  </on-error>
</policies>
''', '{{TENANT_ID}}', tenantId), '{{API_CLIENT_ID}}', apiClientId)
  }
}

resource mcpSubscription 'Microsoft.ApiManagement/service/subscriptions@2023-09-01-preview' = {
  parent: apim
  name: 'mcp-demo-subscription'
  properties: {
    displayName: 'MCP Demo Subscription'
    scope: mcpProduct.id
    state: 'active'
  }
}

// -----------------------------------------------------------------------------
// Application Insights + APIM diagnostics
// Lets you see exactly what APIM is doing with each MCP request/response -
// handy while learning how the APIM MCP passthrough gateway behaves.
// -----------------------------------------------------------------------------
resource appInsights 'Microsoft.Insights/components@2020-02-02' = {
  name: '${namePrefix}-appinsights'
  location: location
  kind: 'web'
  properties: {
    Application_Type: 'web'
  }
}

resource apimLogger 'Microsoft.ApiManagement/service/loggers@2023-09-01-preview' = {
  parent: apim
  name: 'appinsights-logger'
  properties: {
    loggerType: 'applicationInsights'
    description: 'App Insights logger for MCP diagnostics'
    credentials: {
      instrumentationKey: appInsights.properties.InstrumentationKey
    }
    resourceId: appInsights.id
  }
}

resource mcpApiDiagnostics 'Microsoft.ApiManagement/service/apis/diagnostics@2025-09-01-preview' = {
  parent: mcpApi
  name: 'applicationinsights'
  properties: {
    loggerId: apimLogger.id
    alwaysLog: 'allErrors'
    verbosity: 'verbose'
    sampling: {
      samplingType: 'fixed'
      percentage: 100
    }
    frontend: {
      request: { headers: ['*'], body: { bytes: 8192 } }
      response: { headers: ['*'], body: { bytes: 8192 } }
    }
    backend: {
      request: { headers: ['*'], body: { bytes: 8192 } }
      response: { headers: ['*'], body: { bytes: 8192 } }
    }
    logClientIp: true
    httpCorrelationProtocol: 'W3C'
    mcp: {
      logPayload: true
    }
  }
}

output webAppName string = webApp.name
output webAppHostName string = webApp.properties.defaultHostName
output apimName string = apim.name
output apimGatewayUrl string = apim.properties.gatewayUrl
output apimMcpUrl string = '${apim.properties.gatewayUrl}/${mcpPathSegment}mcp'
output appInsightsName string = appInsights.name
output apimPrincipalId string = apim.identity.principalId
