namespace OboSqlServer.Api.Services;

public sealed record CreateDocumentRequest(
    Guid ReceiverTenantId,
    Guid ReceiverObjectId,
    string FileName,
    string ContentType,
    string PayloadBase64);

public sealed record CreateDocumentResponse(Guid DocumentId);

public sealed record ReadDocumentResponse(
    Guid DocumentId,
    string FileName,
    string ContentType,
    string PayloadBase64,
    DateTimeOffset CreatedAt);

public sealed record DocumentReadResult(DocumentReadStatus Status, ReadDocumentResponse? Document);

public enum DocumentReadStatus
{
    Found,
    NotFound,
    Forbidden
}

