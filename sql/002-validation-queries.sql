/*
    Run with a SQL admin connection that does not have Key Vault key permissions.
    Expected result: EncryptedPayload is not readable as plaintext.
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

