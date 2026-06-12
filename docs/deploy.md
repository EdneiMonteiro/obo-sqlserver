# Guia de deploy

Procedimento end-to-end para provisionar a PoC do zero em uma subscription Azure e validar os 7 testes de seguranca.

> Tempo medio: 20-30 minutos de operacao interativa + 10 minutos de espera por provisioning.

## 1. Pre-requisitos

Ferramentas locais:

- Azure CLI 2.60+ (`az version`)
- Bicep 0.30+ (`az bicep version`)
- .NET 8 SDK (`dotnet --version`)
- PowerShell 7+ (`pwsh --version`)
- Modulo SqlServer 22+ (`Install-Module SqlServer -Scope CurrentUser`)
- GitHub CLI (opcional para clonar o repo)

Permissoes no Azure:

- Owner (ou Contributor + User Access Administrator) na subscription escolhida.
- Permissao para criar App Registration no Microsoft Entra ID.
- Permissao para conceder admin consent no tenant.

> Esta PoC usa endpoints publicos restritos para reduzir custo. Para producao, planeje Private Endpoint + VNet integration antes de subir.

## 2. Preflight

Selecione a subscription com maior folga de forecast contra um limite (ex.: USD 150) e confirme registro de providers e regioes.

```powershell
# Exemplo de mapping local de forecast (NAO commitar no repo)
$forecasts = @(
  @{ name='SubA'; subscriptionId='<sub-A>'; currency='USD'; forecast=80;  limitUsd=150 },
  @{ name='SubB'; subscriptionId='<sub-B>'; currency='BRL'; forecast=400; limitUsd=150 },
  @{ name='SubC'; subscriptionId='<sub-C>'; currency='USD'; forecast=95;  limitUsd=150 }
)
$forecasts | ConvertTo-Json -Depth 4 | Out-File -LiteralPath .\forecasts.local.json -Encoding utf8

.\scripts\preflight-azure.ps1 -TenantId "<entra-tenant-id>" -ForecastsPath .\forecasts.local.json
```

A saida mostra:

- Subscriptions enabled no tenant.
- Headroom em USD ordenado.
- Status dos providers (`Microsoft.App`, `Microsoft.Sql`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`, `Microsoft.ManagedIdentity`).
- Regioes candidatas (`brazilsouth`, `eastus`, `eastus2`).

> `forecasts.local.json` esta no `.gitignore` (padrao `*.local.json`).

## 3. Provisionar infraestrutura

Crie o arquivo de parametros local a partir do exemplo.

```powershell
Copy-Item .\infra\bicep\main.parameters.json.example .\infra\bicep\main.parameters.local.json
```

Edite `main.parameters.local.json` com:

- `sqlEntraAdminObjectId`: object id do usuario Entra que sera o admin do SQL.
- `sqlEntraAdminLogin`: UPN do mesmo usuario.
- `keyVaultCryptoUserObjectIds`: array com os object ids que devem receber Key Vault Crypto User para Always Encrypted (inclua sender e receiver da PoC).
- `allowAzureServicesToSql`: `true` (Container Apps Consumption usa IPs Azure).

Faca o deploy:

```powershell
.\scripts\deploy-infra.ps1 `
  -SubscriptionId "<sub-id>" `
  -Location "brazilsouth" `
  -ResourceGroupName "rg-obo-sql-poc-brs-001" `
  -ParametersFile ".\infra\bicep\main.parameters.local.json"
```

Outputs relevantes do deploy (anote):

- `containerAppName`, `containerAppUrl`
- `sqlServerName`, `sqlServerFqdn`, `sqlDatabaseName`
- `keyVaultName`, `keyVaultKeyId`
- `userAssignedIdentityClientId`

> Daily cap do Log Analytics ja vem em 25 MB no Bicep. Ajuste em `workspaceCapping.dailyQuotaGb` se precisar.

## 4. Liberar acesso ao SQL para o operador

Para rodar o setup do Always Encrypted, libere o IP do operador no firewall do SQL.

```powershell
$myIp = (Invoke-RestMethod -Uri 'https://api.ipify.org?format=json').ip
az sql server firewall-rule create `
  -g rg-obo-sql-poc-brs-001 `
  -s <sql-server-name> `
  -n "allow-operator-ip" `
  --start-ip-address $myIp --end-ip-address $myIp
```

Remova a regra apos o setup se nao for usar mais.

## 5. Inicializar Always Encrypted

Cria a Column Master Key (metadata apontando para o AKV), a Column Encryption Key (CEK aleatoria embrulhada pelo AKV) e as tabelas `dbo.Documents` (com `EncryptedPayload varbinary(max) ENCRYPTED WITH ...`) e `dbo.DocumentAccessAudit`.

```powershell
.\scripts\setup-always-encrypted.ps1 `
  -SqlServerFqdn "<sql-server>.database.windows.net" `
  -DatabaseName "sqldb-obo-sql-poc" `
  -KeyVaultKeyUrl "<keyVaultKeyId output>"
```

Validacao rapida:

```powershell
$sqlToken = az account get-access-token --resource 'https://database.windows.net' --query accessToken -o tsv
$cs = "Server=tcp:<fqdn>,1433;Database=sqldb-obo-sql-poc;Encrypt=True;TrustServerCertificate=False;"
Invoke-Sqlcmd -ConnectionString $cs -AccessToken $sqlToken -Query "SELECT name, key_store_provider_name FROM sys.column_master_keys"
```

## 6. Criar App Registration para OBO

Cria a app Entra com scope `user_impersonation`, declara permissoes delegadas para Azure SQL, Key Vault e Microsoft Graph, pre-autoriza o Azure CLI (para testes com `az account get-access-token`) e gera client secret.

```powershell
.\scripts\create-app-registration.ps1 `
  -TenantId "<entra-tenant-id>" `
  -DisplayName "obo-sqlserver-poc-api" `
  -SecretOutputPath ".\client-secret.local.txt"
```

A saida imprime o `clientId`. Salve para os proximos passos. O secret e escrito em `client-secret.local.txt` (gitignored).

> Admin consent e feito automaticamente. Em tenants com Conditional Access bloqueando consent via CLI, faca o consent pelo portal: Microsoft Entra > App registrations > obo-sqlserver-poc-api > API permissions > Grant admin consent.

## 7. Build e push da imagem da API

Cria ACR Basic e roda `az acr build` (build remoto, dispensa Docker local).

```powershell
.\scripts\build-and-push-image.ps1 `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "rg-obo-sql-poc-brs-001" `
  -AcrName "cr<random10>" `
  -Tag "1.0.0"
```

Anote o `loginServer` e a tag (saida JSON).

## 8. Atualizar o Container App com a imagem e secrets

Concede AcrPull ao managed identity, configura registry no ACA, registra o client secret e atualiza imagem + env vars.

```powershell
.\scripts\update-container-app.ps1 `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "rg-obo-sql-poc-brs-001" `
  -ContainerAppName "ca-obo-sql-api-poc-brs" `
  -ManagedIdentityName "id-obo-sql-api-poc-brs" `
  -AcrName "cr<random10>" `
  -Image "<acr>.azurecr.io/obo-sqlserver-api:1.0.0" `
  -TenantId "<entra-tenant-id>" `
  -ApiClientId "<client-id>" `
  -ClientSecretFile ".\client-secret.local.txt"
```

Aguarde 30-60s para a revisao nova ficar `Healthy`:

```powershell
az containerapp revision list -g rg-obo-sql-poc-brs-001 -n ca-obo-sql-api-poc-brs `
  --query "[?properties.active].{name:name, healthState:properties.healthState}" -o table
```

Sanity check:

```powershell
Invoke-RestMethod -Uri "https://<app-url>/healthz"
# -> {"status":"ok"}
```

## 9. Validacao end-to-end (7 testes)

```powershell
.\scripts\validate-poc.ps1 `
  -BaseUrl "https://<app-url>" `
  -ApiClientId "<client-id>" `
  -SqlServerFqdn "<sql-server>.database.windows.net" `
  -DatabaseName "sqldb-obo-sql-poc"
```

Saida esperada: 7/7 PASS.

| # | Teste | Esperado |
|---|---|---|
| T1 | POST sender=me, receiver=me | 201 |
| T2 | POST sender=me, receiver=other | 201 |
| T3 | GET docA com receiver=me | 200 + plaintext igual ao original |
| T4 | GET docB com nao-receiver | 403 |
| T5 | GET sem token | 401 |
| T6 | SQL Admin SUBSTRING na coluna criptografada | erro "Encryption scheme mismatch" |
| T7 | Auditoria gravada | linhas em `dbo.DocumentAccessAudit` |

## 10. Validacao adicional: separacao de duties (opcional)

Os 7 testes acima usam um unico usuario. Para provar que **Always Encrypted + AKV bloqueia o SQL admin sem KV access** e que grants distintos INSERT vs SELECT funcionam com AE ativo, rode:

```powershell
.\scripts\setup-separation-of-duties.ps1 `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "rg-obo-sql-poc-brs-001" `
  -SqlServerFqdn "<sql>.database.windows.net" `
  -DatabaseName "sqldb-obo-sql-poc" `
  -KeyVaultName "<kv-name>" `
  -TenantId "<tenant-id>" `
  -SecretsOutputPath ".\poc-sp-secrets.local.json"

.\scripts\test-separation-of-duties.ps1 `
  -SqlFqdn "<sql>.database.windows.net" `
  -Database "sqldb-obo-sql-poc" `
  -TenantId "<tenant-id>" `
  -SecretsFile ".\poc-sp-secrets.local.json"
```

Detalhes em [separation-of-duties.md](separation-of-duties.md).

## 11. Cleanup

Remove o resource group inteiro.

```powershell
.\scripts\cleanup.ps1 `
  -SubscriptionId "<sub-id>" `
  -ResourceGroupName "rg-obo-sql-poc-brs-001"
```

Também remova manualmente:

- App registration principal (Microsoft Entra > App registrations > obo-sqlserver-poc-api > Delete).
- Service principals do teste de separacao (se rodou): `sp-poc-sender`, `sp-poc-reader`.
- Arquivos locais com secrets (`client-secret.local.txt`, `main.parameters.local.json`, `poc-sp-secrets.local.json`).

> Key Vault tem `softDeleteRetentionInDays = 7` + `enablePurgeProtection = true`. Apos delete, o nome fica reservado por 7 dias. Para reuso imediato, escolha outro `workloadName` no Bicep.

## Troubleshooting

### POST /documents retorna 401

- Audience errado. Em token v2 (`requestedAccessTokenVersion = 2`), `aud = clientId` (sem `api://`). Confirme `AzureAd__Audience = <clientId>` puro nas env vars do ACA.
- Tenant errado no `AzureAd__TenantId`.

### POST /documents retorna 500

- AKV permission ausente para o usuario chamador. Confirme Key Vault Crypto User no escopo do vault.
- CMK/CEK metadata nao criada no SQL. Re-rode `setup-always-encrypted.ps1`.
- Connection string sem `Column Encryption Setting=Enabled`. Verifique env var `Sql__ConnectionString`.

### GET /documents retorna 500

- Bug conhecido: `datetime2` SQL nao casta direto para `DateTimeOffset` no leitor. Ja corrigido na imagem `1.0.1+`.

### Container App nao puxa imagem

- AcrPull ausente. Re-rode `update-container-app.ps1` (e idempotente).
- Registry config sem identidade. Confirme em `properties.configuration.registries`.

### `az acr build` falha por dependencias .NET

- Confirme que `Dockerfile` esta na raiz e `.dockerignore` nao esta excluindo `src/`.

### SQL admin consegue ler plaintext

- CMK nao foi criada via AKV ou Always Encrypted nao foi declarado na coluna. Verifique:

  ```sql
  SELECT name, key_store_provider_name, LEFT(key_path,100) AS path FROM sys.column_master_keys;
  SELECT c.name, c.encryption_type_desc, c.encryption_algorithm_name
  FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
  WHERE t.name = 'Documents' AND c.name = 'EncryptedPayload';
  ```

## Estrutura dos scripts

| Script | Funcao |
|--------|--------|
| `preflight-azure.ps1` | Mapeia subscriptions, calcula headroom, valida providers e regioes |
| `deploy-infra.ps1` | `az deployment group create` com Bicep |
| `setup-always-encrypted.ps1` | Cria CMK metadata, embrulha CEK via AKV provider, cria tabelas |
| `setup-separation-of-duties.ps1` | Cria SPs sender/reader com KV access e grants SQL distintos |
| `test-separation-of-duties.ps1` | Roda S1/S2/R1/R2/E1 demonstrando enforcement e papel do AKV |
| `create-app-registration.ps1` | Cria app Entra, scope, permissoes, pre-autoriza Azure CLI, gera secret |
| `build-and-push-image.ps1` | Cria ACR se nao existir e roda `az acr build` |
| `update-container-app.ps1` | AcrPull + registry + secret + env vars + imagem nova |
| `validate-poc.ps1` | 7 testes black-box (POST/GET/auth/SQL admin/audit) |
| `cleanup.ps1` | `az group delete` |

## Custos esperados (PoC ociosa, brazilsouth)

| Recurso | Custo mensal aprox. (USD) |
|---------|---------------------------|
| Azure SQL Basic | ~5 |
| Key Vault Standard | ~0,03 + ops |
| ACA Consumption (min=0) | ~0 (cold) |
| ACR Basic | ~5 |
| Log Analytics | limitado a 25 MB/dia ~ <2 |
| **Total ocioso** | **~10-13** |

Carga real e cold start contam aparte. Para PoC de algumas horas, esperar <USD 1 incremental.
