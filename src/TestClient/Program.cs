using Azure.Core;
using Azure.Identity;
using ModelContextProtocol.Client;

// =============================================================================
// TestClient — a minimal console app that authenticates as the signed-in user
// (via DefaultAzureCredential) and calls the MCP insurance demo server through
// APIM, exercising each of its three demo tools.
//
// Prerequisites:
//   1. Run `az login --scope api://<API_APP_CLIENT_ID>/access_as_user` once so
//      DefaultAzureCredential (via AzureCliCredential) can silently mint a
//      user-delegated token for this API's scope.
//   2. Set the environment variables below (or edit the defaults).
// =============================================================================

var apiAppClientId = Environment.GetEnvironmentVariable("API_APP_CLIENT_ID")
    ?? throw new InvalidOperationException("Set API_APP_CLIENT_ID to the App Registration's client ID.");
var tenantId = Environment.GetEnvironmentVariable("TENANT_ID")
    ?? throw new InvalidOperationException("Set TENANT_ID to your Entra ID tenant ID.");
var mcpEndpoint = Environment.GetEnvironmentVariable("MCP_ENDPOINT")
    ?? throw new InvalidOperationException("Set MCP_ENDPOINT to the APIM gateway MCP URL, e.g. https://<apim-name>.azure-api.net/mcp");
var apimSubscriptionKey = Environment.GetEnvironmentVariable("APIM_SUBSCRIPTION_KEY");

var scope = $"api://{apiAppClientId}/access_as_user";

Console.WriteLine("Signing in with DefaultAzureCredential (expects `az login` to have been run)...");
var credential = new DefaultAzureCredential(new DefaultAzureCredentialOptions
{
    TenantId = tenantId
});

var tokenResult = await credential.GetTokenAsync(new TokenRequestContext(new[] { scope }));
Console.WriteLine("Acquired user access token.\n");

var headers = new Dictionary<string, string>
{
    ["Authorization"] = $"Bearer {tokenResult.Token}"
};

if (!string.IsNullOrWhiteSpace(apimSubscriptionKey))
{
    headers["Ocp-Apim-Subscription-Key"] = apimSubscriptionKey;
}

var transport = new HttpClientTransport(new HttpClientTransportOptions
{
    Endpoint = new Uri(mcpEndpoint),
    AdditionalHeaders = headers
});

await using var client = await McpClient.CreateAsync(transport);

Console.WriteLine("Connected to MCP server. Available tools:");
var tools = await client.ListToolsAsync();
foreach (var tool in tools)
{
    Console.WriteLine($"  - {tool.Name}: {tool.Description}");
}

Console.WriteLine();
Console.WriteLine("--- Calling get_claim_status(claimId: CLM-1002) ---");
var claimResult = await client.CallToolAsync("get_claim_status", new Dictionary<string, object?>
{
    ["claimId"] = "CLM-1002"
});
PrintResult(claimResult);

Console.WriteLine("--- Calling find_in_network_provider(specialty: Cardiology, zipPrefix: 980) ---");
var providerResult = await client.CallToolAsync("find_in_network_provider", new Dictionary<string, object?>
{
    ["specialty"] = "Cardiology",
    ["zipPrefix"] = "980"
});
PrintResult(providerResult);

Console.WriteLine("--- Calling estimate_member_cost(procedure: MRI, planType: Gold) ---");
var costResult = await client.CallToolAsync("estimate_member_cost", new Dictionary<string, object?>
{
    ["procedure"] = "MRI",
    ["planType"] = "Gold"
});
PrintResult(costResult);

static void PrintResult(ModelContextProtocol.Protocol.CallToolResult result)
{
    foreach (var content in result.Content)
    {
        if (content is ModelContextProtocol.Protocol.TextContentBlock text)
        {
            Console.WriteLine(text.Text);
        }
    }
    Console.WriteLine();
}
