// Camada 2 (cliente) do tutorial de OBO: reaproveita o login do usuário de
// teste (igual à Camada 1, via AzureCliCredential/az login) e chama o
// "middle tier" local, que por sua vez faz o 2o hop OBO para o Key Vault.
// Prova as duas camadas do fluxo: usuário -> API -> Key Vault, tudo local,
// sem container.
//
// Pré-requisito: az login --tenant <tenantId> já executado (uma vez).
// Uso: dotnet run -- <tenantId> <apiAppId> [middleTierUrl]
using Azure.Core;
using Azure.Identity;

if (args.Length < 2)
{
    Console.WriteLine("Uso: dotnet run -- <tenantId> <apiAppId> [middleTierUrl]");
    Console.WriteLine("Os valores do lab atual estão em .local\\aks\\deployment.local.json (tenantId, api.appId).");
    Console.WriteLine("middleTierUrl default: http://localhost:5080");
    Console.WriteLine("Pré-requisito: az login --tenant <tenantId> (uma vez) nesta mesma sessão/perfil.");
    return 1;
}

var tenantId = args[0];
var apiAppId = args[1];
var middleTierUrl = args.Length > 2 ? args[2] : "http://localhost:5080";
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

Console.WriteLine();
Console.WriteLine($"Token adquirido. Chamando o middle tier local em {middleTierUrl}/keyvault-demo ...");

using var client = new HttpClient();
client.DefaultRequestHeaders.Authorization = new("Bearer", token.Token);
var response = await client.GetAsync($"{middleTierUrl}/keyvault-demo");
var body = await response.Content.ReadAsStringAsync();

Console.WriteLine();
Console.WriteLine($"Status: {(int)response.StatusCode} {response.StatusCode}");
Console.WriteLine("Resposta (metadados da chave no Key Vault, via OBO em 2 hops):");
Console.WriteLine(body);
return 0;
