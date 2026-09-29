# Checklist de publicação

## Privacidade

- [ ] Usar apenas placeholders para contas, tenants, subscriptions, IPs e hosts
  do ambiente. Relatos de teste identificam papéis, não pessoas.
- [ ] Não incluir tokens, cookies, authorization codes, client secrets, chaves,
  connection strings reais, kubeconfig, state ou dumps.
- [ ] Excluir `.local`, arquivos `*.local.*`, certificados e resultados de browser
  do Git e do contexto Docker; conferir `git status` e o diff antes de publicar.
- [ ] Remover dados de usuário e URLs de autenticação de logs, issues e imagens.
  Não publicar o resultado bruto de `az account`, `az ad` ou arquivos de estado.
- [ ] Manter fixtures sintéticos; não usar documentos pessoais ou de clientes
  como evidencia versionada.

## Documentação

- [ ] README/diagramas/deploy apontam para AKS + Istio + BFF + Blob privado.
- [ ] ACA aparece somente como alternativa legada em `docs/legacy/aca.md`,
  com comandos e evidencias distinguidos dos testes atuais.
- [ ] OBO e executado pela API; login pelo BFF; browser recebe cookie, não tokens.
- [ ] Diferenciar client ID (SID SQL de apps/MI) de object ID (RBAC/ACL).
- [ ] O bootstrap funcional não requer identidades de teste nem cria db_owner;
  documentar separadamente o setup/teardown opcional e seus privilégios.
- [ ] Informar participantes explicitamente; não usar SQL admin como usuário
  de aplicação por omissao.
- [ ] Documentar uma réplica/Recreate e perda de sessão no restart.
- [ ] Declarar near-E2EE, ausencia de RLS, riscos de administradores e limites
  de HA, logs, WAF, egress e custos.
- [ ] Descrever componentes, parâmetros, comportamento e erros sem slogans,
  perguntas retóricas, travessões ou avisos genéricos repetidos.

## Verificacoes

- [ ] Executar build/test .NET, testes PowerShell e UI Chromium locais.
- [ ] Compilar Bicep AKS e o template ACA legado.
- [ ] Compilar o template de validação opcional e testar o fluxo sem habilita-lo.
- [ ] Conferir links locais, diagramas e exemplos sem IDs reais.
- [ ] Separar resultado de UI simulada, E2E com login real e testes diretos SQL/KV.
- [ ] Distinguir E2E histórico, mudancas verificadas localmente e recursos que
  ainda precisam de nova validação no destino; não alegar renovação ACME, carga,
  pentest ou auditoria imutavel sem evidencias.
- [ ] Confirmar que secrets/Jobs de bootstrap foram removidos.
- [ ] Excluir infraestrutura temporaria de testes dos artefatos oficiais.

## Distribuicao

- [ ] Preservar LICENSE, DISCLAIMER, SUPPORT e metadados de autoria/citacao.
- [ ] Confirmar os IDs dos recursos **localmente** antes de qualquer cleanup.
- [ ] Remover separadamente App Registrations ao encerrar o ambiente; a exclusão
  do RG e assincrona e o vault tem retenção/purge protection.

Guarde o estado local até confirmar a exclusão dos recursos.
