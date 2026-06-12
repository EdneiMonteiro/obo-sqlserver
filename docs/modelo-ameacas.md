# Modelo de Ameacas

## Ameacas cobertas pela PoC

| Ameaca | Controle |
|--------|----------|
| SQL Admin consulta tabela diretamente sem AE habilitado | Always Encrypted + CMK no Key Vault — driver nao decripta, query bruta retorna ciphertext |
| SQL Admin habilita AE no client e tenta ler | RBAC no Key Vault — sem `Key Vault Crypto User` o unwrap da CEK falha com 403 ForbiddenByRbac (validado em docs/separation-of-duties.md) |
| Usuario nao autorizado chama API | ACL por `tid` + `oid` |
| Logs vazam conteudo | API nao registra token, payload ou plaintext |
| Identidade sem Key Vault tenta descriptografar | RBAC minimo no Key Vault (validado) |
| Sender tenta ler ou Reader tenta escrever | Grants SQL distintos (INSERT vs SELECT) enforcados (validado) |

## Ameacas nao cobertas

| Ameaca | Motivo |
|--------|--------|
| Operador com controle total do app/runtime | Backend e trusted compute nesta PoC |
| Owner da subscription altera RBAC | Requer governanca/segregacao fora da PoC |
| Malware no cliente final | Fora do escopo |
| E2EE estrito | Exigiria criptografia no cliente |

## Recomendacao

Use esta PoC para validar o requisito "SQL Admin nao le plaintext" — comprovado em [docs/separation-of-duties.md](separation-of-duties.md) com a fase E1 (com e sem KV access). Para validar "nem backend nem operador le plaintext", implemente criptografia no cliente final.

### Modelo de papeis recomendado para producao

| Persona | SQL grants | KV Crypto User |
|---|---|---|
| Sender | `INSERT` em `Documents` | Sim |
| Receiver | `SELECT` em `Documents` | Sim |
| SQL Admin | `sysadmin`/`db_owner` | **Nao** |
| Operador app | nenhum | **Nao** |
| Auditor | `SELECT` em `DocumentAccessAudit` | Nao |

