using Microsoft.Data.SqlClient;
using OboSqlServer.Api.Security;
using OboSqlServer.Api.Services;
using System.Data;

namespace OboSqlServer.Api.Data;

public sealed class DocumentRepository(SqlConnectionFactory connectionFactory)
{
    public async Task InsertAsync(
        Guid documentId,
        CurrentUser sender,
        CreateDocumentRequest request,
        byte[] payload,
        Guid correlationId,
        CancellationToken cancellationToken)
    {
        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        await using (var command = connection.CreateCommand())
        {
            command.Transaction = (SqlTransaction)transaction;
            command.CommandText = """
                INSERT INTO dbo.Documents
                    (DocumentId, SenderTenantId, SenderObjectId, ReceiverTenantId, ReceiverObjectId, FileName, ContentType, EncryptedPayload, CreatedAt)
                VALUES
                    (@DocumentId, @SenderTenantId, @SenderObjectId, @ReceiverTenantId, @ReceiverObjectId, @FileName, @ContentType, @EncryptedPayload, SYSUTCDATETIME());
                """;

            AddGuid(command, "@DocumentId", documentId);
            AddGuid(command, "@SenderTenantId", sender.TenantId);
            AddGuid(command, "@SenderObjectId", sender.ObjectId);
            AddGuid(command, "@ReceiverTenantId", request.ReceiverTenantId);
            AddGuid(command, "@ReceiverObjectId", request.ReceiverObjectId);
            AddString(command, "@FileName", request.FileName, 256);
            AddString(command, "@ContentType", request.ContentType, 128);
            AddBytes(command, "@EncryptedPayload", payload);

            await command.ExecuteNonQueryAsync(cancellationToken);
        }

        await AuditAsync(connection, (SqlTransaction)transaction, documentId, "document_create", sender, "allowed", correlationId, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
    }

    public async Task<DocumentMetadata?> GetMetadataAsync(Guid documentId, CancellationToken cancellationToken)
    {
        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();

        command.CommandText = """
            SELECT DocumentId, SenderTenantId, SenderObjectId, ReceiverTenantId, ReceiverObjectId, FileName, ContentType, CreatedAt
            FROM dbo.Documents
            WHERE DocumentId = @DocumentId;
            """;
        AddGuid(command, "@DocumentId", documentId);

        await using var reader = await command.ExecuteReaderAsync(cancellationToken);
        if (!await reader.ReadAsync(cancellationToken))
        {
            return null;
        }

        return new DocumentMetadata(
            reader.GetGuid(0),
            reader.GetGuid(1),
            reader.GetGuid(2),
            reader.GetGuid(3),
            reader.GetGuid(4),
            reader.GetString(5),
            reader.GetString(6),
            new DateTimeOffset(DateTime.SpecifyKind(reader.GetDateTime(7), DateTimeKind.Utc)));
    }

    public async Task<byte[]?> GetPayloadAsync(Guid documentId, CancellationToken cancellationToken)
    {
        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var command = connection.CreateCommand();

        command.CommandText = """
            SELECT EncryptedPayload
            FROM dbo.Documents
            WHERE DocumentId = @DocumentId;
            """;
        AddGuid(command, "@DocumentId", documentId);

        var result = await command.ExecuteScalarAsync(cancellationToken);
        return result is byte[] payload ? payload : null;
    }

    public async Task MarkReadAsync(Guid documentId, CurrentUser user, Guid correlationId, CancellationToken cancellationToken)
    {
        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await using var transaction = await connection.BeginTransactionAsync(cancellationToken);

        await using (var command = connection.CreateCommand())
        {
            command.Transaction = (SqlTransaction)transaction;
            command.CommandText = """
                UPDATE dbo.Documents
                SET ReadAt = SYSUTCDATETIME()
                WHERE DocumentId = @DocumentId;
                """;
            AddGuid(command, "@DocumentId", documentId);
            await command.ExecuteNonQueryAsync(cancellationToken);
        }

        await AuditAsync(connection, (SqlTransaction)transaction, documentId, "document_read", user, "allowed", correlationId, cancellationToken);
        await transaction.CommitAsync(cancellationToken);
    }

    public async Task AuditAsync(Guid? documentId, string action, CurrentUser user, string result, Guid correlationId, CancellationToken cancellationToken)
    {
        await using var connection = await connectionFactory.OpenAsync(cancellationToken);
        await AuditAsync(connection, null, documentId, action, user, result, correlationId, cancellationToken);
    }

    private static async Task AuditAsync(
        SqlConnection connection,
        SqlTransaction? transaction,
        Guid? documentId,
        string action,
        CurrentUser user,
        string result,
        Guid correlationId,
        CancellationToken cancellationToken)
    {
        await using var command = connection.CreateCommand();
        command.Transaction = transaction;
        command.CommandText = """
            INSERT INTO dbo.DocumentAccessAudit
                (DocumentId, Action, TenantId, ObjectId, Result, CorrelationId, CreatedAt)
            VALUES
                (@DocumentId, @Action, @TenantId, @ObjectId, @Result, @CorrelationId, SYSUTCDATETIME());
            """;

        AddNullableGuid(command, "@DocumentId", documentId);
        AddString(command, "@Action", action, 64);
        AddGuid(command, "@TenantId", user.TenantId);
        AddGuid(command, "@ObjectId", user.ObjectId);
        AddString(command, "@Result", result, 32);
        AddGuid(command, "@CorrelationId", correlationId);

        await command.ExecuteNonQueryAsync(cancellationToken);
    }

    private static void AddGuid(SqlCommand command, string name, Guid value)
    {
        command.Parameters.Add(new SqlParameter(name, SqlDbType.UniqueIdentifier) { Value = value });
    }

    private static void AddNullableGuid(SqlCommand command, string name, Guid? value)
    {
        command.Parameters.Add(new SqlParameter(name, SqlDbType.UniqueIdentifier) { Value = value.HasValue ? value.Value : DBNull.Value });
    }

    private static void AddString(SqlCommand command, string name, string value, int size)
    {
        command.Parameters.Add(new SqlParameter(name, SqlDbType.NVarChar, size) { Value = value });
    }

    private static void AddBytes(SqlCommand command, string name, byte[] value)
    {
        command.Parameters.Add(new SqlParameter(name, SqlDbType.VarBinary, -1) { Value = value });
    }
}

