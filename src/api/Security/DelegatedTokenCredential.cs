using Azure.Core;
using Microsoft.Identity.Web;
using System.IdentityModel.Tokens.Jwt;

namespace OboSqlServer.Api.Security;

public sealed class DelegatedTokenCredential(
    ITokenAcquisition tokenAcquisition,
    IHttpContextAccessor httpContextAccessor) : TokenCredential
{
    public override AccessToken GetToken(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        return GetTokenAsync(requestContext, cancellationToken).AsTask().GetAwaiter().GetResult();
    }

    public override async ValueTask<AccessToken> GetTokenAsync(TokenRequestContext requestContext, CancellationToken cancellationToken)
    {
        var principal = httpContextAccessor.HttpContext?.User;

        if (principal?.Identity?.IsAuthenticated != true)
        {
            throw new UnauthorizedAccessException("Authenticated user is required for delegated Key Vault access.");
        }

        var token = await tokenAcquisition.GetAccessTokenForUserAsync(requestContext.Scopes, user: principal);
        var expiresOn = TryReadExpiry(token) ?? DateTimeOffset.UtcNow.AddMinutes(5);

        return new AccessToken(token, expiresOn);
    }

    private static DateTimeOffset? TryReadExpiry(string token)
    {
        var jwt = new JwtSecurityTokenHandler().ReadJwtToken(token);
        return jwt.ValidTo == DateTime.MinValue
            ? null
            : new DateTimeOffset(DateTime.SpecifyKind(jwt.ValidTo, DateTimeKind.Utc));
    }
}

