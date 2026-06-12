using OboSqlServer.Api.Data;
using OboSqlServer.Api.Security;

namespace OboSqlServer.Api.Services;

public sealed class DocumentService(
    DocumentRepository repository,
    CurrentUserAccessor currentUserAccessor,
    IConfiguration configuration,
    IHttpContextAccessor httpContextAccessor)
{
    private readonly int _maxDocumentBytes = configuration.GetValue<int>("Sql:MaxDocumentBytes", 10 * 1024 * 1024);

    public async Task<CreateDocumentResponse> CreateAsync(CreateDocumentRequest request, CancellationToken cancellationToken)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(request.FileName);
        ArgumentException.ThrowIfNullOrWhiteSpace(request.ContentType);
        ArgumentException.ThrowIfNullOrWhiteSpace(request.PayloadBase64);

        var payload = Convert.FromBase64String(request.PayloadBase64);
        if (payload.Length > _maxDocumentBytes)
        {
            throw new InvalidOperationException($"Document exceeds the configured limit of {_maxDocumentBytes} bytes.");
        }

        var sender = currentUserAccessor.GetRequiredUser();
        var documentId = Guid.NewGuid();
        var correlationId = GetCorrelationId();

        await repository.InsertAsync(documentId, sender, request, payload, correlationId, cancellationToken);

        return new CreateDocumentResponse(documentId);
    }

    public async Task<DocumentReadResult> GetAsync(Guid documentId, CancellationToken cancellationToken)
    {
        var user = currentUserAccessor.GetRequiredUser();
        var correlationId = GetCorrelationId();

        var metadata = await repository.GetMetadataAsync(documentId, cancellationToken);
        if (metadata is null)
        {
            await repository.AuditAsync(documentId, "document_read", user, "not_found", correlationId, cancellationToken);
            return new DocumentReadResult(DocumentReadStatus.NotFound, null);
        }

        if (metadata.ReceiverTenantId != user.TenantId || metadata.ReceiverObjectId != user.ObjectId)
        {
            await repository.AuditAsync(documentId, "document_read", user, "denied", correlationId, cancellationToken);
            return new DocumentReadResult(DocumentReadStatus.Forbidden, null);
        }

        var payload = await repository.GetPayloadAsync(documentId, cancellationToken);
        if (payload is null)
        {
            await repository.AuditAsync(documentId, "document_read", user, "not_found", correlationId, cancellationToken);
            return new DocumentReadResult(DocumentReadStatus.NotFound, null);
        }

        await repository.MarkReadAsync(documentId, user, correlationId, cancellationToken);

        var response = new ReadDocumentResponse(
            metadata.DocumentId,
            metadata.FileName,
            metadata.ContentType,
            Convert.ToBase64String(payload),
            metadata.CreatedAt);

        return new DocumentReadResult(DocumentReadStatus.Found, response);
    }

    private Guid GetCorrelationId()
    {
        var value = httpContextAccessor.HttpContext?.Items[CorrelationIdMiddleware.HeaderName];
        return value is Guid correlationId ? correlationId : Guid.NewGuid();
    }
}

