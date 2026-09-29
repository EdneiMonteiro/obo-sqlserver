# Modelo de ameaças

Controles e limitações da [arquitetura AKS/BFF](arquitetura.md).

## Controles

| Ameaca / superficie | Controle implementado | Evidencia / limite |
|---|---|---|
| SQL admin sem chave tenta recuperar payload | Always Encrypted + CMK externa e RBAC | Teste raw ciphertext + AE 403/ForbiddenByRbac passou |
| Identidade com SQL e chave | Segregacao administrativa necessária | Controle positivo confirmou que ela le plaintext |
| Usuário chama documento de outro destinatário | ACL por tid+oid na API, antes de consultar payload | E2E retornou negação |
| App diferente tenta usar API | JWT, scope delegado e AllowedClientId do BFF | Política configurada e testes locais; API sem ingress proprio |
| JavaScript rouba access/refresh token do browser | BFF mantem tokens server-side; cookie HttpOnly/Secure | Superficies do E2E não expuseram bearer; não elimina XSS |
| CSRF em escrita/logout | Header antiforgery e cookie de sessão | POST sem token rejeitado em teste |
| Redirecionamento ou destino arbitrario | PublicOrigin fixo, allowlist de rotas/assets, HttpClient sem redirects/cookies | Testes locais; não e um proxy generico |
| Pod lateral tenta atingir workloads | mTLS STRICT, AuthorizationPolicies e NetworkPolicy | Configurado; sem pentest exaustivo de bypass |
| Acesso direto ao Blob/SQL/Key Vault pela Internet | Public network disabled + Private Endpoints/DNS | Blob sondado interna/externamente; configuração de SQL/KV no IaC |
| Segredo de aplicação persistido | Federação OIDC do workload; sem client secret no AKS | Bootstrap tem token temporário com transporte protegido |
| Payload em logs/cache HTTP | Sem logging explícito de payload/tokens; no-store | Bibliotecas, dumps e agentes não foram auditados |

## Acessos que permanecem possíveis

- BFF/API processam plaintext e tokens. Administradores do cluster, container,
  máquina de administração ou pipeline podem alterar o codigo e capturar esses dados.
- Owners, User Access Administrators e administradores Entra podem alterar RBAC,
  consentimento e federação. PIM e auditoria administrativa não estão configurados.
- O operador só recebe Crypto User se explicitamente configurado como
  participante. Se acumular SQL admin e acesso de chave, poderá ler os documentos.
  O bootstrap avisa, mas não revoga privilégios anteriores.
- A ACL da API não e RLS. SQL SELECT + chave pode ler outras linhas diretamente.
- Revogar RBAC não elimina plaintext ou chaves ja obtidos e cacheados.
- XSS pode executar ações na sessão ativa, mesmo com tokens fora do browser.
- Não ha proteção contra malware/dispositivo final comprometido nem E2EE estrito.
- Não ha WAF/Application Gateway, monitoramento central provisionado, HA ou
  estado distribuido de sessão. Uma réplica/Recreate invalida sessões em restart.
- HTTPS de saida e permitido; não existe controle de exfiltracao por FQDN.
  O controle administrativo AKS não e privado, embora restrito por CIDRs/Entra.

## Permissões de dados

Sender precisa INSERT Documents/Audit e acesso a metadata AE; receiver precisa
SELECT, UPDATE(ReadAt), INSERT Audit e metadata AE. Ambos precisam autorização
criptografica nas operações autorizadas. SQL admin não deve acumular acesso a
chave em um ambiente com segregacao real.

Um db_owner pode alterar a auditoria SQL. Metadados e ACL permanecem em claro.
[Testes de segregação](separation-of-duties.md).
O deploy funcional não cria usuários de validação `db_owner`: eles pertencem a
uma etapa opcional com setup/teardown explicitos. Os grants de participantes são
aditivos; remover um ID da configuração não revoga acessos ja concedidos.

## Privacidade e publicação

Use fixtures sintéticos, placeholders e relatos por papel. Não publique contas
pessoais, tenant/subscription IDs reais, URLs de autenticação, tokens,
kubeconfigs, dumps, documentos ou screenshots contendo identificadores.
Estado real fica em `.local`, excluido do Git e do contexto Docker.

E2EE estrito exigiria criptografia no cliente final.
[Cobertura dos testes](validacao.md) e [checklist de publicação](publicacao.md).
