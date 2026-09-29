# Segregação de acesso: SQL e Key Vault

Os testes opcionais usam quatro identidades em Jobs no AKS para verificar
permissões SQL e acesso à chave. São conexões diretas aos recursos.
O [E2E OBO](validacao.md) é executado no navegador.

## Identidades de teste

Os testes usam identidades separadas para comparar acesso com e sem chave,
sem alterar os privilégios da conta do operador.

| Ator | Usuário SQL | SQL | Key Vault |
|---|---|---|---|
| Sender | `test-sender` | INSERT Documents/Audit + metadata AE | Crypto User |
| Reader | `test-reader` | SELECT Documents, UPDATE(ReadAt), INSERT Audit + metadata AE | Crypto User |
| Admin com chave | `test-admin-with-key` | db_owner | Crypto User |
| Admin sem chave | `test-admin-without-key` | db_owner | Nenhuma atribuicao de chave no template |

`validation.bicep` cria managed identities e federações; o modo `setup-validation`
de `src\operations` cria os usuários contidos. Nenhuma dessas etapas e chamada
por `deploy-aks.ps1` ou pelo modo funcional `bootstrap`.
Para apps/managed identities, o SID SQL e a representacao binaria do
**client ID**. O object ID e usado nos role assignments Azure e nas ACLs dos
documentos, não como SID desses usuários SQL.

O reader recebe UPDATE em `ReadAt` porque a API marca a data da leitura e grava
um evento de auditoria.

## Execução

Com o deploy pronto e acesso administrativo autorizado ao AKS:

```powershell
.\scripts\setup-validation.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json
.\scripts\test-aks.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json -IncludeSegregation
```

O setup executa what-if e exige permissões para criar identidades, RBAC e
grants SQL. `validation.local.json` só é marcado pronto depois de concluir o Job.
`-IncludeSegregation` exige esse estado. Sem o switch, o script faz smoke tests.

Cada rodada usa um ID e payload sintéticos. Os quatro Jobs são executados em
sequência, em processos separados. O payload não é impresso nos logs.

## Resultados dos testes

Os controles passaram no Azure em 23/09/2026 e em uma repetição sem republicação.
A separação posterior do setup/teardown foi testada localmente.

| Teste | Ação | Resultado exigido e observado |
|---|---|---|
| S1 | Sender grava fixture com AE | INSERT permitido |
| S2 | Sender consulta Documents | SQL 229, permissão SELECT negada |
| R1 | Reader le o ID exato criado por S1 | Bytes identicos ao fixture |
| R2 | Reader tenta inserir | SQL 229, permissão INSERT negada |
| E1 | db_owner com chave le o mesmo fixture | Bytes identicos: controle positivo |
| E2 | db_owner sem chave faz SELECT bruto e depois AE | Raw retorna ciphertext; unwrap falha com 403/ForbiddenByRbac |

E2 primeiro confirma `IS_ROLEMEMBER('db_owner')=1`. A conexão raw tem Always
Encrypted desabilitado; a conexão AE recebe provider Key Vault proprio.
Falhas de login, DNS, rede ou query fazem o teste falhar.

## Limitações

- A ACL por destinatário **não** e Row-Level Security. Reader com SELECT direto
  e chave pode ler outras linhas; o `tid`/`oid` e verificado pela API.
- Os privilégios da conta que provisionou o ambiente permanecem inalterados.
- Comprometimento de BFF/API, cluster ou máquina administrativa pode expor tokens/plaintext.
- Revogação de uma chave não apaga CEKs/plaintext previamente obtidos ou caches.
  Os Jobs separados evitam compartilhar um cache de CEK entre os controles.

## Remover a validação sem remover a aplicação

```powershell
.\scripts\remove-validation.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json -WhatIf
.\scripts\remove-validation.ps1 -SubscriptionId "<subscription-id>" `
  -StatePath .\.local\aks\deployment.local.json
```

O teardown confere IDs, SIDs, tags e escopos antes de remover os usuários SQL,
Jobs, ServiceAccounts, role assignments e MIs. Marca o estado como não pronto
antes da limpeza e pode ser repetido após falha parcial.
Os registros sintéticos permanecem no SQL. As identidades não expiram sozinhas.

## Artefatos e legado

Arquivos: `infra\bicep\validation.bicep`, `src\operations\Program.cs`,
`scripts\setup-validation.ps1`, `scripts\remove-validation.ps1`,
`scripts\aks-common.ps1`, `scripts\test-aks.ps1`.

Os scripts de [ACA](legacy/aca.md) usam dois service principals com secrets e
a identidade CLI para E1. Suas consultas TOP não selecionam o ID exato da rodada.
