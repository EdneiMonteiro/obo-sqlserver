using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using OboSqlServer.Api;
using OboSqlServer.Api.Data;
using OboSqlServer.Api.Security;
using OboSqlServer.Api.Services;

var builder = WebApplication.CreateBuilder(args);
builder.WebHost.ConfigureKestrel(options => options.Limits.MaxRequestBodySize = 15 * 1024 * 1024);
if (builder.Configuration.GetSection("AzureAd:ClientCredentials").GetChildren().Any())
    builder.Configuration["AzureAd:ClientSecret"] = null;

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();

builder.Services.AddAuthorization(options => options.AddPolicy("documents", policy =>
    policy.RequireAssertion(context => DocumentAuthorization.IsAllowed(
        context.User, builder.Configuration["AzureAd:AllowedClientId"]))));
builder.Services.AddProblemDetails();
builder.Services.AddHttpContextAccessor();
builder.Services.Configure<SqlOptions>(builder.Configuration.GetSection("Sql"));
builder.Services.AddScoped<CurrentUserAccessor>();
builder.Services.AddScoped<SqlConnectionFactory>();
builder.Services.AddScoped<DocumentRepository>();
builder.Services.AddScoped<DocumentService>();

var app = builder.Build();

app.UseExceptionHandler();
app.UseMiddleware<CorrelationIdMiddleware>();
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }))
    .AllowAnonymous();

app.MapPost("/documents", async (CreateDocumentRequest request, DocumentService service, CancellationToken cancellationToken) =>
{
    try
    {
        var result = await service.CreateAsync(request, cancellationToken);
        return Results.Created($"/documents/{result.DocumentId}", result);
    }
    catch (BadHttpRequestException exception)
    {
        return Results.Problem(statusCode: exception.StatusCode, title: exception.Message);
    }
}).RequireAuthorization("documents");

app.MapGet("/documents/{documentId:guid}", async (Guid documentId, DocumentService service, CancellationToken cancellationToken) =>
{
    var result = await service.GetAsync(documentId, cancellationToken);

    return result.Status switch
    {
        DocumentReadStatus.Found => Results.Ok(result.Document),
        DocumentReadStatus.Forbidden => Results.Forbid(),
        _ => Results.NotFound()
    };
}).RequireAuthorization("documents");

app.Run();

public partial class Program
{
}
