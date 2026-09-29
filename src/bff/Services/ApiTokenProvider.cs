using System.Security.Claims;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;

namespace OboSqlServer.Bff.Services;

public interface IApiTokenProvider
{
    Task<string> GetAsync(ClaimsPrincipal user);
}

public sealed class ApiTokenProvider(ITokenAcquisition acquisition, IOptions<BffOptions> options) : IApiTokenProvider
{
    public Task<string> GetAsync(ClaimsPrincipal user) =>
        acquisition.GetAccessTokenForUserAsync([options.Value.ApiScope],
            authenticationScheme: OpenIdConnectDefaults.AuthenticationScheme, user: user);
}
