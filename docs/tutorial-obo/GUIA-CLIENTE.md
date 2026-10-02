# Guia rápido — validação do OBO (passo a passo para o cliente)

Este guia é a versão enxuta, para você (cliente) executar sozinho no **seu
próprio tenant**, validando o fluxo OBO (On-Behalf-Of) em duas camadas, sem
precisar subir o AKS completo. Para detalhes técnicos e mapeamento com o
código real do lab, veja `README.md` nesta mesma pasta.

Tempo estimado: **20-30 minutos** na primeira vez (inclui preparação única);
**~10 minutos** em reexecuções.

## O que você vai precisar (uma vez só)

Preencha esta tabela com os valores do seu ambiente antes de começar:

| Valor | Onde conseguir |
|---|---|
| `<tenantId>` | `az account show --query tenantId -o tsv` |
| `<api-appId>` | App ID da App Registration da API (`obo-api` ou equivalente) |
| `<api-object-id>` | Object ID dessa mesma App Registration (`az ad app show --id <api-appId> --query id -o tsv`) |
| `<scope-id-user_impersonation>` | `az ad app show --id <api-appId> --query "api.oauth2PermissionScopes[?value=='user_impersonation'].id" -o tsv` |
| `<keyVaultName>` | Nome do Key Vault que guarda a chave de criptografia |
| `<seu-objectId>` | `az ad signed-in-user show --query id -o tsv` (depois de logado) |

## Passo 1 — Login

```powershell
az login --tenant "<tenantId>" --allow-no-subscriptions
```

> Use o `az login` normal (browser). Não é necessário device code — o
> tutorial foi desenhado para funcionar mesmo com Conditional Access/MFA
> ativos no seu tenant.

## Passo 2 — Preparação única no tenant

Estes 4 comandos só precisam ser rodados **uma vez** (não a cada execução):

```powershell
# 2.1 Dar a você (ou ao usuário de teste) permissão para ler a chave no Key Vault
az role assignment create `
  --assignee-object-id "<seu-objectId>" `
  --assignee-principal-type User `
  --role "Key Vault Crypto User" `
  --scope "/subscriptions/<subscriptionId>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<keyVaultName>"

# 2.2 Autorizar o Azure CLI a pedir token para a API (evita erro de consentimento)
$body = @{
  api = @{
    preAuthorizedApplications = @(
      @{ appId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"; delegatedPermissionIds = @("<scope-id-user_impersonation>") }
    )
  }
} | ConvertTo-Json -Depth 5
az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/<api-object-id>" `
  --headers "Content-Type=application/json" --body $body

# 2.3 Criar um client secret temporário (para o middle tier local)
az ad app credential reset --id "<api-appId>" --display-name "tutorial-obo-temp" --years 1 --query password -o tsv
# >>> guarde o valor retornado, vai ser usado no Passo 4 <<<

# 2.4 Se o Key Vault bloquear acesso público, libere seu IP de saída
curl https://ifconfig.me   # descubra seu IP público
az keyvault update --name "<keyVaultName>" --public-network-access Enabled --default-action Deny --bypass AzureServices
az keyvault network-rule add --name "<keyVaultName>" --ip-address "<seu-ip-publico>/32"
```

## Passo 3 — Camada 1: provar o 1º hop (usuário → API)

```powershell
cd src\samples\obo-tutorial\Step1.ConsoleLogin
dotnet run -- <tenantId> <api-appId>
```

Saída esperada (sem nenhuma interação, usa a sessão do `az login`):

```
Token adquirido com sucesso. Claims relevantes:
  aud: <api-appId>
  scp: user_impersonation
  ...
```

✅ Se aparecer isso, o 1º hop do OBO está funcionando.

## Passo 4 — Camada 2: provar o 2º hop (API → Key Vault)

```powershell
# Em um terminal: configurar e subir o middle tier
cd src\samples\obo-tutorial\Step2.MiddleTier
dotnet user-secrets set "AzureAd:TenantId" "<tenantId>"
dotnet user-secrets set "AzureAd:ClientId" "<api-appId>"
dotnet user-secrets set "AzureAd:ClientSecret" "<secret-do-Passo-2.3>"
dotnet user-secrets set "KeyVault:Uri" "https://<keyVaultName>.vault.azure.net"
dotnet run --urls http://localhost:5080

# Em outro terminal: rodar o cliente
cd src\samples\obo-tutorial\Step2.ConsoleClient
dotnet run -- <tenantId> <api-appId>
```

Saída esperada:

```
Status: 200 OK
Resposta (metadados da chave no Key Vault, via OBO em 2 hops):
{ "key": { "kid": "...", "kty": "RSA", ... }, ... }
```

✅ Se aparecer `200 OK` com os metadados da chave, o fluxo OBO completo (2
hops) está validado no seu ambiente.

## Encerrando (opcional)

Se não for reexecutar o tutorial, você pode remover os ajustes temporários do
Passo 2 (secret, role, firewall) — comandos de rollback em `README.md`,
seção "Limpeza". A pré-autorização do Azure CLI (passo 2.2) pode ficar
permanente, não concede acesso extra por si só.

## Se algo der errado

| Sintoma | Causa provável |
|---|---|
| `CredentialUnavailableException` / "faça login" | Rode `az login --tenant <tenantId>` novamente |
| `AADSTS65001` (consentimento) | Repita o Passo 2.2 (preAuthorizedApplications) |
| `403 Forbidden` no Key Vault | Falta a role `Key Vault Crypto User` (Passo 2.1) ou o IP não está liberado (Passo 2.4) |
| Connection refused no Step2.ConsoleClient | O `Step2.MiddleTier` não está rodando — confira o primeiro terminal |
