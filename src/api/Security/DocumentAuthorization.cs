using System.Security.Claims;

namespace OboSqlServer.Api.Security;

public static class DocumentAuthorization
{
    public static bool IsAllowed(ClaimsPrincipal principal, string? allowedClientId)
    {
        var scopes = principal.FindFirstValue("scp")
            ?? principal.FindFirstValue("http://schemas.microsoft.com/identity/claims/scope");
        var clientId = principal.FindFirstValue("azp") ?? principal.FindFirstValue("appid");
        return principal.Identity?.IsAuthenticated == true &&
            (scopes?.Split(' ', StringSplitOptions.RemoveEmptyEntries).Contains("user_impersonation") ?? false) &&
            (string.IsNullOrWhiteSpace(allowedClientId) ||
             string.Equals(clientId, allowedClientId, StringComparison.OrdinalIgnoreCase));
    }
}
