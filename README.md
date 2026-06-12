# OBO SQL Server — Azure SQL Always Encrypted PoC

[![ORCID](https://img.shields.io/badge/ORCID-0009--0006--0765--4201-A6CE39?logo=orcid&logoColor=white)](https://orcid.org/0009-0006-0765-4201)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Azure](https://img.shields.io/badge/Cloud-Azure-0078D4?logo=microsoftazure&logoColor=white)](#)
[![.NET](https://img.shields.io/badge/.NET-8.0-512BD4?logo=dotnet&logoColor=white)](#)
[![Security](https://img.shields.io/badge/Security-Always%20Encrypted-2E7D32)](#)
[![Last commit](https://img.shields.io/github/last-commit/EdneiMonteiro/obo-sqlserver)](https://github.com/EdneiMonteiro/obo-sqlserver/commits)

## Visao Geral

Este repositorio contem uma prova de conceito (PoC) para validar acesso delegado com OAuth2 On-Behalf-Of (OBO) entre uma API em Azure Container Apps, Azure SQL Database e Azure Key Vault.

O objetivo e demonstrar como armazenar documentos sensiveis em Azure SQL usando criptografia de coluna com Always Encrypted, mantendo o material criptografico fora do banco em Azure Key Vault, de forma que um administrador SQL sem permissao no Key Vault nao consiga ler plaintext.

Este projeto foi criado para aprendizado, avaliacao tecnica e experimentacao.

## Aviso Importante

Este repositorio contem **codigo de exemplo e nao e destinado para uso em producao**.

Antes de utilizar qualquer parte deste projeto em um ambiente produtivo ou critico, revise, valide, proteja e adapte o codigo conforme os requisitos da sua organizacao, incluindo:

- Seguranca
- Escalabilidade
- Confiabilidade
- Monitoramento
- Observabilidade
- Custos
- Conformidade
- Privacidade / LGPD

Leia tambem:

- [DISCLAIMER.md](./DISCLAIMER.md)
- [SUPPORT.md](./SUPPORT.md)

## O que este exemplo demonstra

- Login de usuario com Microsoft Entra ID
- Fluxo OAuth2 On-Behalf-Of para Azure SQL
- Acesso delegado a Azure Key Vault para Always Encrypted
- Azure SQL com dados sensiveis criptografados em coluna
- Autorizacao por documento usando `tid` + `oid` do token Entra
- API .NET 8 Minimal API rodando em Azure Container Apps
- Infraestrutura como codigo com Bicep
- Scripts de preflight, deploy, validacao e cleanup
- Documentacao explicita do limite entre near-E2EE e E2EE estrito

## Near-E2EE vs E2EE estrito

Esta PoC valida um modelo **near-E2EE**:

- O SQL Admin nao deve conseguir ler plaintext.
- A chave mestra fica no Azure Key Vault.
- A aplicacao usa a identidade delegada do usuario para acessar SQL e Key Vault.
- A aplicacao ainda e trusted compute e pode ver plaintext em memoria durante operacoes autorizadas.

Se o requisito for **E2EE estrito**, a criptografia e a descriptografia devem acontecer no cliente final, e o backend deve armazenar apenas ciphertext e metadados.

## Pre-requisitos

- Azure CLI 2.60+ autenticado (`az login --tenant <entra-tenant-id>`)
- GitHub CLI autenticado (`gh auth login`) — opcional
- .NET 8 SDK
- Azure CLI Bicep 0.30+ (`az bicep version`)
- PowerShell 7+
- Modulo SqlServer 22+ (`Install-Module SqlServer -Scope CurrentUser`)
- Permissao para criar recursos na subscription alvo
- Permissao para criar App Registration no Microsoft Entra ID
- Permissao para conceder admin consent no tenant

Tenant alvo: definir antes de rodar o preflight (nao versionar no repositorio).

## Como iniciar

### Editar no VS Code

Sim. O repositorio inclui configuracao em `.vscode/` com extensoes recomendadas, tarefas de restore/build/test/run e launch para debug da API.

```powershell
code .
```

No VS Code:

1. Instale as extensoes recomendadas quando solicitado.
2. Use `Terminal > Run Task` para `dotnet: restore`, `dotnet: build`, `dotnet: test` ou `api: run`.
3. Use `Run and Debug > API: debug` para depurar a API.

### Provisionar e validar (resumo)

O guia completo passo a passo esta em [docs/deploy.md](docs/deploy.md). Resumo dos comandos:

```powershell
# 1. Preflight
.\scripts\preflight-azure.ps1 -TenantId "<entra-tenant-id>" -ForecastsPath ".\forecasts.local.json"

# 2. Deploy infra
Copy-Item .\infra\bicep\main.parameters.json.example .\infra\bicep\main.parameters.local.json
.\scripts\deploy-infra.ps1 -SubscriptionId "<sub-id>" -ResourceGroupName "rg-obo-sql-poc-brs-001" `
  -ParametersFile ".\infra\bicep\main.parameters.local.json"

# 3. Liberar IP do operador no SQL (one-off)
$myIp = (Invoke-RestMethod 'https://api.ipify.org?format=json').ip
az sql server firewall-rule create -g rg-obo-sql-poc-brs-001 -s <sql-server> `
  -n allow-operator-ip --start-ip-address $myIp --end-ip-address $myIp

# 4. Always Encrypted (CMK + CEK + tabelas)
.\scripts\setup-always-encrypted.ps1 -SqlServerFqdn "<sql>.database.windows.net" `
  -DatabaseName "sqldb-obo-sql-poc" -KeyVaultKeyUrl "<keyVaultKeyId>"

# 5. App Registration (scope, perms, secret)
.\scripts\create-app-registration.ps1 -TenantId "<tenant>" `
  -SecretOutputPath ".\client-secret.local.txt"

# 6. Build e push da imagem
.\scripts\build-and-push-image.ps1 -SubscriptionId "<sub-id>" `
  -ResourceGroupName "rg-obo-sql-poc-brs-001" -AcrName "cr<random>" -Tag "1.0.0"

# 7. Atualizar Container App
.\scripts\update-container-app.ps1 -SubscriptionId "<sub-id>" `
  -ResourceGroupName "rg-obo-sql-poc-brs-001" `
  -ContainerAppName "ca-obo-sql-api-poc-brs" `
  -ManagedIdentityName "id-obo-sql-api-poc-brs" `
  -AcrName "cr<random>" `
  -Image "<acr>.azurecr.io/obo-sqlserver-api:1.0.0" `
  -TenantId "<tenant>" -ApiClientId "<client-id>" `
  -ClientSecretFile ".\client-secret.local.txt"

# 8. Validacao end-to-end (7 testes)
.\scripts\validate-poc.ps1 -BaseUrl "https://<app-url>" `
  -ApiClientId "<client-id>" `
  -SqlServerFqdn "<sql>.database.windows.net" -DatabaseName "sqldb-obo-sql-poc"

# 9. Cleanup
.\scripts\cleanup.ps1 -SubscriptionId "<sub-id>" -ResourceGroupName "rg-obo-sql-poc-brs-001"
```

## Arquitetura

```mermaid
sequenceDiagram
    participant Sender as Sender Client
    participant App as Container App API
    participant Entra as Microsoft Entra ID
    participant KV as Azure Key Vault
    participant SQL as Azure SQL Database
    participant Receiver as Receiver Client

    Sender->>Entra: Login OAuth2
    Sender->>App: POST /documents com bearer token
    App->>Entra: OBO token para SQL/KV
    App->>KV: unwrap/acesso CMK via Always Encrypted
    App->>SQL: INSERT ciphertext + ACL
    Receiver->>Entra: Login OAuth2
    Receiver->>App: GET /documents/{id}
    App->>SQL: Verifica ACL por tid/oid
    App->>KV: unwrap/acesso CMK via Always Encrypted
    App-->>Receiver: Plaintext somente se autorizado
```

| Recurso | Finalidade |
|---------|------------|
| Azure Container Apps | Hospeda a API .NET 8 |
| Azure SQL Database | Armazena documentos criptografados e metadados de ACL |
| Azure Key Vault | Armazena a Column Master Key usada pelo Always Encrypted |
| Microsoft Entra ID | Autenticacao, tokens e fluxo OBO |
| Log Analytics | Logs operacionais sem payload sensivel |

## Documentacao

| Documento | Descricao |
|-----------|-----------|
| [docs/deploy.md](docs/deploy.md) | Guia end-to-end de deploy, configuracao, validacao e troubleshooting |
| [docs/arquitetura.md](docs/arquitetura.md) | Arquitetura e principais decisoes |
| [docs/fluxo-logico.md](docs/fluxo-logico.md) | Fluxo detalhado de escrita e leitura |
| [docs/componentes-azure.md](docs/componentes-azure.md) | Componentes Azure e escolhas de SKU |
| [docs/modelo-ameacas.md](docs/modelo-ameacas.md) | Ameacas cobertas, nao cobertas e riscos residuais |
| [docs/validacao.md](docs/validacao.md) | Criterios de validacao e resultados |
| [docs/publicacao.md](docs/publicacao.md) | Checklist antes de tornar o repositorio publico |

## Suporte

Este projeto **nao possui SLA nem suporte oficial**.

Veja [SUPPORT.md](./SUPPORT.md) para detalhes.

## Aviso Legal

O uso deste projeto esta sujeito aos termos descritos em [DISCLAIMER.md](./DISCLAIMER.md).

## Contribuicoes

Contribuicoes podem ser aceitas a criterio do mantenedor.

## Marcas Registradas (Trademarks)

Os nomes e servicos da Microsoft sao utilizados apenas para fins descritivos.

Este projeto **nao e afiliado, endossado ou suportado oficialmente pela Microsoft**.

O uso de marcas da Microsoft nao deve sugerir qualquer tipo de parceria ou suporte oficial.
