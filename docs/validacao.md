# Validacao da PoC

## Criterios

1. Sender grava documento.
2. Receiver autorizado le documento.
3. Usuario nao autorizado recebe 403.
4. SQL Admin sem Key Vault nao le plaintext.
5. Identidade sem Key Vault nao consegue unwrap/decrypt.

## Evidencias esperadas

- Correlation ID em cada chamada.
- Registros em `dbo.DocumentAccessAudit`.
- Consulta SQL direta mostrando ciphertext/dado inutilizavel.
- Logs do Key Vault para operacoes de chave.

## Comandos

```powershell
.\scripts\validate-poc.ps1 -BaseUrl "https://<app-url>"
```

Para validacao SQL direta:

```sql
:r .\sql\002-validation-queries.sql
```

