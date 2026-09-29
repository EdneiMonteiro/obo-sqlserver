using System.Net;
using System.Net.Http.Json;
using System.Security.Claims;
using System.Text;
using System.Text.Json;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Hosting;
using Microsoft.AspNetCore.Http;
using Microsoft.AspNetCore.Mvc.Testing;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.DependencyInjection.Extensions;
using OboSqlServer.Bff.Services;
using Xunit;

namespace OboSqlServer.Bff.Tests;

public sealed class BffTests
{
    [Theory]
    [InlineData("127.0.0.6", HttpStatusCode.OK)]
    [InlineData("203.0.113.10", HttpStatusCode.InternalServerError)]
    public async Task HttpsSchemeIsAcceptedOnlyFromLocalSidecar(string peer, HttpStatusCode expected)
    {
        await using var factory = new BffFactory();
        using var client = factory.Client();
        await client.GetAsync("/test/signin");
        client.DefaultRequestHeaders.Add("x-test-peer", peer);
        client.DefaultRequestHeaders.Add("x-forwarded-proto", "https");
        var response = await client.GetAsync("/bff/session");
        Assert.Equal(expected, response.StatusCode);
    }

    [Fact]
    public async Task AnonymousSessionHasNoTokensAndApiReturns401()
    {
        await using var factory = new BffFactory();
        using var client = factory.Client();
        var session = await client.GetStringAsync("/bff/session");
        Assert.Equal("{\"authenticated\":false}", session);
        Assert.Equal(HttpStatusCode.Unauthorized, (await client.GetAsync("/api/documents/" + Guid.NewGuid())).StatusCode);
        Assert.Empty(factory.Upstream.Requests);
    }

    [Fact]
    public async Task RealSessionCookieIsHttpOnlyAndDoesNotContainTokens()
    {
        await using var factory = new BffFactory();
        using var client = factory.Client();
        var login = await client.GetAsync("/test/signin");
        var cookies = string.Join(";", login.Headers.GetValues("Set-Cookie"));
        Assert.Contains("__Host-obo-session=", cookies);
        Assert.Contains("httponly", cookies.ToLowerInvariant());
        Assert.Contains("secure", cookies.ToLowerInvariant());
        Assert.DoesNotContain(FakeTokens.Token, cookies);
        var session = await client.GetStringAsync("/bff/session");
        Assert.Contains("\"authenticated\":true", session);
        Assert.Contains("\"csrfToken\":", session);
        Assert.DoesNotContain(FakeTokens.Token, session);
        Assert.DoesNotContain("access_token", session);
        Assert.DoesNotContain("refresh_token", session);
    }

    [Fact]
    public async Task CsrfFailureDoesNotReachApi()
    {
        await using var factory = new BffFactory();
        using var client = factory.Client();
        await client.GetAsync("/test/signin");
        var response = await client.PostAsJsonAsync("/api/documents", new { payloadBase64 = "YQ==" });
        Assert.Equal(HttpStatusCode.BadRequest, response.StatusCode);
        Assert.Empty(factory.Upstream.Requests);
        Assert.Equal(HttpStatusCode.BadRequest, (await client.PostAsync("/bff/logout", null)).StatusCode);
    }

    [Fact]
    public async Task ProxyAttachesTokenOnlyUpstreamAndDoesNotRelaySensitiveHeaders()
    {
        await using var factory = new BffFactory();
        using var client = factory.Client();
        await client.GetAsync("/test/signin");
        using var session = JsonDocument.Parse(await client.GetStringAsync("/bff/session"));
        client.DefaultRequestHeaders.Add("x-csrf-token", session.RootElement.GetProperty("csrfToken").GetString());
        client.DefaultRequestHeaders.Add("Authorization", "Bearer attacker-supplied");
        var response = await client.PostAsJsonAsync("/api/documents", new { payloadBase64 = "YQ==" });
        Assert.Equal(HttpStatusCode.Created, response.StatusCode);
        Assert.Equal("Bearer " + FakeTokens.Token, Assert.Single(factory.Upstream.Requests).Authorization);
        Assert.Null(Assert.Single(factory.Upstream.Requests).Cookie);
        Assert.False(response.Headers.Contains("Set-Cookie"));
        Assert.False(response.Headers.Contains("WWW-Authenticate"));
        Assert.False(response.Headers.Contains("Authorization"));
        Assert.False(response.Headers.Contains("Location"));
        Assert.DoesNotContain(FakeTokens.Token, await response.Content.ReadAsStringAsync());
    }

    [Fact]
    public async Task LogoutRevokesSession()
    {
        await using var factory = new BffFactory();
        using var client = factory.Client();
        await client.GetAsync("/test/signin");
        using var session = JsonDocument.Parse(await client.GetStringAsync("/bff/session"));
        client.DefaultRequestHeaders.Add("x-csrf-token", session.RootElement.GetProperty("csrfToken").GetString());
        Assert.Equal(HttpStatusCode.NoContent, (await client.PostAsync("/bff/logout", null)).StatusCode);
        Assert.Equal("{\"authenticated\":false}", await client.GetStringAsync("/bff/session"));
    }

    [Theory]
    [InlineData("/app.js", HttpStatusCode.OK)]
    [InlineData("/styles.css", HttpStatusCode.OK)]
    [InlineData("/unknown.js", HttpStatusCode.NotFound)]
    [InlineData("/api/admin", HttpStatusCode.NotFound)]
    public async Task RoutesAreExplicitAndProtectedBySecurityHeaders(string path, HttpStatusCode expected)
    {
        await using var factory = new BffFactory();
        using var client = factory.Client();
        var response = await client.GetAsync(path);
        Assert.Equal(expected, response.StatusCode);
        Assert.Contains("no-store", response.Headers.CacheControl!.ToString());
        Assert.Contains("frame-ancestors 'none'", response.Headers.GetValues("Content-Security-Policy").Single());
    }
}

internal sealed class BffFactory : WebApplicationFactory<Program>
{
    public FakeUpstream Upstream { get; } = new();
    public HttpClient Client() => CreateClient(new WebApplicationFactoryClientOptions
    {
        BaseAddress = new Uri("https://bff.example.test"),
        AllowAutoRedirect = false
    });

    protected override void ConfigureWebHost(IWebHostBuilder builder)
    {
        builder.ConfigureAppConfiguration((_, config) => config.AddInMemoryCollection(new Dictionary<string, string?>
        {
            ["Bff:PublicOrigin"] = "https://bff.example.test",
            ["Bff:ApiBaseUrl"] = "http://api.example.test/",
            ["Bff:ApiScope"] = "api://11111111-1111-1111-1111-111111111111/user_impersonation",
            ["Bff:BlobContainerUrl"] = "https://storage.example.test/spa",
            ["AzureAd:TenantId"] = "22222222-2222-2222-2222-222222222222",
            ["AzureAd:ClientId"] = "33333333-3333-3333-3333-333333333333"
        }));
        builder.ConfigureServices(services =>
        {
            services.RemoveAll<IApiTokenProvider>();
            services.AddSingleton<IApiTokenProvider, FakeTokens>();
            services.RemoveAll<IStaticAssetStore>();
            services.AddSingleton<IStaticAssetStore, FakeAssets>();
            services.AddHttpClient("api").ConfigurePrimaryHttpMessageHandler(() => Upstream);
            services.AddSingleton<IStartupFilter, TestLogin>();
        });
    }
}

internal sealed class TestLogin : IStartupFilter
{
    public Action<IApplicationBuilder> Configure(Action<IApplicationBuilder> next) => app =>
    {
        app.Use(async (context, continuation) =>
        {
            if (context.Request.Headers.TryGetValue("x-test-peer", out var peer))
            {
                context.Request.Scheme = "http";
                context.Connection.RemoteIpAddress = IPAddress.Parse(peer.ToString());
            }
            if (context.Request.Path == "/test/signin")
            {
                var identity = new ClaimsIdentity([
                    new Claim("name", "Test Reader"),
                    new Claim("http://schemas.microsoft.com/identity/claims/tenantid", Guid.NewGuid().ToString()),
                    new Claim("http://schemas.microsoft.com/identity/claims/objectidentifier", Guid.NewGuid().ToString()),
                    new Claim(ClaimTypes.NameIdentifier, "test-reader")
                ], CookieAuthenticationDefaults.AuthenticationScheme);
                await context.SignInAsync(CookieAuthenticationDefaults.AuthenticationScheme,
                    new ClaimsPrincipal(identity), new AuthenticationProperties());
                context.Response.StatusCode = 204;
                return;
            }
            await continuation(context);
        });
        next(app);
    };
}

internal sealed class FakeTokens : IApiTokenProvider
{
    public const string Token = "server-only-test-access-token";
    public Task<string> GetAsync(ClaimsPrincipal user) => Task.FromResult(Token);
}

internal sealed class FakeAssets : IStaticAssetStore
{
    public Task<StaticAsset?> GetAsync(string name, CancellationToken cancellationToken) =>
        Task.FromResult<StaticAsset?>(new(new MemoryStream(Encoding.UTF8.GetBytes(name)), "text/plain"));
}

internal sealed class FakeUpstream : HttpMessageHandler
{
    public List<(string? Authorization, string? Cookie)> Requests { get; } = [];
    protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken)
    {
        Requests.Add((request.Headers.Authorization?.ToString(),
            request.Headers.TryGetValues("Cookie", out var cookies) ? string.Join(";", cookies) : null));
        var response = new HttpResponseMessage(HttpStatusCode.Created)
        {
            Content = JsonContent.Create(new { documentId = Guid.NewGuid() })
        };
        response.Headers.Add("Set-Cookie", "upstream=not-for-browser");
        response.Headers.Add("WWW-Authenticate", "Bearer secret-challenge");
        response.Headers.Add("Authorization", "Bearer " + FakeTokens.Token);
        response.Headers.Location = new Uri("https://untrusted.example.test");
        return Task.FromResult(response);
    }
}
