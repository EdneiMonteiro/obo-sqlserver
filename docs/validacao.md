## Validacao

### Criterios e resultado

| # | Criterio | Esperado | Resultado |
|---|----------|----------|-----------|
| T1 | Sender grava documento | 201 | PASS |
| T2 | Sender pode endereçar para qualquer receiver | 201 | PASS |
| T3 | Receiver autorizado le plaintext | 200 + payload decriptado | PASS |
| T4 | Non-receiver tenta ler | 403 | PASS |
| T5 | Chamada sem token | 401 | PASS |
| T6 | SQL Admin direto SELECT/SUBSTRING em coluna criptografada | erro "Encryption scheme mismatch" / ciphertext | PASS |
| T7 | Auditoria gravada por chamada | linhas em DocumentAccessAudit | PASS |

### Como rodar

```powershell
.\scripts\validate-poc.ps1 `
  -BaseUrl "https://<app-url>" `
  -ApiClientId "<api-client-id>" `
  -SqlServerFqdn "<sql-server>.database.windows.net" `
  -DatabaseName "sqldb-obo-sql-poc"
```

Pre-requisitos:
- Azure CLI logado com a identidade que ira atuar como sender/receiver.
- Identidade com Key Vault Crypto User no Key Vault da PoC (necessario para o driver Always Encrypted desencriptar a CEK).
- Identidade com permissao no Azure SQL como usuario Entra (ou ser o Entra admin do servidor).

### Evidencias esperadas

- Correlation ID em cada chamada (header `x-correlation-id`).
- Registros em `dbo.DocumentAccessAudit` (`document_create allowed`, `document_read allowed`, `document_read denied`).
- Consulta SQL direta mostrando ciphertext / dado inutilizavel ou erro de encryption scheme.
- Logs do Key Vault para operacoes de unwrap.

### Comandos uteis

```powershell
# Estado do CMK/CEK
Invoke-Sqlcmd -ConnectionString "..." -AccessToken $sqlToken -Query "SELECT * FROM sys.column_master_keys; SELECT * FROM sys.column_encryption_keys"

# Audit log
Invoke-Sqlcmd -ConnectionString "..." -AccessToken $sqlToken -Query "SELECT TOP 20 * FROM dbo.DocumentAccessAudit ORDER BY CreatedAt DESC"
```

## Validacao adicional: separacao de duties

A validacao acima usa um unico usuario (Entra admin + receiver + operador) para simplificar.

Para provar que **AE+AKV bloqueia o SQL admin** quando ele nao tem `Key Vault Crypto User`, e que grants distintos INSERT/SELECT funcionam com AE ativo, veja [docs/separation-of-duties.md](separation-of-duties.md).

Resumo dos testes adicionais:

| # | Identidade | Ação | Resultado |
|---|---|---|---|
| S1 | sp-poc-sender (INSERT only) | INSERT com AE+KV | PASS |
| S2 | sp-poc-sender | SELECT | `SELECT permission denied` |
| R1 | sp-poc-reader (SELECT only) | SELECT com AE+KV | PASS (plaintext) |
| R2 | sp-poc-reader | INSERT | `INSERT permission denied` |
| E1 (com KV)  | SQL admin **com** KV Crypto User | SELECT | le plaintext — separacao quebrada |
| E1 (sem KV)  | SQL admin **sem** KV Crypto User | SELECT | `Status 403 ForbiddenByRbac` no unwrap — nao le |

