namespace OboSqlServer.Api.Services;

public static class DocumentValidation
{
    public static byte[] Decode(CreateDocumentRequest request, int maxBytes)
    {
        if (request.ReceiverTenantId == Guid.Empty || request.ReceiverObjectId == Guid.Empty)
            throw new BadHttpRequestException("Receiver tenant and object IDs are required.");
        if (string.IsNullOrWhiteSpace(request.FileName) || request.FileName.Length > 256 ||
            string.IsNullOrWhiteSpace(request.ContentType) || request.ContentType.Length > 128)
            throw new BadHttpRequestException("File name or content type is invalid.");
        if (string.IsNullOrWhiteSpace(request.PayloadBase64))
            throw new BadHttpRequestException("Payload is required.");
        if (maxBytes <= 0)
            throw new InvalidOperationException("Sql:MaxDocumentBytes must be positive.");
        if (request.PayloadBase64.Length > 4L * ((maxBytes + 2L) / 3))
            throw new BadHttpRequestException("Document exceeds the configured limit.", StatusCodes.Status413PayloadTooLarge);

        byte[] payload;
        try { payload = Convert.FromBase64String(request.PayloadBase64); }
        catch (FormatException) { throw new BadHttpRequestException("Payload must be valid Base64."); }
        if (payload.Length == 0)
            throw new BadHttpRequestException("Payload is empty.");
        if (payload.Length > maxBytes)
            throw new BadHttpRequestException("Document exceeds the configured limit.", StatusCodes.Status413PayloadTooLarge);
        return payload;
    }
}
