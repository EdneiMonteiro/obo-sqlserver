# Modelo de Ameacas

## Ameacas cobertas pela PoC

| Ameaca | Controle |
|--------|----------|
| SQL Admin consulta tabela diretamente | Always Encrypted + CMK no Key Vault |
| Usuario nao autorizado chama API | ACL por `tid` + `oid` |
| Logs vazam conteudo | API nao registra token, payload ou plaintext |
| Identidade sem Key Vault tenta descriptografar | RBAC minimo no Key Vault |

## Ameacas nao cobertas

| Ameaca | Motivo |
|--------|--------|
| Operador com controle total do app/runtime | Backend e trusted compute nesta PoC |
| Owner da subscription altera RBAC | Requer governanca/segregacao fora da PoC |
| Malware no cliente final | Fora do escopo |
| E2EE estrito | Exigiria criptografia no cliente |

## Recomendacao

Use esta PoC para validar o requisito "SQL Admin nao le plaintext". Para validar "nem backend nem operador le plaintext", implemente criptografia no cliente final.

