# Componentes Azure

Configuração atual dos templates [AKS](../infra/bicep/aks.bicep) e
[Private Endpoints](../infra/bicep/private-endpoint.bicep).

| Componente | Configuração da PoC | Finalidade / limite |
|---|---|---|
| AKS | Tier Free, um node `Standard_D4s_v5`, Azure Linux, Kubernetes `1.35.8` por padrão | BFF, API, operações e ACME; sem HA |
| Istio gerenciado | Revisão `asm-1-30`, CNIChaining em novas instalacoes, ingress externo | HTTPS, mTLS STRICT e AuthorizationPolicies |
| BFF | Uma réplica, Recreate, .NET 8, 256 MiB request / 768 MiB limit | Sessão, tokens server-side e proxy |
| API | Uma réplica, .NET 8, 256 MiB request / 768 MiB limit | Autorização de documentos e OBO |
| Azure SQL | Basic, 5 DTUs, maximo 2 GiB, Entra-only | Ciphertext, metadados e auditoria |
| Key Vault | Standard, RBAC, soft delete 7 dias, purge protection | CMK RSA-3072 criada pelo bootstrap privado |
| Storage | StorageV2, Standard LRS, container `spa`, sem anonymous/shared key | Assets da SPA, não documentos |
| Rede | VNet, Azure CNI overlay/Cilium, tres Private Endpoints e Private DNS | SQL, Blob e Key Vault sem acesso público |
| ACR | Basic, admin e anonymous pull desabilitados | Builds remotos; pull autenticado do kubelet |
| Public IP + Load Balancer | IP estático e hostname Azure | Entrada publica do Istio; não expoe a API diretamente |
| Certbot | CronJob diário `17 3 * * *`, PVC 1 GiB, Secret TLS | Let's Encrypt HTTP-01 e renovação |
| Entra | Duas App Registrations Web/API com federação OIDC do AKS | Sem client secrets no caminho principal |
| Identidades operacionais | Controle AKS, kubelet e operações | Papéis distintos, escopos definidos no Bicep |

Consulte a disponibilidade dessas versões/SKUs e a quota de vCPU na região antes
do deploy. O controle AKS usa endpoint público com faixas de IP autorizadas.

## Permissões e observabilidade

O BFF recebe Blob Data Reader **no container**. Operações recebe Blob Data
Contributor no container e Crypto Officer no vault. SQL/Key Vault no fluxo da
API usam permissões **do usuário**, não as managed identities do cluster.
O template opcional `validation.bicep` cria as
[identidades de teste](separation-of-duties.md). Os grants de usuários estão em
[identidades e permissões](identidades-e-permissoes.md).

A auditoria de documentos fica no SQL; logs de processos/pods são acessados pelo
canal administrativo. **Log Analytics, diagnósticos centralizados de Key Vault,
Application Insights, WAF e Application Gateway não são provisionados no AKS.**

## Custos e lifecycle

O cluster não tem scale-to-zero. Node, discos/PVCs, Load Balancer, IPs, Private
Endpoints, SQL e ACR geram custos sem usuários ativos. Builds e transferência
também são cobrados.

Excluir o RG remove os recursos Azure. App Registrations são removidas
separadamente; o Key Vault permanece retido pelo período de proteção.
As [limitações de produção](modelo-ameacas.md) incluem HA, recuperação,
monitoramento e controle de acesso administrativo.

## Alternativa legada

O [caminho ACA](legacy/aca.md) usa Consumption (0 a 1 réplica), SQL Basic,
Key Vault e Log Analytics (30 dias no template, cap 0,025 GiB/dia).
Seus endpoints, credenciais e custos são diferentes; não fazem parte do
deploy principal de AKS.
