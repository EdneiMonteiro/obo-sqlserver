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

