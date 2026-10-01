// Camada 2 do tutorial de OBO: "middle tier" mínimo que recebe o token da
// Camada 1, valida-o (audience = obo-api) e faz o 2o hop OBO para o Key Vault
// real do lab, reproduzindo em miniatura o padrão de
// src/api/Security/DelegatedTokenCredential.cs do projeto real.
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.Identity.Web;

var builder = WebApplication.CreateBuilder(args);

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddMicrosoftIdentityWebApi(builder.Configuration.GetSection("AzureAd"))
    .EnableTokenAcquisitionToCallDownstreamApi()
    .AddInMemoryTokenCaches();

builder.Services.AddAuthorization();
builder.Services.AddHttpClient();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

app.MapGet("/keyvault-demo", async (
    ITokenAcquisition tokenAcquisition,
    IHttpClientFactory httpClientFactory,
    IConfiguration config) =>
{
    var keyVaultUri = config["KeyVault:Uri"]!.TrimEnd('/');
    var keyName = config["KeyVault:KeyName"] ?? "cmk-documents";

    // 2o hop do OBO: troca o token do usuário (recebido no header Authorization)
    // por um novo token, on-behalf-of, escopado para o Key Vault.
    var vaultToken = await tokenAcquisition.GetAccessTokenForUserAsync(
        ["https://vault.azure.net/user_impersonation"]);

    var client = httpClientFactory.CreateClient();
    client.DefaultRequestHeaders.Authorization = new("Bearer", vaultToken);
    var response = await client.GetAsync($"{keyVaultUri}/keys/{keyName}?api-version=7.4");
    var body = await response.Content.ReadAsStringAsync();

    return Results.Content(body, "application/json", statusCode: (int)response.StatusCode);
}).RequireAuthorization();

app.Run();
