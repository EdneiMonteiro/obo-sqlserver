# Identidades e permissões

Permissões necessárias para implantação e acesso a documentos.
Substitua os campos entre `<...>` pelos IDs do ambiente.

## 1. Identidades da aplicação

| Ator | Como autentica | Permissões necessárias | Onde |
|---|---|---|---|
| Usuário remetente | Login Entra pelo BFF | INSERT Documents/Audit; metadata AE; Crypto User | Banco e Key Vault |
| Usuário destinatário | Login Entra pelo BFF | SELECT Documents, UPDATE(ReadAt), INSERT Audit; metadata AE; Crypto User | Banco e Key Vault |
| Aplicação BFF | OIDC Authorization Code + PKCE; credencial federada de workload | Scope delegado da API; Blob Data Reader | App Registration da API e container `spa` |
| Aplicação API | JWT do BFF; credencial federada para OBO | Scopes delegados SQL/Key Vault | Entra; os direitos de dados são os do usuário |
| Controle AKS | Managed identity | Network Contributor em VNet/IP; Managed Identity Operator no kubelet | Recursos criados pelo template |
| Kubelet | Managed identity | AcrPull | ACR |
| Certbot | ServiceAccount Kubernetes | GET/PATCH do Secret `obo-tls` | Namespace do ingress |

O BFF é um cliente Web confidencial. A API é um recurso protegido e cliente OBO.
A SPA não tem registro OAuth próprio. O BFF recebe Blob Data Reader, mas não
recebe grants SQL ou Crypto User para ler documentos em nome próprio.

### Federações e consentimento

| Aplicação | Subject Kubernetes | Permissões delegadas |
|---|---|---|
| BFF | `system:serviceaccount:obo:bff` | `api://<api-client-id>/user_impersonation` |
| API | `system:serviceaccount:obo:api` | SQL e Key Vault `user_impersonation` |

Ambas confiam no issuer OIDC do cluster e na audience
`api://AzureADTokenExchange`. A API usa access tokens v2, com audiencia igual
ao client ID, e valida o client ID do BFF em `azp`/`appid`.
Os grants SQL e o RBAC Key Vault do usuário são verificados além do consentimento.

## 2. Preparação e administração

| Ator | Função | Privilégio |
|---|---|---|
| Operador de infraestrutura | Criar RG, recursos e role assignments | Permissões Azure de provisionamento/RBAC no escopo autorizado |
| Administrador de aplicações Entra | Criar apps, federações e consentimento | Permissões de diretório especificas; independentes do RBAC Azure |
| SQL Entra admin | Preparar schema e usuários contidos | DDL e concessao de grants SQL |
| Identidade `operations` | Publicar assets e criar/proteger CMK/CEK | Blob Data Contributor no container; Crypto Officer no vault |

O usuário atual do Azure CLI é configurado como SQL Entra admin. Seu token SQL
é montado em Secret temporário no Job de bootstrap. Ele só recebe Crypto User
se também for incluído nas listas de participantes. Nesse caso, o bootstrap
registra aviso sobre o acúmulo de permissões.

O client ID da MI `operations` e federado a
`system:serviceaccount:obo-operations:operations`. Ela não e uma identidade de
atendimento HTTP. Restrinja quem pode criar Jobs ou assumir essa ServiceAccount.
Os grants de preparação permanecem após o deploy. A equipe de operação deve
definir quando revogá-los e como reaplicá-los nas próximas publicações.

## 3. Configurar usuários reais do lab

```powershell
.\scripts\deploy-aks.ps1 `
  -SubscriptionId "<subscription-id>" -TenantId "<tenant-id>" `
  -OperatorCidrs @("<approved-egress-ip>/32") `
  -SenderObjectIds @("<sender-user-object-id>") `
  -ReceiverObjectIds @("<receiver-user-object-id>")
```

Informe object IDs de **usuários** do tenant do recurso, não client IDs de apps.
O mesmo usuário pode aparecer nas duas listas: o bootstrap une as permissões.
O usuário contido e nomeado `document-user-<object-id-sem-hifens>`.
Os grants são aditivos. Retirar um ID da lista não revoga permissões existentes
no SQL ou Key Vault; a revogação deve ser executada pelo administrador.

Na primeira implantação, listas vazias não criam usuários. O script emite aviso.
Em reaplicações, parâmetros omitidos preservam as listas do estado local.

Esta referência usa tenant único. Para convidados B2B, use o object ID do
usuário **no tenant do recurso**. Multitenancy não esta implementado.

## 4. Identificadores

| Uso | Identificador |
|---|---|
| Tenant da autenticação | Tenant ID |
| Audience da API e federação da aplicação | Client/application ID |
| Role assignments Azure | Principal/object ID |
| ACL do documento | Tenant ID + object ID do usuário |
| SID SQL de usuário humano | Object ID em representacao binaria GUID |
| SID SQL de app/managed identity (testes opcionais) | Client ID em representacao binaria GUID |

Um SID incorreto pode ser aceito no CREATE USER e causar erro 18456 no login.

## 5. Validação opcional

`setup-validation.ps1` provisiona quatro MIs e seus usuários SQL, separados dos
usuários da aplicação. Dois controles recebem `db_owner`; isso só existe na
etapa opcional. O estado fica em `validation.local.json`, não no estado funcional.
O bootstrap normal não le esse arquivo nem requer variáveis `TEST_*`.

[Execução e remoção dos controles](separation-of-duties.md).

## Limite da autorização

O par destinatário `tid` + `oid` e validado **na API**. Os grants SELECT no banco
não são Row-Level Security: acesso SQL direto + chave permite ler outras linhas.
SQL admins devem permanecer sem acesso de chave quando esse isolamento for
requisito. Administradores do cluster ainda podem acessar tokens e plaintext
no runtime.
