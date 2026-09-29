using System.Reflection;
using System.Security.Claims;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;
using OboSqlServer.Bff.Services;
using Xunit;

namespace OboSqlServer.Bff.Tests;

public sealed class ApiTokenProviderTests
{
    [Fact]
    public async Task AcquisitionUsesOidcRatherThanDefaultCookieScheme()
    {
        var acquisition = DispatchProxy.Create<ITokenAcquisition, CapturingTokenAcquisition>();
        var capture = (CapturingTokenAcquisition)acquisition;
        var options = Options.Create(new BffOptions
        {
            PublicOrigin = "https://example.test",
            ApiBaseUrl = "http://api/",
            ApiScope = "api://test/user_impersonation",
            BlobContainerUrl = "https://storage.example.test/spa"
        });
        var principal = new ClaimsPrincipal(new ClaimsIdentity([], "Cookies"));
        var provider = new ApiTokenProvider(acquisition, options);
        Assert.Equal("synthetic-token", await provider.GetAsync(principal));
        Assert.Equal("OpenIdConnect", capture.Arguments["authenticationScheme"]);
        Assert.Same(principal, capture.Arguments["user"]);
        Assert.Equal(["api://test/user_impersonation"], Assert.IsAssignableFrom<IEnumerable<string>>(capture.Arguments["scopes"]));
    }
}

public class CapturingTokenAcquisition : DispatchProxy
{
    public Dictionary<string, object?> Arguments { get; } = [];

    protected override object Invoke(MethodInfo? targetMethod, object?[]? args)
    {
        Assert.NotNull(targetMethod);
        Assert.NotNull(args);
        Assert.Equal(nameof(ITokenAcquisition.GetAccessTokenForUserAsync), targetMethod.Name);
        foreach (var parameter in targetMethod.GetParameters())
            Arguments[parameter.Name!] = args[parameter.Position];
        return Task.FromResult("synthetic-token");
    }
}
