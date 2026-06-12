namespace OboSqlServer.Api.Security;

public sealed class CurrentUserAccessor(IHttpContextAccessor httpContextAccessor)
{
    public CurrentUser GetRequiredUser()
    {
        var principal = httpContextAccessor.HttpContext?.User;

        if (principal?.Identity?.IsAuthenticated != true)
        {
            throw new UnauthorizedAccessException("Authenticated user is required.");
        }

        return CurrentUser.FromClaimsPrincipal(principal);
    }
}

