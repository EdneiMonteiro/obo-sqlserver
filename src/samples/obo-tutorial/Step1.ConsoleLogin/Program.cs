// Camada 1 do tutorial de OBO: login do usuário de teste + primeiro hop
// (obtenção de um token delegado "user_impersonation" para a API real do lab).
// Não chama nenhum recurso protegido ainda — só prova que o hop usuário -> API
// funciona com a configuração real do Entra ID.
//
// Uso: dotnet run -- <tenantId> <apiAppId>
using System.IdentityModel.Tokens.Jwt;
using Microsoft.Identity.Client;

if (args.Length < 2)
{
    Console.WriteLine("Uso: dotnet run -- <tenantId> <apiAppId>");
    Console.WriteLine("Os valores do lab atual estão em .local\\aks\\deployment.local.json (tenantId, api.appId).");
    return 1;
}

var tenantId = args[0];
var apiAppId = args[1];
var apiScope = $"api://{apiAppId}/user_impersonation";

// obo-api também atua como client aqui: é a mesma App Registration usada pela
// API real, com "Allow public client flows" habilitado temporariamente para
// permitir o fluxo Device Code (sem precisar de nenhuma app nova).
var app = PublicClientApplicationBuilder.Create(apiAppId)
    .WithTenantId(tenantId)
    .Build();

Console.WriteLine("Fazendo login como o usuário de teste (Device Code)...");
var result = await app.AcquireTokenWithDeviceCode([apiScope], deviceCodeResult =>
{
    Console.WriteLine(deviceCodeResult.Message);
    return Task.CompletedTask;
}).ExecuteAsync();

Console.WriteLine();
Console.WriteLine("Token adquirido com sucesso. Claims relevantes:");
var jwt = new JwtSecurityTokenHandler().ReadJwtToken(result.AccessToken);
foreach (var claimType in new[] { "aud", "scp", "tid", "oid", "upn", "preferred_username" })
{
    var claim = jwt.Claims.FirstOrDefault(c => c.Type == claimType);
    if (claim is not null) Console.WriteLine($"  {claimType}: {claim.Value}");
}

Console.WriteLine();
Console.WriteLine("Isso prova o 1o hop do OBO: o usuario recebeu um token delegado");
Console.WriteLine("escopado para a API real do lab (aud = api appId, scp = user_impersonation).");
Console.WriteLine();
Console.WriteLine("Access token (para usar na Camada 2):");
Console.WriteLine(result.AccessToken);
return 0;
