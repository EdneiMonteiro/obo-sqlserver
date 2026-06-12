using System.Security.Claims;
using Microsoft.Identity.Web;

namespace OboSqlServer.Api.Security;

public sealed record CurrentUser(Guid TenantId, Guid ObjectId, string? DisplayName)
{
    public static CurrentUser FromClaimsPrincipal(ClaimsPrincipal principal)
    {
        var tenantId = ReadGuidClaim(principal, ClaimConstants.TenantId, "tid");
        var objectId = ReadGuidClaim(principal, ClaimConstants.ObjectId, "oid");
        var displayName = principal.FindFirstValue("name") ?? principal.FindFirstValue("preferred_username");

        return new CurrentUser(tenantId, objectId, displayName);
    }

    private static Guid ReadGuidClaim(ClaimsPrincipal principal, params string[] claimTypes)
    {
        foreach (var claimType in claimTypes)
        {
            var value = principal.FindFirstValue(claimType);
            if (Guid.TryParse(value, out var parsed))
            {
                return parsed;
            }
        }

        throw new UnauthorizedAccessException($"Missing or invalid claim: {string.Join(" or ", claimTypes)}.");
    }
}

