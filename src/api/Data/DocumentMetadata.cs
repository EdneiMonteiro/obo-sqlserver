namespace OboSqlServer.Api.Data;

public sealed record DocumentMetadata(
    Guid DocumentId,
    Guid SenderTenantId,
    Guid SenderObjectId,
    Guid ReceiverTenantId,
    Guid ReceiverObjectId,
    string FileName,
    string ContentType,
    DateTimeOffset CreatedAt);

