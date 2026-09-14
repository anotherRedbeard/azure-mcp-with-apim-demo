using System.ComponentModel;
using ModelContextProtocol.Server;

namespace McpServer.Tools;

/// <summary>
/// Demo MCP tools for a fictional health insurance member-services scenario.
/// All data is fake and generated in-memory purely for learning purposes.
/// </summary>
[McpServerToolType]
public static class InsuranceTools
{
    // A handful of fake claims, keyed by claim ID.
    private static readonly Dictionary<string, (string Status, string Description, decimal AmountBilled, decimal MemberResponsibility)> Claims = new()
    {
        ["CLM-1001"] = ("Approved", "Annual wellness visit", 250.00m, 0.00m),
        ["CLM-1002"] = ("Pending Review", "MRI - left knee", 1875.50m, 375.10m),
        ["CLM-1003"] = ("Denied", "Out-of-network specialist visit", 420.00m, 420.00m),
        ["CLM-1004"] = ("Approved", "Urgent care - flu symptoms", 180.00m, 45.00m),
    };

    // A small fake provider directory grouped by specialty + zip prefix.
    private static readonly List<(string Name, string Specialty, string Zip, string Phone)> Providers = new()
    {
        ("Dr. Amara Chen", "Cardiology", "980", "(555) 010-1000"),
        ("Dr. Luis Fernandez", "Cardiology", "981", "(555) 010-1001"),
        ("Dr. Priya Natarajan", "Pediatrics", "980", "(555) 010-1002"),
        ("Dr. Sam O'Neil", "Orthopedics", "982", "(555) 010-1003"),
        ("Dr. Grace Kim", "Dermatology", "980", "(555) 010-1004"),
    };

    [McpServerTool, Description("Looks up the status of a member's insurance claim by claim ID (e.g. CLM-1001). Returns status, description, billed amount, and member responsibility.")]
    public static string GetClaimStatus(
        [Description("The claim identifier, e.g. CLM-1001")] string claimId)
    {
        if (Claims.TryGetValue(claimId.Trim().ToUpperInvariant(), out var claim))
        {
            return $"Claim {claimId}: {claim.Status} — {claim.Description}. " +
                   $"Billed: ${claim.AmountBilled:N2}, Member responsibility: ${claim.MemberResponsibility:N2}.";
        }

        return $"No claim found with ID '{claimId}'. Try one of: {string.Join(", ", Claims.Keys)}.";
    }

    [McpServerTool, Description("Finds in-network healthcare providers by medical specialty and the first three digits of a ZIP code.")]
    public static string FindInNetworkProvider(
        [Description("Medical specialty, e.g. Cardiology, Pediatrics, Orthopedics, Dermatology")] string specialty,
        [Description("First 3 digits of the member's ZIP code, e.g. 980")] string zipPrefix)
    {
        var matches = Providers
            .Where(p => p.Specialty.Equals(specialty, StringComparison.OrdinalIgnoreCase)
                        && p.Zip == zipPrefix.Trim())
            .ToList();

        if (matches.Count == 0)
        {
            return $"No in-network {specialty} providers found near ZIP prefix {zipPrefix}.";
        }

        return string.Join("\n", matches.Select(p => $"{p.Name} ({p.Specialty}) — {p.Phone}"));
    }

    [McpServerTool, Description("Estimates a member's out-of-pocket cost for a procedure given a plan type. This is a simplified illustrative estimate, not a real quote.")]
    public static string EstimateMemberCost(
        [Description("Procedure name, e.g. 'MRI', 'Annual Physical', 'Specialist Visit'")] string procedure,
        [Description("Plan type: 'Bronze', 'Silver', 'Gold', or 'Platinum'")] string planType)
    {
        // Simplified fake base costs and coinsurance rates per plan tier.
        var baseCosts = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase)
        {
            ["MRI"] = 1800m,
            ["Annual Physical"] = 250m,
            ["Specialist Visit"] = 300m,
            ["Urgent Care"] = 180m,
        };

        var coinsurance = new Dictionary<string, decimal>(StringComparer.OrdinalIgnoreCase)
        {
            ["Bronze"] = 0.40m,
            ["Silver"] = 0.25m,
            ["Gold"] = 0.15m,
            ["Platinum"] = 0.05m,
        };

        if (!baseCosts.TryGetValue(procedure, out var cost))
        {
            return $"Unknown procedure '{procedure}'. Try one of: {string.Join(", ", baseCosts.Keys)}.";
        }

        if (!coinsurance.TryGetValue(planType, out var rate))
        {
            return $"Unknown plan type '{planType}'. Try one of: {string.Join(", ", coinsurance.Keys)}.";
        }

        var memberCost = cost * rate;
        return $"Estimated member cost for '{procedure}' under the {planType} plan: ${memberCost:N2} " +
               $"(of an estimated ${cost:N2} total, at {rate:P0} coinsurance). Actual costs may vary.";
    }
}
