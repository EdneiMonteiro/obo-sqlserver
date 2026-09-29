using System.Security.Claims;
using System.Net;
using Azure.Core;
using Azure.Identity;
using Azure.Storage.Blobs;
using Microsoft.AspNetCore.Antiforgery;
using Microsoft.AspNetCore.Authentication;
using Microsoft.AspNetCore.Authentication.Cookies;
using Microsoft.AspNetCore.Authentication.OpenIdConnect;
using Microsoft.AspNetCore.DataProtection;
using Microsoft.AspNetCore.HttpOverrides;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;
using OboSqlServer.Bff;
using OboSqlServer.Bff.Security;
using OboSqlServer.Bff.Services;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 15 * 1024 * 1024);
builder.Services.AddOptions<BffOptions>().BindConfiguration("Bff")
    .Validate(o => BffOptions.IsHttpsOrigin(o.PublicOrigin), "Bff:PublicOrigin must be an HTTPS origin.")
    .Validate(o => Uri.TryCreate(o.ApiBaseUrl, UriKind.Absolute, out var uri) &&
                   (uri.Scheme == "https" || uri.Scheme == "http") &&
                   uri.AbsolutePath == "/" && string.IsNullOrEmpty(uri.UserInfo + uri.Query + uri.Fragment),
        "Bff:ApiBaseUrl must be the fixed API origin.")
    .Validate(o => !string.IsNullOrWhiteSpace(o.ApiScope), "Bff:ApiScope is required.")
    .Validate(o => Uri.TryCreate(o.BlobContainerUrl, UriKind.Absolute, out var uri) &&
                   uri.Scheme == "https" && string.IsNullOrEmpty(uri.UserInfo + uri.Query + uri.Fragment),
        "Bff:BlobContainerUrl must use HTTPS without credentials or SAS.")
    .ValidateOnStart();
var settings = builder.Configuration.GetSection("Bff").Get<BffOptions>()
    ?? throw new InvalidOperationException("Bff configuration is required.");

builder.Services.AddAuthentication(options =>
    {
        options.DefaultScheme = CookieAuthenticationDefaults.AuthenticationScheme;
        options.DefaultAuthenticateScheme = CookieAuthenticationDefaults.AuthenticationScheme;
        options.DefaultChallengeScheme = OpenIdConnectDefaults.AuthenticationScheme;
    })
    .AddMicrosoftIdentityWebApp(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi([settings.ApiScope])
    .AddInMemoryTokenCaches();
builder.Services.AddAuthorization();
builder.Services.AddMemoryCache();
builder.Services.AddDataProtection().UseEphemeralDataProtectionProvider();
builder.Services.AddSingleton<ITicketStore, ServerTicketStore>();
builder.Services.AddOptions<CookieAuthenticationOptions>(CookieAuthenticationDefaults.AuthenticationScheme)
    .Configure<ITicketStore>((options, store) =>
    {
        options.SessionStore = store;
        options.Cookie.Name = "__Host-obo-session";
        options.Cookie.HttpOnly = true;
        options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
        options.Cookie.SameSite = SameSiteMode.Lax;
        options.Cookie.Path = "/";
        options.ExpireTimeSpan = TimeSpan.FromMinutes(30);
        options.SlidingExpiration = false;
        options.Events.OnRedirectToLogin = context =>
        {
            context.Response.StatusCode = StatusCodes.Status401Unauthorized;
            return Task.CompletedTask;
        };
        options.Events.OnRedirectToAccessDenied = context =>
        {
            context.Response.StatusCode = StatusCodes.Status403Forbidden;
            return Task.CompletedTask;
        };
    });
builder.Services.PostConfigure<OpenIdConnectOptions>(OpenIdConnectDefaults.AuthenticationScheme, options =>
{
    options.ResponseType = "code";
    options.UsePkce = true;
    options.SaveTokens = false;
    var priorRedirect = options.Events.OnRedirectToIdentityProvider;
    options.Events.OnRedirectToIdentityProvider = async context =>
    {
        await priorRedirect(context);
        context.ProtocolMessage.RedirectUri = settings.PublicOrigin.TrimEnd('/') + "/signin-oidc";
    };
    options.Events.OnRedirectToIdentityProviderForSignOut = context =>
    {
        context.ProtocolMessage.PostLogoutRedirectUri = settings.PublicOrigin.TrimEnd('/') + "/signout-callback-oidc";
        return Task.CompletedTask;
    };
});
builder.Services.AddAntiforgery(options =>
{
    options.HeaderName = "x-csrf-token";
    options.Cookie.Name = "__Host-obo-csrf";
    options.Cookie.HttpOnly = true;
    options.Cookie.SecurePolicy = CookieSecurePolicy.Always;
    options.Cookie.SameSite = SameSiteMode.Strict;
    options.Cookie.Path = "/";
});
builder.Services.AddSingleton<TokenCredential>(_ => builder.Environment.IsDevelopment()
    ? new DefaultAzureCredential()
    : new WorkloadIdentityCredential());
builder.Services.AddSingleton(sp => new BlobContainerClient(
    new Uri(settings.BlobContainerUrl), sp.GetRequiredService<TokenCredential>()));
builder.Services.AddSingleton<IStaticAssetStore, StaticAssetStore>();
builder.Services.AddScoped<IApiTokenProvider, ApiTokenProvider>();
builder.Services.AddScoped<DocumentProxy>();
builder.Services.AddHttpClient("api", client =>
{
    client.BaseAddress = new Uri(settings.ApiBaseUrl);
    client.Timeout = TimeSpan.FromSeconds(90);
}).ConfigurePrimaryHttpMessageHandler(() => new HttpClientHandler
{
    AllowAutoRedirect = false,
    UseCookies = false
});
builder.Services.AddProblemDetails();

var app = builder.Build();
var forwarded = new ForwardedHeadersOptions
{
    ForwardedHeaders = ForwardedHeaders.XForwardedProto,
    ForwardLimit = 1
};
// Only the local Istio sidecar may assert the scheme terminated at the ingress.
forwarded.KnownNetworks.Clear();
forwarded.KnownProxies.Clear();
forwarded.KnownProxies.Add(IPAddress.Loopback);
forwarded.KnownProxies.Add(IPAddress.IPv6Loopback);
forwarded.KnownProxies.Add(IPAddress.Parse("127.0.0.6"));
app.UseForwardedHeaders(forwarded);
app.UseExceptionHandler();
app.Use(async (context, next) =>
{
    context.Response.Headers.CacheControl = "no-store";
    context.Response.Headers["X-Content-Type-Options"] = "nosniff";
    context.Response.Headers["Referrer-Policy"] = "no-referrer";
    context.Response.Headers["Strict-Transport-Security"] = "max-age=31536000";
    context.Response.Headers["Content-Security-Policy"] =
        "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; " +
        "img-src 'self'; base-uri 'none'; frame-ancestors 'none'; form-action 'self'";
    await next(context);
});
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/healthz", () => Results.Ok(new { status = "ok" })).AllowAnonymous();
app.MapGet("/bff/login", () => Results.Challenge(
    new AuthenticationProperties { RedirectUri = "/" }, [OpenIdConnectDefaults.AuthenticationScheme]));
app.MapGet("/bff/session", (HttpContext context, IAntiforgery antiforgery) =>
{
    if (context.User.Identity?.IsAuthenticated != true)
        return Results.Ok(new { authenticated = false });
    return Results.Ok(new
    {
        authenticated = true,
        name = context.User.FindFirstValue("name"),
        tenantId = context.User.GetTenantId(),
        objectId = context.User.GetObjectId(),
        csrfToken = antiforgery.GetAndStoreTokens(context).RequestToken
    });
}).AllowAnonymous();
app.MapPost("/bff/logout", async (HttpContext context, IAntiforgery antiforgery) =>
{
    try { await antiforgery.ValidateRequestAsync(context); }
    catch (AntiforgeryValidationException) { return Results.BadRequest(); }
    // Local logout revokes the server-side ticket; the next login may reuse the Entra SSO session.
    await context.SignOutAsync(CookieAuthenticationDefaults.AuthenticationScheme);
    return Results.NoContent();
}).RequireAuthorization(new Microsoft.AspNetCore.Authorization.AuthorizeAttribute
{
    AuthenticationSchemes = CookieAuthenticationDefaults.AuthenticationScheme
});

var documents = app.MapGroup("/api/documents").RequireAuthorization(
    new Microsoft.AspNetCore.Authorization.AuthorizeAttribute
    {
        AuthenticationSchemes = CookieAuthenticationDefaults.AuthenticationScheme
    });
documents.MapPost("", (HttpContext context, DocumentProxy proxy) => proxy.ForwardAsync(context, "documents"));
documents.MapGet("/{id:guid}", (Guid id, HttpContext context, DocumentProxy proxy) =>
    proxy.ForwardAsync(context, $"documents/{id}"));
foreach (var (route, asset) in new[] { ("/", "index.html"), ("/app.js", "app.js"), ("/styles.css", "styles.css") })
{
    app.MapGet(route, async (IStaticAssetStore store, CancellationToken ct) =>
    {
        var file = await store.GetAsync(asset, ct);
        return file is null ? Results.NotFound() : Results.Stream(file.Content, file.ContentType);
    }).AllowAnonymous();
}
app.Run();

public partial class Program;
