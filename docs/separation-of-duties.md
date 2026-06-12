# Segregacao de tarefas (Separation of Duties)

Documento que prova, com testes reproduziveis, que **Always Encrypted + Azure Key Vault e a fronteira real que protege o plaintext do administrador SQL**, e que grants SQL diferentes (INSERT vs SELECT) sao enforcaveis em paralelo, mesmo com criptografia ativa.

## Contexto

A PoC original (validacao em [docs/validacao.md](validacao.md)) rodava como um unico usuario (`ednei@live.com`) que acumulava 3 papeis:

- SQL Entra admin
- Receptor com Key Vault Crypto User
- Operador da subscription

Isso e suficiente para demonstrar OBO + criptografia, mas nao prova que o admin SQL nao consegue ler plaintext, ja que o mesmo usuario tinha acesso ao Key Vault.

Este teste resolve isso usando **duas identidades distintas** (service principals) com permissoes minimas, depois compara com o admin SQL com e sem acesso ao Key Vault.

## Setup

### Identidades

Dois service principals:

- `sp-poc-sender` — INSERT only
- `sp-poc-reader` — SELECT only

Ambos tem **Key Vault Crypto User** no `kv-obosql-poc-*` (necessario para o driver Always Encrypted fazer unwrap/wrap da CEK).

### Grants SQL

Contained users no banco:

```sql
CREATE USER [sp-poc-sender] FROM EXTERNAL PROVIDER;
CREATE USER [sp-poc-reader] FROM EXTERNAL PROVIDER;

GRANT INSERT ON dbo.Documents           TO [sp-poc-sender];
GRANT INSERT ON dbo.DocumentAccessAudit TO [sp-poc-sender];

GRANT SELECT ON dbo.Documents           TO [sp-poc-reader];
GRANT INSERT ON dbo.DocumentAccessAudit TO [sp-poc-reader];

-- Necessario para Always Encrypted client-side
GRANT VIEW ANY COLUMN MASTER KEY DEFINITION     TO [sp-poc-sender];
GRANT VIEW ANY COLUMN ENCRYPTION KEY DEFINITION TO [sp-poc-sender];
GRANT VIEW ANY COLUMN MASTER KEY DEFINITION     TO [sp-poc-reader];
GRANT VIEW ANY COLUMN ENCRYPTION KEY DEFINITION TO [sp-poc-reader];
```

> Sem `VIEW ANY COLUMN MASTER KEY DEFINITION` o driver falha com `view any column encryption key definition permission denied` mesmo em INSERT, porque ele precisa ler a metadata para encriptar parametros.

## Execucao

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

## Testes

### Fase 1: separacao funciona

| # | Identidade | Ação | Esperado | Resultado real |
|---|---|---|---|---|
| **S1** | sp-poc-sender | `INSERT INTO Documents` com AE+KV | PASS, payload encriptado client-side | **PASS** |
| **S2** | sp-poc-sender | `SELECT ... FROM Documents` | FAIL `SELECT permission denied` | **PASS** |
| **R1** | sp-poc-reader | `SELECT ... FROM Documents` com AE+KV | PASS, plaintext decriptado via AKV unwrap | **PASS** |
| **R2** | sp-poc-reader | `INSERT INTO Documents` | FAIL `INSERT permission denied` | **PASS** |

### Fase 2: admin SQL com KV Crypto User

| # | Identidade | Ação | Esperado | Resultado real |
|---|---|---|---|---|
| **E1** | `ednei@live.com` (SQL admin + KV Crypto User) | `SELECT ... FROM Documents` com AE+KV | PASS, le plaintext | **PASS** — admin leu o conteudo |

Este teste prova que **enquanto o admin SQL tiver acesso ao Key Vault, ele le tudo**. Acumular papeis quebra a separacao.

### Fase 3: admin SQL sem KV Crypto User

Removi `Key Vault Crypto User` do ednei e repeti E1:

```powershell
az role assignment delete --assignee <admin-object-id> --role 'Key Vault Crypto User' `
  --scope /subscriptions/<sub>/.../vaults/kv-obosql-poc-*
```

Resultado:

```
RESULT (admin BLOCKED):
Caller is not authorized to perform action on resource.
Caller: appid=04b07795-8ddb-461a-bbee-02f9e1bf7b46;oid=<admin-object-id>
Action: 'Microsoft.KeyVault/vaults/keys/unwrap/action'
Resource: '.../keys/cmk-documents'
Status: 403 (Forbidden)
ErrorCode: ForbiddenByRbac
```

O admin SQL continua sendo sysadmin do banco e pode rodar `SELECT` ilimitado, mas o driver Always Encrypted **nao consegue desembrulhar a CEK**, entao a coluna `EncryptedPayload` chega como bytes inuteis. Sem KV unwrap, sem plaintext.

## Conclusao

Esta PoC valida tres afirmacoes:

1. **Separacao de duties via grants funciona com AE.** INSERT/SELECT distintos sao enforcados normalmente; o driver de criptografia coexiste sem conflitos.
2. **AKV RBAC e o controle de acesso real para plaintext.** Sem `Microsoft.KeyVault/vaults/keys/unwrap/action`, nem o sysadmin do SQL le os dados.
3. **Acumular papeis (SQL admin + KV Crypto User) quebra a separacao.** Para producao, segregue:
   - SQL admins **sem** Key Vault Crypto User
   - Quem precisa ler dados (receivers, ETL) com KV Crypto User mas **sem** SQL admin
   - Quem opera a app (deploy, observabilidade) sem nem um nem outro

## Modelo de papeis recomendado

| Persona | SQL grants | KV Crypto User | Vê plaintext |
|---|---|---|---|
| Sender (cliente A) | `INSERT` em `Documents` | Sim | Sim, na escrita (sua propria) |
| Receiver (cliente B) | `SELECT` em `Documents` | Sim | Sim, na leitura (sua propria) |
| SQL Admin | `sysadmin` / `db_owner` | **Nao** | Nao — vê ciphertext |
| Operador app (CI/CD, SRE) | nenhum | **Nao** | Nao |
| Auditor | `SELECT` em `DocumentAccessAudit` | Nao | Nao — auditoria nao tem payload |

## Limites desta prova

- A app em Container Apps continua sendo trusted compute. Quem compromete o pod com o usuario logado dentro pode ver plaintext em memoria. Para fechar isso, criptografia tem que rolar no cliente final (E2EE estrito).
- Owners da subscription podem reverter o RBAC do Key Vault. Governance/Defender for Cloud devem alertar em mudancas.
- Sysadmins de Microsoft Entra podem criar service principals novos. Conditional Access + Privileged Identity Management mitigam.

## Scripts relacionados

| Script | Funcao |
|---|---|
| `scripts/setup-separation-of-duties.ps1` | Cria SPs, secrets, KV roles e contained users no SQL com grants |
| `scripts/test-separation-of-duties.ps1` | Roda S1, S2, R1, R2, E1 e imprime tabela de resultados |
