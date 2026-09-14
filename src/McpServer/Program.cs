using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Authorization;
using Microsoft.Identity.Web;

var builder = WebApplication.CreateBuilder(args);

// --- Entra ID authentication -------------------------------------------------
// The MCP server itself is the "resource app", but it does NOT trust bare user
// tokens. APIM validates the end user's token itself, then calls this backend
// using its own system-assigned managed identity (see infra/main.bicep's
// mcpApiPolicy). So the only caller this API authorizes is APIM, identified by
// the app-only "Mcp.Backend" role assigned to APIM's managed identity
// (scripts/05-assign-apim-role.sh). A direct call to this Web App with a user's
// own delegated token will be authenticated but then rejected (403) for
// lacking that role - by design.
builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"));

builder.Services.AddAuthorization(options =>
{
    options.AddPolicy("RequireMcpBackendRole", policy => policy
        .RequireAuthenticatedUser()
        .RequireRole("Mcp.Backend"));
});

// --- MCP server ---------------------------------------------------------------
builder.Services
    .AddMcpServer()
    .WithHttpTransport()
    .WithToolsFromAssembly();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

// Simple unauthenticated health check for App Service / APIM probes.
app.MapGet("/healthz", () => Results.Ok(new { status = "healthy" })).AllowAnonymous();

app.MapMcp("/mcp").RequireAuthorization("RequireMcpBackendRole");

app.Run();
