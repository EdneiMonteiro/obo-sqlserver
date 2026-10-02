// Camada 1 do tutorial de OBO: login do usuário de teste + primeiro hop
// (obtenção de um token delegado "user_impersonation" para a API real do lab).
// Não chama nenhum recurso protegido ainda — só prova que o hop usuário -> API
// funciona com a configuração real do Entra ID.
//
// Reaproveita o login já feito via `az login` (AzureCliCredential), em vez de
// abrir um fluxo de Device Code: tenants com Conditional Access costumam
// bloquear o Device Code, mas o login interativo normal do Azure CLI
// (navegador/broker) satisfaz MFA/CA normalmente.
//
// Pré-requisito: az login --tenant <tenantId> já executado (uma vez, na
// sessão do terminal/perfil que você vai usar para rodar este console).
// Uso: dotnet run -- <tenantId> <apiAppId>
using System.IdentityModel.Tokens.Jwt;
using Azure.Core;
using Azure.Identity;

if (args.Length < 2)
{
    Console.WriteLine("Uso: dotnet run -- <tenantId> <apiAppId>");
    Console.WriteLine("Os valores do lab atual estão em .local\\aks\\deployment.local.json (tenantId, api.appId).");
    Console.WriteLine("Pré-requisito: az login --tenant <tenantId> (uma vez) nesta mesma sessão/perfil.");
    return 1;
}

var tenantId = args[0];
var apiAppId = args[1];
var apiScope = $"api://{apiAppId}/.default";

Console.WriteLine("Obtendo token via login existente do Azure CLI (az login)...");
var credential = new AzureCliCredential(new AzureCliCredentialOptions { TenantId = tenantId });

AccessToken token;
try
{
    token = await credential.GetTokenAsync(new TokenRequestContext([apiScope]));
}
catch (CredentialUnavailableException)
{
    Console.WriteLine("Nenhum login do Azure CLI encontrado para este tenant.");
    Console.WriteLine($"Rode primeiro: az login --tenant {tenantId}");
    return 1;
}
catch (AuthenticationFailedException ex)
{
    Console.WriteLine("Falha ao obter o token (ex.: usuário ainda não consentiu o escopo da API).");
    Console.WriteLine(ex.Message);
    return 1;
}

Console.WriteLine();
Console.WriteLine("Token adquirido com sucesso. Claims relevantes:");
var jwt = new JwtSecurityTokenHandler().ReadJwtToken(token.Token);
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
Console.WriteLine(token.Token);
return 0;
