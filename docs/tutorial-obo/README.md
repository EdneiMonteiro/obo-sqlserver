# Tutorial incremental de OBO (validação local, sem AKS)

Este tutorial valida o fluxo OBO (On-Behalf-Of) em duas camadas, com o mínimo
de código possível, rodando 100% local (`dotnet run`, sem container/cluster).
Reaproveita as App Registrations reais do lab (`obo-api`) em vez de criar
aplicações dedicadas ao tutorial.

Código em `src/samples/obo-tutorial/`:

- `Step1.ConsoleLogin/` — Camada 1: login do usuário + 1o hop (usuário → API).
- `Step2.MiddleTier/` — Camada 2: API mínima que faz o 2o hop (API → Key Vault).
- `Step2.ConsoleClient/` — cliente da Camada 2 (reaproveita o login da Camada 1
  e chama o middle tier local).

## Pré-requisitos

- Lab implantado (`scripts\deploy-aks.ps1` já executado com sucesso) e o
  arquivo de estado `.local\aks\deployment.local.json` presente.
- **Login prévio no Azure CLI, no tenant do lab** (perfil isolado, se você usa
  múltiplos tenants). Os consoles do tutorial **não fazem login sozinhos** —
  eles reaproveitam esta sessão via `AzureCliCredential`:

  ```powershell
  $env:AZURE_CONFIG_DIR = "$HOME\.azure-tenant-<tenantId>"
  az login --tenant "<tenantId>" --allow-no-subscriptions
  ```

  > **Por que não Device Code?** Em tenants com Conditional Access (acesso
  > condicional) configurado, o fluxo de *device code* é comumente bloqueado
  > (é mais difícil de amarrar a um dispositivo gerenciado/compliant). O
  > `az login` comum (browser/broker) passa normalmente pelas políticas de CA
  > e MFA. Por isso o tutorial usa `Azure.Identity.AzureCliCredential`, que
  > obtém tokens a partir da sessão já autenticada do `az login`, sem abrir
  > nenhum fluxo interativo dentro do próprio app .NET.

- .NET SDK 8.0.
- Um usuário de teste com conta no tenant (pode ser o próprio operador, se não
  houver uma conta de teste dedicada no lab).

## Camada 0 — Preparação (uma vez só)

Os valores abaixo vêm de `.local\aks\deployment.local.json` (chaves `tenantId`,
`api.appId`, `outputs.keyVaultName`). Substitua pelos valores do seu ambiente.

1. **Conceder ao usuário de teste a role `Key Vault Crypto User`** no vault do
   lab (necessário para o 2o hop conseguir desembrulhar/ler a chave):

   ```powershell
   az role assignment create `
     --assignee-object-id "<objectId-do-usuario-de-teste>" `
     --assignee-principal-type User `
     --role "Key Vault Crypto User" `
     --scope "/subscriptions/<subscriptionId>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<keyVaultName>"
   ```

2. **Pré-autorizar o Azure CLI em `obo-api`** (necessário porque o
   `AzureCliCredential` pede o token usando o app first-party "Microsoft Azure
   CLI", `04b07795-8ddb-461a-bbee-02f9e1bf7b46` — em tenants com consentimento
   de usuário restrito, isso evita um `AADSTS65001` ao solicitar o escopo
   `user_impersonation` de `obo-api`):

   ```powershell
   $body = @{
     api = @{
       preAuthorizedApplications = @(
         @{
           appId = "04b07795-8ddb-461a-bbee-02f9e1bf7b46"
           delegatedPermissionIds = @("<id-do-escopo-user_impersonation-de-obo-api>")
         }
       )
     }
   } | ConvertTo-Json -Depth 5
   az rest --method PATCH --uri "https://graph.microsoft.com/v1.0/applications/<object-id-de-obo-api>" `
     --headers "Content-Type=application/json" --body $body
   ```

   > Este ajuste é **permanente** (não precisa ser revertido na limpeza): ele
   > só autoriza o Azure CLI a solicitar, em nome do usuário logado, um token
   > para `obo-api` — não concede nenhum acesso adicional por si só.

3. **Criar um client secret temporário em `obo-api`** (necessário para o
   middle tier local fazer OBO como confidential client — localmente não há
   credencial federada de workload, que só existe dentro do AKS):

   ```powershell
   az ad app credential reset --id "<api-appId>" --display-name "tutorial-obo-temp" --years 1 --query password -o tsv
   ```

   Guarde o valor com `dotnet user-secrets` (nunca em arquivo versionado — veja
   Camada 2 abaixo).

4. **Abrir temporariamente o firewall do Key Vault para o seu IP** — o vault do
   lab é implantado com `publicNetworkAccess=Disabled` (só aceita conexões via
   private endpoint, de dentro da VNet do AKS). Para chamá-lo a partir da sua
   máquina local, é preciso liberar seu IP de saída:

   ```powershell
   az keyvault update --name "<keyVaultName>" --public-network-access Enabled --default-action Deny --bypass AzureServices
   az keyvault network-rule add --name "<keyVaultName>" --ip-address "<seu-ip-publico>/32"
   ```

   > Se sua máquina estiver atrás de um Cloud PC / NAT com IP de saída
   > rotativo, descubra a faixa observada (ex.: `curl https://ifconfig.me`
   > algumas vezes) e use um prefixo que cubra a faixa (ex.: `/28`), igual ao
   > ajuste feito para o authorized IP range do AKS.

Todos os passos acima são reversíveis — veja [Limpeza](#limpeza).

## Camada 1 — Login do usuário + 1o hop (`Step1.ConsoleLogin`)

```powershell
cd src\samples\obo-tutorial\Step1.ConsoleLogin
dotnet run -- <tenantId> <api-appId>
```

O programa reaproveita a sessão já autenticada do `az login` (nenhuma
interação é necessária aqui). Saída esperada:

```
Obtendo token via login existente do Azure CLI (az login)...

Token adquirido com sucesso. Claims relevantes:
  aud: <api-appId>
  scp: user_impersonation
  tid: <tenantId>
  oid: <objectId-do-usuario>
  upn: usuario@dominio.com
```

Isso prova o 1o hop: o usuário recebeu um token delegado, escopado para a API
real do lab (`aud` = appId da API, `scp` = `user_impersonation`), igual ao que
o BFF real obtém via `ApiTokenProvider.cs` (`ITokenAcquisition.GetAccessTokenForUserAsync`).

## Camada 2 — 2o hop (`Step2.MiddleTier` + `Step2.ConsoleClient`)

### 2.1. Configurar o middle tier

```powershell
cd src\samples\obo-tutorial\Step2.MiddleTier
dotnet user-secrets set "AzureAd:TenantId" "<tenantId>"
dotnet user-secrets set "AzureAd:ClientId" "<api-appId>"
dotnet user-secrets set "AzureAd:ClientSecret" "<secret-criado-na-Camada-0>"
dotnet user-secrets set "KeyVault:Uri" "https://<keyVaultName>.vault.azure.net"
```

### 2.2. Rodar o middle tier

```powershell
dotnet run --urls http://localhost:5080
```

Deixe rodando em um terminal.

### 2.3. Rodar o cliente, em outro terminal

```powershell
cd src\samples\obo-tutorial\Step2.ConsoleClient
dotnet run -- <tenantId> <api-appId>
```

O cliente repete o login da Camada 1 e chama `GET /keyvault-demo` no middle
tier local, passando o token do usuário no header `Authorization`. Saída
esperada:

```
Status: 200 OK
Resposta (metadados da chave no Key Vault, via OBO em 2 hops):
{
  "key": { "kid": "https://<keyVaultName>.vault.azure.net/keys/cmk-documents/...", "kty": "RSA", ... },
  "attributes": { "enabled": true, ... }
}
```

Isso prova o 2o hop: o middle tier trocou o token do usuário por um token
**on-behalf-of** para o Key Vault (`ITokenAcquisition.GetAccessTokenForUserAsync`
com escopo `https://vault.azure.net/user_impersonation`), igual ao padrão usado
pela API real em `src/api/Security/DelegatedTokenCredential.cs` para
desembrulhar a chave de criptografia (Always Encrypted) nas consultas SQL.

## Como isso mapeia para o BFF/API reais

| Tutorial | Projeto real equivalente |
|---|---|
| `Step1.ConsoleLogin` (login + token p/ API) | `src/bff/Services/ApiTokenProvider.cs` |
| `Step2.MiddleTier` (OBO API → Key Vault) | `src/api/Security/DelegatedTokenCredential.cs` |

A diferença é só a superfície: o tutorial usa um console e uma API minimalista
locais; o lab real usa SPA → BFF → API → AKS com Workload Identity federada
(sem client secret) e TLS público. A mecânica OBO (duas trocas de token
encadeadas, mesmo usuário do início ao fim) é idêntica.

## Apresentação (PowerPoint)

`docs/tutorial-obo/tutorial-obo.pptx` resume este guia em slides (objetivo,
pré-requisitos, Camada 0, Camada 1, Camada 2 com comandos e saída esperada,
mapeamento para o código real e limpeza). Para regenerar após editar este
README:

```powershell
python docs\tutorial-obo\gerar-apresentacao.py
```

Requer o pacote `python-pptx` (`pip install python-pptx`).

## Limpeza

Ao terminar de validar, reverta os ajustes temporários da Camada 0:

```powershell
# 1. Remover o client secret temporário (liste e delete pelo displayName/keyId)
az ad app credential list --id "<api-appId>" --query "[?displayName=='tutorial-obo-temp'].keyId" -o tsv
az ad app credential delete --id "<api-appId>" --key-id "<keyId-retornado-acima>"

# 2. (Opcional) remover a pré-autorização do Azure CLI em obo-api, se você
#    não pretende repetir este tutorial — não é necessário reverter, pois ela
#    não concede acesso extra por si só (só evita o prompt de consentimento).

# 3. Fechar o firewall do Key Vault
az keyvault update --name "<keyVaultName>" --public-network-access Disabled
az keyvault network-rule remove --name "<keyVaultName>" --ip-address "<ip-ou-faixa-liberada>"

# 4. Remover a role assignment do usuário de teste no Key Vault, se ele não
#    precisar continuar com acesso de Crypto User
az role assignment delete `
  --assignee-object-id "<objectId-do-usuario-de-teste>" `
  --role "Key Vault Crypto User" `
  --scope "/subscriptions/<subscriptionId>/resourceGroups/<rg>/providers/Microsoft.KeyVault/vaults/<keyVaultName>"
```

Também remova os `user-secrets` locais do `Step2.MiddleTier`:

```powershell
cd src\samples\obo-tutorial\Step2.MiddleTier
dotnet user-secrets clear
```
