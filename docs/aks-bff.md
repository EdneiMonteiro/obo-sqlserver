# Operação do BFF e AKS

Configuração e manutenção do BFF no AKS.
[Deploy](deploy.md), [arquitetura](arquitetura.md) e [testes](validacao.md).

## Rotas e configuração

| Superficie | Rotas |
|---|---|
| Assets servidos pelo BFF | `/`, `/app.js`, `/styles.css`; allowlist fixa |
| Sessão | `/bff/login`, `/bff/session`, `POST /bff/logout` |
| Callback OIDC | `/signin-oidc`, `/signout-callback-oidc` |
| Proxy autenticado | `POST /api/documents`, `GET /api/documents/{id:guid}` |
| API interna | `POST /documents`, `GET /documents/{id:guid}` |
| Health | `/healthz` em BFF/API; não prova SQL/Key Vault |

O BFF entrega os arquivos da SPA sem exigir login. A leitura da origem Blob
usa a identidade federada do BFF.

| Configuração | Origem / semantica |
|---|---|
| `Bff:PublicOrigin` | Origem HTTPS fixa; redirects OIDC não dependem do Host recebido |
| `Bff:ApiBaseUrl` | Destino fixo da API no cluster; não aceita URL enviada pelo usuário |
| `Bff:ApiScope` | Scope delegado `api://<api-client-id>/user_impersonation` |
| `Bff:BlobContainerUrl` | Endpoint Blob HTTPS sem SAS/credenciais |
| `AzureAd:TenantId`, `ClientId` | Aplicação correspondente ao BFF ou API |
| `AzureAd:ClientCredentials` | `SignedAssertionFilePath` nos workloads AKS |
| `AzureAd:Audience` (API) | Client ID puro para o access token v2 |
| `AzureAd:AllowedClientId` (API) | Client ID do BFF; obrigatorio no manifesto AKS |
| `Sql:ConnectionString` | TLS e `Column Encryption Setting=Enabled` |
| `Sql:DatabaseScope` | Scope SQL delegado |
| `Sql:MaxDocumentBytes` | 10 MiB por padrão |

ConfigMaps contem IDs/endpoints, não segredos. O arquivo de configuração base da
API mantem um placeholder de client secret para compatibilidade local/legada;
quando `ClientCredentials` e configurado, o composition root descarta esse campo.
Nunca acrescente segredo real a um `appsettings.json` versionado.

`Render-Manifest` calcula o SHA-256 do manifesto de aplicações e o inclui na
anotação `checksum/manifest` dos dois pod templates. Ao reaplicar o deploy,
mudanças de configuração substituem os pods mesmo com as mesmas imagens.
Reaplicar um manifesto idêntico não força restart. Alterar um ConfigMap
diretamente com kubectl não recalcula essa anotação.

O encaminhamento HTTP para a API tem limite total de 90 segundos, incluindo
envio, espera pelos headers e cópia do corpo ao navegador. Se o limite for
atingido antes de iniciar a resposta, o BFF retorna 504. Se a resposta já
começou, aborta a conexão. O cancelamento pelo cliente também interrompe a cópia.

## Sessão e escalabilidade

Cookie `__Host-obo-session`: Secure, HttpOnly, path `/`, SameSite=Lax e ticket
server-side. Expira em 30 minutos, sem renovação deslizante. O CSRF usa cookie
proprio e header `x-csrf-token`; não e um token OAuth.

Tickets, cache MSAL e chaves Data Protection ficam no processo do BFF.
O deployment usa uma réplica e Recreate. Restart/deploy invalida sessões.
Mais réplicas exigem compartilhar os três estados.
Logout remove o ticket local; a sessão SSO do Entra permanece.

`ApiTokenProvider` solicita tokens com o esquema `OpenIdConnect`, enquanto
`Cookies` autentica requisições da sessão. `X-Forwarded-Proto` é aceito somente
do sidecar local.

## Identidade e rede

ServiceAccounts `bff` e `api` pertencem ao namespace `obo` e correspondem a
federações distintas no issuer OIDC do AKS. Workload Identity projeta o token do
pod; Microsoft.Identity.Web usa essa credencial para autenticar a aplicação.
Os tokens de acesso do usuário a SQL/Key Vault continuam sendo obtidos por OBO.

Istio usa mTLS STRICT e políticas gateway -> BFF -> API. A NetworkPolicy restringe
comunicacao entre pods; HTTPS de saida para Entra/Azure continua permitido.
SQL, Blob e Key Vault são acessados por Private Endpoints/DNS, sem habilitar
rede publica ou bypass temporário para o bootstrap.

## Bootstrap privado e Jobs

`src\operations` executa dentro da VNet, no namespace `obo-operations`.
O modo `bootstrap`:

1. Publica os tres assets no container privado.
2. Cria/recupera a CMK RSA-3072 pelo data plane privado do Key Vault.
3. Gera uma CEK aleatoria, embrulha-a e aplica o template SQL em transação.
4. Confere a coluna randomized e o caminho versionado da chave.
5. Cria os usuários humanos explicitamente configurados, com permissão de envio,
   leitura ou ambas; não cria usuários de teste.

A identidade de operações tem Blob Data Contributor no container e Crypto Officer
no vault. Para DDL SQL, usa um token temporário do operador, montado em Secret.
Job e Secret são removidos no `finally`.
Usuários humanos usam seu object ID como SID SQL. Aplicações/managed identities
da validação opcional usam **client ID** para o SID, mas **object ID** em RBAC/ACL.
O modo `setup-validation` e separado e só migra SID antigo se ele corresponder
exatamente a identidade de teste conhecida.

As quatro identidades de teste são criadas somente por `setup-validation.ps1`,
não por `deploy-aks.ps1`. Elas persistem para repeticao ate que
`remove-validation.ps1` seja executado; os Jobs tem TTL. A aplicação continua
funcionando sem elas.

## Acesso administrativo e bootstrap

`deploy-aks.ps1` usa Azure CLI e kubectl a partir de uma máquina autorizada.
`OperatorCidrs` define as saídas da rede administrativa autorizadas no AKS.

O token SQL de bootstrap e obtido no contexto autenticado do operador e enviado
pela conexão TLS do Kubernetes em Secret efêmero, sem arquivo local ou argumento
de CLI. Administradores da máquina e do cluster podem acessar esse token.

`test-aks.ps1` faz smoke tests por padrão. Com `-IncludeSegregation`, usa as
identidades federadas dos Jobs e não solicita token SQL do operador nem reinicia
o BFF. Setup/teardown da validação exigem token administrativo efêmero.
Se uma operação for interrompida, confira Jobs e
Secret de bootstrap antes de considerar a limpeza concluida.

## Estado local e retomada

| Arquivo em `.local\aks` | Conteúdo |
|---|---|
| `deployment.local.json` | Destino, apps, participantes, SQL admin, outputs, `infrastructureReady`, `tag` e `operationsTag` |
| `aks.parameters.local.json` | Parâmetros gerados para aquele ambiente |
| `validation.local.json` | Apenas após setup opcional: identidades de teste, alvo e readiness dos grants |
| `validation.parameters.local.json` | Parâmetros da etapa opcional |
| `kubeconfig.local` | Contexto Kubernetes privado do operador |
| `*.local.yaml` | Manifests renderizados, não templates para publicar no Git |

O diretório é ignorado pelo Git e pelo Docker.
`infrastructureReady=false` indica recursos/federações incompletos.
`operationsTag` pode mudar sem trocar o BFF; um build completo atualiza as duas
tags. A infraestrutura preserva as tags se o destino e o registry forem iguais.
Em estado novo, as tags ficam vazias até o build.

## TLS e renovação

O ingress usa IP/hostname Azure e certificado público Let's Encrypt.
HTTP-01 e atendido somente em `/.well-known/acme-challenge/`; o restante do HTTP
redireciona para HTTPS.

Certbot roda diariamente e armazena conta/certificados no PVC.
Após obter ou reutilizar o certificado, `certificate.py` atualiza `obo-tls`.
A ServiceAccount só pode ler e alterar esse Secret.

O deploy cria `obo-tls` com tipo `kubernetes.io/tls` e campos `tls.crt`/`tls.key`
vazios. O Job preenche os campos após obter o certificado. O Kubernetes não
permite alterar o tipo de um Secret existente.

Se existir um placeholder antigo `Opaque` sem dados, o deploy o substitui pelo
tipo TLS. Um Secret TLS existente é preservado; outros tipos contendo dados
interrompem o deploy para revisão manual.

Se o Secret for perdido e o PVC existir, reaplique o deploy. O Job publica o
certificado existente. Erros de Certbot, arquivos ausentes ou falhas no PATCH
fazem o Job falhar. HTTPS só fica disponível após preencher o Secret.

Não foi testado um ciclo completo de expiração. Não há e-mail ACME configurado.
Configure alertas de expiração e falha do CronJob e backup do PVC.

## Desenvolvimento e legado

As tarefas VS Code cobrem restore/build/test da solução, API/BFF e Bicep.
Executar o BFF localmente exige origem HTTPS, redirect Web correspondente e
configuração externa via user-secrets/variáveis, alem de acesso aos servicos
privados. `DefaultAzureCredential` é usado para Blob somente em Development.

O [guia ACA](legacy/aca.md) documenta a implantação legada com cliente CLI e
client secret, sem BFF.

## Referências

- [BFF e OAuth para browsers](https://datatracker.ietf.org/doc/rfc10017/)
- [Federação de workload e MSAL](https://learn.microsoft.com/entra/msal/dotnet/acquiring-tokens/web-apps-apis/workload-identity-federation)
- [Web app que chama API](https://learn.microsoft.com/entra/identity-platform/scenario-web-app-call-api-app-configuration)
- [Ingress Istio](https://learn.microsoft.com/azure/aks/istio-deploy-ingress)
- [Istio CNI](https://learn.microsoft.com/azure/aks/istio-cni)
- [TLS no Istio](https://learn.microsoft.com/azure/aks/istio-secure-gateway)
- [Private Endpoints Storage](https://learn.microsoft.com/azure/storage/common/storage-private-endpoints)
- [CREATE USER e SID](https://learn.microsoft.com/sql/t-sql/statements/create-user-transact-sql?view=azuresqldb-current)
