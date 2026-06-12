# Fluxo Logico

## Escrita

1. Sender autentica no Microsoft Entra ID.
2. Sender chama `POST /documents` com bearer token.
3. API valida token e extrai `tid` e `oid`.
4. API obtem token OBO para Azure SQL.
5. Driver SQL com Always Encrypted usa acesso delegado ao Key Vault para proteger a operacao criptografica.
6. API grava metadata, ACL e payload criptografado no SQL.
7. API grava evento `document_create` na tabela de auditoria.

## Leitura

1. Receiver autentica no Microsoft Entra ID.
2. Receiver chama `GET /documents/{documentId}`.
3. API valida token e extrai `tid` e `oid`.
4. API consulta metadata do documento sem retornar payload.
5. API compara `ReceiverTenantId` e `ReceiverObjectId` com o token.
6. Se autorizado, API le payload com Always Encrypted habilitado.
7. API retorna payload em Base64 ao receiver.
8. API grava evento `document_read`.

## Negado

Se o usuario nao corresponder ao receptor autorizado:

- A API retorna 403.
- O payload nao e consultado/descriptografado.
- A tentativa e registrada como `denied`.

