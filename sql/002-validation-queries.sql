/*
    Diagnostic queries, not an automated proof of the full BFF/OBO flow.
    In AKS, execute through an authorized client inside the private network.

    For the raw ciphertext query below, disable Always Encrypted on the client.
    With AE enabled, an admin without Key Vault permission should fail to unwrap,
    not return plaintext. See src/operations and docs/separation-of-duties.md
    for the exact-fixture positive and negative controls.

    Audit output contains identity metadata: redact it before sharing.
*/

SELECT TOP (10)
    DocumentId,
    SenderTenantId,
    SenderObjectId,
    ReceiverTenantId,
    ReceiverObjectId,
    FileName,
    ContentType,
    EncryptedPayload,
    CreatedAt,
    ReadAt
FROM dbo.Documents
ORDER BY CreatedAt DESC;
GO

SELECT TOP (50)
    AuditId,
    DocumentId,
    Action,
    TenantId,
    ObjectId,
    Result,
    CorrelationId,
    CreatedAt
FROM dbo.DocumentAccessAudit
ORDER BY CreatedAt DESC;
GO
