# Validação

Testes do lab AKS/BFF: verificações locais, E2E no navegador e conexões diretas
SQL/Key Vault. Os resultados locais e os obtidos no Azure estão separados abaixo.

O lab Azure foi desprovisionado em 30/09/2026, após concluir as validações.

## Camadas e resultados

| Camada | Execução | Evidencia observada |
|---|---|---|
| .NET local | Build Release e `dotnet test` | 40 testes: API, BFF, timeout/cancelamento do proxy e configuração de participantes do bootstrap |
| Scripts locais | Suites em `tests\scripts` | Deploy sem testes opcionais, rollout por configuração, estado de imagens, falhas do CLI legado, setup/teardown, rede e cleanup com mocks |
| TLS local | `tests\python` | Reconciliacao do Secret com certificado existente e propagacao de falhas |
| UI local | Playwright `npm test` | 1 teste com servicos simulados; upload/download binario e validação de campos |
| E2E real de referência (23/09/2026) | Playwright `npm run test:live` | Login Entra, OBO, arquivo identico, negação, CSRF, sessão e logout: PASS |
| SQL/Key Vault reais de referência | Quatro Jobs no AKS | S1/S2, R1/R2, E1/E2: PASS |
| Blob | Sondas interna/externa e propriedades ARM | Público desabilitado; respostas esperadas 409 e 403 |
| Operação | Verificação antes do encerramento | Bootstrap Secret ausente e HTTPS disponível |

Após a rodada Azure, o bootstrap de participantes, o setup/teardown opcional
e a recuperação de tags/TLS foram alterados e testados localmente.
A CI executa testes locais, sem login ou deploy Azure.

### Reprodução do procedimento em 29/09/2026

Uma implantação nova foi executada pelos scripts documentados, com estado local
novo e sem recursos de validação opcionais.

| Etapa | Resultado |
|---|---|
| Infraestrutura, aplicações Entra e federações | Concluídas |
| Bootstrap de arquivos, chaves e banco | Concluído |
| API e BFF | Deployments disponíveis, pods com sidecars prontos |
| Certificado e Secret TLS | Emitido e publicado após corrigir o tipo do placeholder |
| Smoke interno e externo | HTTPS, sessão anônima, API 401 e Blob privado verificados |
| E2E autenticado desta implantação | PASS: login Entra, OBO, upload/download com bytes idênticos, destinatário negado, CSRF, cookie, isolamento de tokens e logout |
| Segregação opcional | Não executada nesta rodada |

O Kubernetes recusou alterar `obo-tls` de `Opaque` para `kubernetes.io/tls`.
O deploy foi corrigido para criar o tipo definitivo e substituir apenas um
placeholder antigo vazio. A correção possui regressão local e foi aplicada
na nova implantação.

O usuário escolhido para este lab também era SQL admin. O bootstrap emitiu o
aviso documentado; esta rodada não comprova segregação desse usuário.
O E2E foi concluído em 29/09/2026 após login manual, sem republicar a aplicação.

Após esse E2E, as correções de rollout por configuração, timeout completo do proxy
e tratamento de falhas do Azure CLI legado foram verificadas localmente.
As duas correções do AKS foram aplicadas e verificadas no dia seguinte.

### Atualização incremental em 30/09/2026

API e BFF foram atualizados para o código do commit `b078cd0`, sem recriar a
infraestrutura. O bootstrap SQL, os grants e o certificado existente foram
preservados.

| Verificação | Resultado observado |
|---|---|
| ConfigMap alterado, imagens mantidas | BFF e API receberam novos UIDs de pod, com os mesmos digests de imagem; o valor foi conferido no ambiente dos processos |
| Manifesto idêntico reaplicado | UIDs dos pods preservados, sem restart |
| Configuração original restaurada | Marcador de teste removido; workloads prontos |
| Headers enviados sem corpo | Proxy retornou HTTP 504 em 90,014 s |
| Corpo parcial | Cliente recebeu um byte; conexão abortada em 90,007 s, sem concluir a resposta |
| Controle com imagem anterior | Com timeout de 2 s, ambas as transferências continuavam pendentes após 5 s, reproduzindo o defeito |
| Smoke interno e externo | Blob privado com 409/PublicAccessNotPermitted dentro da VNet e 403 fora; API anônima com 401 |
| E2E autenticado após atualização | PASS: login Entra, OBO, bytes idênticos, destinatário negado, CSRF, isolamento de tokens e logout |

A sonda de timeout executou em Job isolado, com a DLL da imagem publicada.
O SHA-256 foi comparado com o arquivo no pod do BFF. Um upstream HTTP controlado
enviou os headers com `FlushAsync` e reteve o restante da resposta. A sonda usou
credencial sintética e o mesmo limite de 90 segundos do BFF, sem alterar suas
rotas públicas. A resposta rápida manteve os bytes e retornou HTTP 200.

Os scripts ACA permanecem cobertos pelas regressões locais. Não foi criado
um ambiente ACA nem foram executados novamente os testes opcionais de
segregação SQL/Key Vault.

### Encerramento do lab em 30/09/2026

Foi confirmada a exclusão do RG do lab e do RG gerenciado pelo AKS, com os
respectivos recursos de computação, rede, armazenamento e banco. As aplicações
Entra da API e do BFF e seus service principals ativos também foram removidos.

O Key Vault permaneceu em soft delete, com purge protection e retenção de sete
dias. O expurgo está previsto para 07/10/2026. O código, os scripts e as
evidências dos testes foram preservados; o endpoint desse lab não está mais ativo.

## 1. Testes locais

```powershell
dotnet test .\OboSqlServer.sln --configuration Release
.\tests\scripts\manifests.Tests.ps1
.\tests\scripts\architecture.Tests.ps1
.\tests\scripts\deployment.Tests.ps1
.\tests\scripts\state.Tests.ps1
.\tests\scripts\certificate.Tests.ps1
.\tests\scripts\azure-cli.Tests.ps1
python -m unittest discover -s .\tests\python -v

Set-Location .\tests\browser
npm ci
npx playwright install chromium
npm test
```

Os testes do BFF usam autenticação por cookie e login sintético no host de teste.
`ApiTokenProviderTests` verifica o esquema OIDC usado na aquisição de tokens.
Os testes da SPA verificam formulários, upload e download no Chromium.
`certificate.Tests.ps1` verifica o tipo imutável do Secret TLS, a substituição
do placeholder vazio e a preservação de certificados existentes.
`DocumentProxyTests` verifica timeout nos headers, no corpo e na escrita para
um cliente lento, aborto de resposta parcial e cancelamento pelo cliente.
`manifests.Tests.ps1` altera configurações mantendo as imagens e exige mudança
dos dois pod templates; reaplicação idêntica deve preservar a revisão.
`azure-cli.Tests.ps1` simula falhas de seleção, consultas e escritas em todos os
scripts legados, sem executar comandos reais no Azure.

## 2. E2E no navegador publicado

```powershell
# Na pasta tests\browser:
$env:OBO_BASE_URL = "https://<public-host>"
npm run test:live
```

O operador conclui login/MFA na janela. Não trocar arquivo ou clicar em Enviar
durante a automacao. Não ha timeout durante o login; após autenticado, o teste
tem cinco minutos para concluir.
Configure o usuário de round-trip nas listas `SenderObjectIds` e `ReceiverObjectIds`.

| Cenario | Assertiva |
|---|---|
| Sessão autenticada | Resposta contem somente authenticated/name/tenantId/objectId/csrfToken |
| Cookie | `__Host-obo-session` presente, HttpOnly e Secure |
| Armazenamento browser | localStorage e sessionStorage vazios |
| POST sem antiforgery | 400 antes da chamada autorizada |
| Envio para o proprio usuário | Criação pela UI e ID retornado |
| Leitura autorizada | Download comparado byte a byte com o fixture enviado |
| Outro destinatário | Documento criado para outro object ID; leitura negada |
| Isolamento de tokens | Nenhum header Authorization enviado pelo browser para a origem da aplicação |
| Logout | Workspace fechado e sessão volta a authenticated=false |

O teste valida TLS e não grava senhas, cookies, storage state, imagens, vídeos
ou traces. A captura de DOM do provedor de identidade está desabilitada.

## 3. Segregacao e rede privada

Na máquina com acesso administrativo autorizado ao AKS:

```powershell
# Smoke funcional: nao cria identidades nem Jobs de teste
.\scripts\test-aks.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json

# Opt-in: cria controles de teste e executa segregacao
.\scripts\setup-validation.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json
.\scripts\test-aks.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json -IncludeSegregation

# Remove somente os controles opcionais, com confirmacao
.\scripts\remove-validation.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json
```

Os helpers verificam `$LASTEXITCODE` das chamadas nativas.

O script confirma `publicNetworkAccess=Disabled`, `allowBlobPublicAccess=false`,
SPA/HTTPS e 401 anônimo. Executado fora da VNet, exige 403 do Blob público.
Dentro da VNet, use `-FromPrivateNetwork`: a resposta esperada e
`409/PublicAccessNotPermitted`. Execute as sondas interna e externa separadamente.

Os Jobs verificam INSERT/SELECT, erro SQL 229, ID/bytes do documento e acesso
dos administradores com/sem chave. O controle sem chave exige ciphertext na
consulta raw e 403/ForbiddenByRbac com AE habilitado. [Grants e critérios](separation-of-duties.md).

O teste de navegador exercita OBO; os Jobs acessam SQL/Key Vault diretamente.

## Testes não executados

Não foram executados testes de carga, HA, recuperação de desastre, pentest
completo ou um ciclo inteiro de renovação ACME. A rota permitida pelo Istio foi
exercitada, mas não todos os caminhos de rede.

O teste de navegador não consulta cada registro de `DocumentAccessAudit`.
A auditoria SQL não é protegida contra alterações de um db_owner.
Diagnósticos centralizados de Key Vault não foram provisionados.
As consultas de `sql\002-validation-queries.sql` exigem acesso à rede privada.

## Legado

`validate-poc.ps1` e os scripts antigos usam o
[deploy ACA](legacy/aca.md), sem BFF. O teste SUBSTRING aceita exceções amplas;
o teste AKS exige os erros e bytes descritos nesta página.
