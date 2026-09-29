# Deploy no AKS

Execute os comandos na raiz do repositório. Substitua os placeholders pelos
valores do ambiente. O estado do deploy fica em `.local`.
O [deploy ACA](legacy/aca.md) usa outros scripts.

## 1. Pre-requisitos e permissões

| Onde | Necessário |
|---|---|
| Máquina do operador | PowerShell 7, Azure CLI/Bicep atuais, kubectl e kubelogin |
| Validação local | SDK compatível com .NET 8; Node.js 20+ e npm para Playwright; Python 3 para testes de certificado |
| Rede administrativa | Rota estavel ao controle do AKS por uma saida aprovada |
| Azure | Criação dos recursos e role assignments da PoC |
| Entra | Criação de aplicações/service principals, federação e admin consent delegado |
| Login E2E | Usuário explicitamente configurado como remetente e destinatário; login/MFA manual |

As imagens são construídas no ACR, sem Docker local ou módulo SqlServer.
A validação utilizou Azure CLI 2.90 e Bicep 0.47.

Solicite os acessos listados em [identidades e permissões](identidades-e-permissoes.md).
RBAC da subscription e permissões Entra são concedidos separadamente.

## 2. Selecionar o ambiente e validar localmente

```powershell
az login --tenant "<tenant-id>"
az rest --subscription "<subscription-id>" --method get `
  --url "https://management.azure.com/subscriptions/<subscription-id>?api-version=2022-12-01" `
  --query "{name:displayName,state:state}"

.\scripts\preflight-azure.ps1 -TenantId "<tenant-id>" -Architecture AKS
dotnet test .\OboSqlServer.sln --configuration Release
.\tests\scripts\manifests.Tests.ps1
.\tests\scripts\architecture.Tests.ps1
.\tests\scripts\deployment.Tests.ps1
.\tests\scripts\state.Tests.ps1
.\tests\scripts\certificate.Tests.ps1
.\tests\scripts\azure-cli.Tests.ps1
python -m unittest discover -s .\tests\python -v
az bicep build --file .\infra\bicep\aks.bicep --stdout > $null
```

O preflight consulta providers e lista regiões. Consulte também a quota de
vCPU, a SKU da VM e as versões AKS/Istio disponíveis na região.
O deploy verifica o ID da subscription pela ARM API; o nome no cache CLI pode
estar desatualizado.

## 3. Provisionar recursos e identidades

O deploy pode ser separado em recursos/federações e publicação. A primeira etapa
usa ARM/Entra; a segunda exige acesso autenticado ao Kubernetes:

```powershell
.\scripts\deploy-aks.ps1 `
  -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" `
  -ResourceGroupName "rg-obo-aks-poc-brs-001" `
  -Location "brazilsouth" `
  -OperatorCidrs @("<approved-egress-ip>/32") `
  -SenderObjectIds @("<sender-user-object-id>") `
  -ReceiverObjectIds @("<receiver-user-object-id>") `
  -InfrastructureOnly
```

O script cria as duas App Registrations, configura consentimento, executa
what-if e aplica `infra\bicep\aks.bicep`. Em seguida, configura federações e
redirects do BFF. Usa credenciais federadas, sem client secrets.
Crypto User é concedido aos participantes informados. Os usuários de teste
`db_owner` pertencem à etapa opcional da seção 6.

### Parâmetros

| Parâmetro | Valor a fornecer |
|---|---|
| `SubscriptionId` / `TenantId` | IDs do destino; o script confere a correspondencia na ARM |
| `ResourceGroupName` | RG exclusivo do exemplo; o script não assume posse de RG sem sua tag |
| `Location` | Região aprovada com disponibilidade/quotas para os recursos |
| `OperatorCidrs` | Saidas administrativas explicitamente aprovadas, não IPs de usuários finais |
| `SenderObjectIds` | Object IDs de usuários que podem inserir documentos |
| `ReceiverObjectIds` | Object IDs de usuários que podem consultar documentos destinados a eles |
| `KubernetesVersion` / `IstioRevision` | Versões compatíveis e disponiveis no destino |
| `OutputDirectory` | Diretório local privado para estado; padrão `.local\aks` |

O mesmo usuário pode estar nas duas listas. Listas vazias na primeira implantação
não criam usuários de aplicação; o script emite aviso. Nas reaplicações, omitir
um parâmetro preserva a lista anterior.

Os outputs ficam em `.local\aks\deployment.local.json`.
`infrastructureReady=false` indica que a configuração de recursos/federações
precisa terminar antes da publicação.

Reaplicar a infraestrutura preserva as tags de imagens existentes. Em um ambiente
novo, as tags ficam vazias até o build; `-SkipImageBuild` recusa esse estado.
O arquivo `aks.parameters.json.example` descreve os parâmetros do template.
O script gera o arquivo local usado no deploy.

## 4. Publicar a aplicação

```powershell
.\scripts\deploy-aks.ps1 `
  -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" `
  -ResourceGroupName "rg-obo-aks-poc-brs-001" -SkipInfrastructure
```

Execute de uma máquina com saída incluída em `OperatorCidrs`.
A máquina administrativa não é provisionada pelo projeto.

O script constrói três imagens no ACR e aplica os manifests via kubectl.
O Job de bootstrap publica a SPA e configura CMK, CEK, tabelas e usuários dentro
da VNet. O token SQL do operador passa em memória para um Secret temporário;
o Secret e o Job são removidos ao terminar.

Após aplicar workloads e políticas, o script espera readiness, solicita o
certificado Let's Encrypt e consulta `/healthz`. SQL, Key Vault e Storage
permanecem com acesso público desabilitado.
[Detalhes de operação](aks-bff.md).

## 5. E2E real no navegador

```powershell
Set-Location .\tests\browser
npm ci
npx playwright install chromium
$env:OBO_BASE_URL = "https://<public-host>"
npm run test:live
```

Conclua login/MFA e deixe a automação operar a tela. O teste compara os bytes
enviados e recebidos, verifica negações, CSRF, cookies e logout.
A espera de login não expira; depois, o teste tem cinco minutos para concluir.
Configure o usuário nas duas listas para a suite de round-trip.

## 6. Validação de segregacao (opcional)

Execute somente em um ambiente autorizado para criar identidades/grants de teste:

```powershell
.\scripts\setup-validation.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json
.\scripts\test-aks.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json -IncludeSegregation
```

`setup-validation.ps1` aplica `validation.bicep` com what-if, cria quatro
ServiceAccounts e executa o Job `setup-validation` com token SQL administrativo
efêmero. Dois usuários `db_owner` são controles de teste, não identidades da
aplicação. O estado separado `validation.local.json` só e marcado pronto após
concluir os grants. `test-aks.ps1` sem o switch não cria nem exige esses recursos.

Para retirar apenas os controles, mantendo a aplicação:

```powershell
.\scripts\remove-validation.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json -WhatIf
.\scripts\remove-validation.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json
```

O teardown pede confirmação e confere nomes, IDs, tags e escopos. Remove usuários
SQL, Jobs, ServiceAccounts e identidades/grants de teste. Os registros sintéticos
no SQL permanecem.

## 7. Repetir sem republicar ou atualizar a aplicação

```powershell
.\scripts\test-aks.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json

# Publicar codigo novo (build remoto incluso):
.\scripts\deploy-aks.ps1 -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" `
  -SkipInfrastructure

# Ou reaplicar a tag ja construida:
.\scripts\deploy-aks.ps1 -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" `
  -SkipInfrastructure -SkipImageBuild
```

Publicar/reiniciar o BFF invalida sessões. `test-aks.ps1` não altera os workloads
da aplicação nem pede token SQL do operador. Apenas com `-IncludeSegregation`
cria fixtures/Jobs usando as identidades opcionais ja configuradas.
`tag` identifica as imagens da aplicação; `operationsTag` pode identificar uma
sonda atualizada sem trocar o BFF. Um build completo atualiza ambas.

O manifesto renderizado inclui sua revisão SHA-256 nos pod templates de BFF
e API. Alterações de configuração provocam rollout mesmo com `-SkipImageBuild`.
Reaplicar o mesmo manifesto mantém os pods. O restart do BFF exige novo login.

## Deploy em uma única etapa

Com ferramentas e rota estavel ao controle do AKS:

```powershell
.\scripts\deploy-aks.ps1 -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" `
  -OperatorCidrs @("<approved-egress-ip>/32") `
  -SenderObjectIds @("<sender-user-object-id>") `
  -ReceiverObjectIds @("<receiver-user-object-id>")
```

`-SkipInfrastructure` retoma somente build/bootstrap/workloads.
`-BuildImagesOnly` junto de `-SkipInfrastructure` constroi as imagens sem
conectar via kubectl. Não infira faixas maiores a partir de IPs variáveis.
Mudancas nas listas de usuários exigem a etapa de infraestrutura para aplicar
RBAC no Key Vault; não podem ser passadas junto de `-SkipInfrastructure`.
Retirar IDs da configuração não revoga grants existentes. Faça a revogação
separadamente no SQL e no RBAC.

## Cleanup do ambiente

O comando exclui o RG inteiro. Confira o destino com `-WhatIf`:

```powershell
.\scripts\cleanup.ps1 -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "rg-obo-aks-poc-brs-001" -WhatIf

# Somente depois de conferir o alvo:
.\scripts\cleanup.ps1 -SubscriptionId "<subscription-id>" `
  -ResourceGroupName "rg-obo-aks-poc-brs-001"
```

O script pede confirmação e solicita exclusão assíncrona. Aguarde a conclusão.
AKS remove seu node RG gerenciado. Remova as duas App Registrations separadamente,
pelos IDs no estado local. O Key Vault fica retido por soft delete/purge protection.
Guarde o estado local até concluir a limpeza.

## Troubleshooting

| Sintoma | Conferir |
|---|---|
| `kubectl` timeout TLS | IP de saida vs `OperatorCidrs`; use rota administrativa autorizada, não amplie para `0.0.0.0/0` |
| BFF 500 / `IDW10503` | Token acquisition deve usar `OpenIdConnect`, não `Cookies` |
| Falha em federation | Issuer, subject/ServiceAccount, audience e arquivo projetado do workload |
| API 401/403 | Audience v2 igual ao client ID, scope delegado, AllowedClientId e ACL |
| SQL 18456 nos testes | SID de app/MI usa client ID; não usar object ID para esse SID |
| Usuário real sem acesso a documentos | Confirme listas de usuários, grants SQL e Crypto User; `/healthz` não valida esses acessos |
| Segregacao solicitada sem setup | Execute `setup-validation.ps1`; não e parte obrigatoria do deploy |
| Key Vault 403 | Distinguir `ForbiddenByRbac` de `ForbiddenByConnection`; validar DNS/rede e identidade |
| CMK falha no provisionamento ARM | Deve ser criada pelo Job privado, não abrir firewall do vault |
| Blob anônimo 409 dentro da VNet | `PublicAccessNotPermitted` e esperado; a leitura autenticada do BFF deve funcionar |
| Certificado/HTTPS indisponível | O Secret `obo-tls` deve ter tipo `kubernetes.io/tls`; reaplique o deploy para inicializá-lo e publicar o certificado do PVC |
| PATCH do certificado retorna 422 | O tipo do Secret é imutável. O deploy substitui somente um placeholder `Opaque` vazio; Secrets com dados exigem revisão manual |

## Adaptacao e ambientes anteriores

Os scripts criam um RG exclusivo e usam tenant único, hostname Azure e
Let's Encrypt. Integração com recursos existentes ou outra PKI exige alterar
os templates e testar os redirects, identidades e TLS.

Em ambientes de versões anteriores deste exemplo, reaplicacao incremental de
Bicep não remove recursos de teste ou grants antigos. O setup/teardown opcional
pode adotar e remover os controles identificados. Revise os grants antigos do
operador no Key Vault.
Se o estado não contiver `applicationUsers` ou `sqlAdminObjectId`, reaplique a
etapa de infraestrutura com os participantes.
[Procedimentos de validação](validacao.md).
