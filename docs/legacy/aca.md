# Legado: API OBO em Azure Container Apps

Implantação legada com cliente Azure CLI/PowerShell, API no ACA, client secret
e endpoints públicos de SQL/Key Vault. Não inclui SPA, BFF ou Istio.
Use um RG separado do [ambiente AKS](../deploy.md).

## 1. Pre-requisitos

Ferramentas locais:

- Azure CLI 2.60+ (`az version`)
- Bicep 0.30+ (`az bicep version`)
- .NET 8 SDK (`dotnet --version`)
- PowerShell 7+ (`pwsh --version`)
- Modulo SqlServer 22+ (`Install-Module SqlServer -Scope CurrentUser`)
- GitHub CLI (opcional para clonar o repo)

Permissões no Azure:

- Owner (ou Contributor + User Access Administrator) na subscription escolhida.
- Permissão para criar App Registration no Microsoft Entra ID.
- Permissão para conceder admin consent no tenant.

SQL e Key Vault usam endpoints públicos nesta implantação. As regras abaixo
não devem ser aplicadas aos serviços privados do AKS.

## 2. Preflight

Selecione a subscription autorizada para o lab e consulte os providers.

```powershell
.\scripts\preflight-azure.ps1 -TenantId "<entra-tenant-id>" -Architecture ACA
```

A saida mostra:

- Subscriptions enabled no tenant.
- Status dos providers (`Microsoft.App`, `Microsoft.Sql`, `Microsoft.KeyVault`, `Microsoft.OperationalInsights`, `Microsoft.ManagedIdentity`).
- Regiões candidatas (`brazilsouth`, `eastus`, `eastus2`).

Consulte quota e disponibilidade regional antes do deploy.

Os scripts interrompem a execução quando um comando Azure CLI falha.
Os que recebem `SubscriptionId` verificam a seleção e passam esse ID às
operações de recursos. Os demais usam a subscription ativa; quando `TenantId`
é informado, ele deve corresponder ao contexto autenticado.
Falhas ao consultar ACR ou atribuições RBAC não são tratadas como recurso ausente.

## 3. Provisionar infraestrutura

Crie o arquivo de parâmetros local a partir do exemplo.

```powershell
Copy-Item .\infra\bicep\main.parameters.json.example .\infra\bicep\main.parameters.local.json
```

Edite `main.parameters.local.json` com:

- `sqlEntraAdminObjectId`: object id do usuário Entra que sera o admin do SQL.
- `sqlEntraAdminLogin`: UPN do mesmo usuário.
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

Outputs utilizados nas próximas etapas:

- `containerAppName`, `containerAppUrl`
- `sqlServerName`, `sqlServerFqdn`, `sqlDatabaseName`
- `keyVaultName`, `keyVaultKeyId`
- `userAssignedIdentityClientId`

O cap diário de Log Analytics é definido em `workspaceCapping.dailyQuotaGb`.

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

Remova a regra após o setup se não for usar mais.

## 5. Inicializar Always Encrypted

Cria a Column Master Key (metadata apontando para o AKV), a Column Encryption Key (CEK aleatoria embrulhada pelo AKV) e as tabelas `dbo.Documents` (com `EncryptedPayload varbinary(max) ENCRYPTED WITH ...`) e `dbo.DocumentAccessAudit`.

```powershell
.\scripts\setup-always-encrypted.ps1 `
  -SqlServerFqdn "<sql-server>.database.windows.net" `
  -DatabaseName "sqldb-obo-sql-poc" `
  -KeyVaultKeyUrl "<keyVaultKeyId output>"
```

Validação rapida:

```powershell
$sqlToken = az account get-access-token --resource 'https://database.windows.net' --query accessToken -o tsv
$cs = "Server=tcp:<fqdn>,1433;Database=sqldb-obo-sql-poc;Encrypt=True;TrustServerCertificate=False;"
Invoke-Sqlcmd -ConnectionString $cs -AccessToken $sqlToken -Query "SELECT name, key_store_provider_name FROM sys.column_master_keys"
```

## 6. Criar App Registration para OBO

Cria a app Entra com scope `user_impersonation`, declara permissões delegadas para Azure SQL, Key Vault e Microsoft Graph, pre-autoriza o Azure CLI (para testes com `az account get-access-token`) e gera client secret.

```powershell
.\scripts\create-app-registration.ps1 `
  -TenantId "<entra-tenant-id>" `
  -DisplayName "obo-sqlserver-poc-api" `
  -SecretOutputPath ".\client-secret.local.txt"
```

A saída contém o `clientId`. O secret é gravado em `client-secret.local.txt`,
ignorado pelo Git.

> Admin consent é feito automaticamente. Uma falha nessa etapa interrompe o script antes da criação do secret. Em tenants com Conditional Access bloqueando consent via CLI, faça o consent pelo portal: Microsoft Entra > App registrations > obo-sqlserver-poc-api > API permissions > Grant admin consent.

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

Aguarde a nova revisão ficar `Healthy`:

```powershell
az containerapp revision list -g rg-obo-sql-poc-brs-001 -n ca-obo-sql-api-poc-brs `
  --query "[?properties.active].{name:name, healthState:properties.healthState}" -o table
```

Verifique o endpoint:

```powershell
Invoke-RestMethod -Uri "https://<app-url>/healthz"
# -> {"status":"ok"}
```

## 9. Validação end-to-end (7 testes)

```powershell
.\scripts\validate-poc.ps1 `
  -BaseUrl "https://<app-url>" `
  -ApiClientId "<client-id>" `
  -SqlServerFqdn "<sql-server>.database.windows.net" `
  -DatabaseName "sqldb-obo-sql-poc"
```

Saida esperada: 7/7 PASS.

T6 aceita exceções amplas. T7 verifica se há linhas na auditoria, sem correlacionar
cada uma à rodada.

| # | Teste | Esperado |
|---|---|---|
| T1 | POST sender=me, receiver=me | 201 |
| T2 | POST sender=me, receiver=other | 201 |
| T3 | GET docA com receiver=me | 200 + plaintext igual ao original |
| T4 | GET docB com não-receiver | 403 |
| T5 | GET sem token | 401 |
| T6 | SQL Admin SUBSTRING na coluna criptografada | erro "Encryption scheme mismatch" |
| T7 | Auditoria gravada | linhas em `dbo.DocumentAccessAudit` |

## 10. Validação adicional: separacao de duties (opcional)

Os 7 testes acima usam um único usuário. Para explorar a separacao de acesso
SQL/Key Vault e grants INSERT/SELECT no desenho legado, rode:

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

Os [testes AKS](../separation-of-duties.md) usam identidades federadas.
Os scripts legados usam client credentials e não testam o BFF.
O teste legado E1 considera a leitura com chave um sucesso; remover a permissão
faz esse script terminar com falha, embora o bloqueio seja desejado nessa fase.

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

> Key Vault tem `softDeleteRetentionInDays = 7` + `enablePurgeProtection = true`. Após delete, o nome fica reservado por 7 dias. Para reuso imediato, escolha outro `workloadName` no Bicep.

## Troubleshooting

### POST /documents retorna 401

- Audience errado. Em token v2 (`requestedAccessTokenVersion = 2`), `aud = clientId` (sem `api://`). Confirme `AzureAd__Audience = <clientId>` puro nas env vars do ACA.
- Tenant errado no `AzureAd__TenantId`.

### POST /documents retorna 500

- AKV permission ausente para o usuário chamador. Confirme Key Vault Crypto User no escopo do vault.
- CMK/CEK metadata não criada no SQL. Re-rode `setup-always-encrypted.ps1`.
- Connection string sem `Column Encryption Setting=Enabled`. Verifique env var `Sql__ConnectionString`.

### GET /documents retorna 500

- Bug conhecido: `datetime2` SQL não casta direto para `DateTimeOffset` no leitor. Ja corrigido na imagem `1.0.1+`.

### Container App não puxa imagem

- AcrPull ausente. Re-rode `update-container-app.ps1` (e idempotente).
- Registry config sem identidade. Confirme em `properties.configuration.registries`.

### `az acr build` falha por dependencias .NET

- Confirme que `Dockerfile` esta na raiz e `.dockerignore` não esta excluindo `src/`.

### SQL admin consegue ler plaintext

- CMK não foi criada via AKV ou Always Encrypted não foi declarado na coluna. Verifique:

  ```sql
  SELECT name, key_store_provider_name, LEFT(key_path,100) AS path FROM sys.column_master_keys;
  SELECT c.name, c.encryption_type_desc, c.encryption_algorithm_name
  FROM sys.columns c JOIN sys.tables t ON c.object_id = t.object_id
  WHERE t.name = 'Documents' AND c.name = 'EncryptedPayload';
  ```

## Estrutura dos scripts

| Script | Função |
|--------|--------|
| `preflight-azure.ps1 -Architecture ACA` | Lista subscriptions, consulta providers e exibe regiões candidatas |
| `deploy-infra.ps1` | `az deployment group create` com Bicep |
| `setup-always-encrypted.ps1` | Cria CMK metadata, embrulha CEK via AKV provider, cria tabelas |
| `setup-separation-of-duties.ps1` | Cria SPs sender/reader com KV access e grants SQL distintos |
| `test-separation-of-duties.ps1` | Roda S1/S2/R1/R2/E1 demonstrando enforcement e papel do AKV |
| `create-app-registration.ps1` | Cria app Entra, scope, permissões, pre-autoriza Azure CLI, gera secret |
| `build-and-push-image.ps1` | Cria ACR se não existir e roda `az acr build` |
| `update-container-app.ps1` | AcrPull + registry + secret + env vars + imagem nova |
| `validate-poc.ps1` | 7 testes black-box (POST/GET/auth/SQL admin/audit) |
| `cleanup.ps1` | `az group delete` |

## Custos

Estime SQL Basic, Key Vault, ACR Basic, consumo do ACA e ingestão de logs na
região escolhida. O ACA pode reduzir réplicas a zero; SQL e ACR continuam
provisionados. Inclua operações e transferência de dados no cálculo.
