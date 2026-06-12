using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;
using OboSqlServer.Api;
using OboSqlServer.Api.Data;
using OboSqlServer.Api.Security;
using OboSqlServer.Api.Services;

var builder = WebApplication.CreateBuilder(args);

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();

builder.Services.AddAuthorization();
builder.Services.AddHttpContextAccessor();
builder.Services.Configure<SqlOptions>(builder.Configuration.GetSection("Sql"));
builder.Services.AddScoped<CurrentUserAccessor>();
builder.Services.AddScoped<SqlConnectionFactory>();
builder.Services.AddScoped<DocumentRepository>();
builder.Services.AddScoped<DocumentService>();

var app = builder.Build();

app.UseMiddleware<CorrelationIdMiddleware>();
app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/healthz", () => Results.Ok(new { status = "ok" }))
    .AllowAnonymous();

app.MapPost("/documents", async (CreateDocumentRequest request, DocumentService service, CancellationToken cancellationToken) =>
{
    var result = await service.CreateAsync(request, cancellationToken);
    return Results.Created($"/documents/{result.DocumentId}", result);
}).RequireAuthorization();

app.MapGet("/documents/{documentId:guid}", async (Guid documentId, DocumentService service, CancellationToken cancellationToken) =>
{
    var result = await service.GetAsync(documentId, cancellationToken);

    return result.Status switch
    {
        DocumentReadStatus.Found => Results.Ok(result.Document),
        DocumentReadStatus.Forbidden => Results.Forbid(),
        _ => Results.NotFound()
    };
}).RequireAuthorization();

app.Run();

public partial class Program
{
}
