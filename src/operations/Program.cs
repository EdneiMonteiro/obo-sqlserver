using System.Data;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using Azure;
using Azure.Core;
using Azure.Identity;
using Azure.Security.KeyVault.Keys;
using Azure.Storage.Blobs;
using Azure.Storage.Blobs.Models;
using Microsoft.Data.SqlClient;
using Microsoft.Data.SqlClient.AlwaysEncrypted.AzureKeyVaultProvider;
using OboSqlServer.Operations;

var credential = new WorkloadIdentityCredential();
var connectionString = new SqlConnectionStringBuilder
{
    DataSource = "tcp:" + Required("SQL_FQDN") + ",1433",
    InitialCatalog = Required("DATABASE"),
    Encrypt = SqlConnectionEncryptOption.Mandatory,
    TrustServerCertificate = false,
    ColumnEncryptionSetting = SqlConnectionColumnEncryptionSetting.Enabled
}.ConnectionString;
var mode = args.SingleOrDefault() ?? throw new ArgumentException("An operation mode is required.");
if (mode is not ("bootstrap" or "setup-validation" or "remove-validation" or "sender" or "reader" or "admin-with-key" or "admin-without-key"))
    throw new ArgumentException("Unknown operation mode.");
var applicationUsers = mode == "bootstrap" ? ApplicationUser.Parse(Required("APPLICATION_USERS")) : [];
var administratorId = mode == "bootstrap" ? Guid.Parse(Required("SQL_ADMIN_OBJECT_ID")) : Guid.Empty;

if (mode == "bootstrap")
{
    var container = new BlobContainerClient(new Uri(Required("BLOB_URL")), credential);
    foreach (var name in new[] { "index.html", "app.js", "styles.css" })
    {
        await using var file = File.OpenRead(Path.Combine("/spa", name));
        await container.GetBlobClient(name).UploadAsync(file, new BlobUploadOptions
        {
            HttpHeaders = new BlobHttpHeaders
            {
                ContentType = name.EndsWith(".html") ? "text/html" : name.EndsWith(".js") ? "text/javascript" : "text/css",
                CacheControl = "no-store"
            }
        });
    }
    var sqlToken = (await File.ReadAllTextAsync("/bootstrap/access-token")).Trim();
    await using var connection = new SqlConnection(connectionString) { AccessToken = sqlToken };
    await connection.OpenAsync();
    var exists = Convert.ToInt32(await Scalar(connection, "SELECT COUNT(*) FROM sys.column_encryption_keys WHERE name=N'CEK_Documents'")) > 0;
    if (!exists)
    {
        var configuredKeyUrl = Required("KEY_URL");
        if (!Uri.TryCreate(configuredKeyUrl, UriKind.Absolute, out var uri) || uri.Scheme != "https" || configuredKeyUrl.Contains('\''))
            throw new InvalidOperationException("Invalid Key Vault key URL.");
        var keyClient = new KeyClient(new Uri(uri.GetLeftPart(UriPartial.Authority)), credential);
        KeyVaultKey key;
        try { key = (await keyClient.GetKeyAsync("cmk-documents")).Value; }
        catch (RequestFailedException exception) when (exception.Status == 404)
        {
            key = (await keyClient.CreateRsaKeyAsync(new CreateRsaKeyOptions("cmk-documents")
            {
                KeySize = 3072,
                KeyOperations = { KeyOperation.WrapKey, KeyOperation.UnwrapKey, KeyOperation.Sign, KeyOperation.Verify }
            })).Value;
        }
        var keyUrl = key.Id.ToString();
        var provider = new SqlColumnEncryptionAzureKeyVaultProvider(credential);
        var plainKey = RandomNumberGenerator.GetBytes(32);
        byte[] encrypted;
        try { encrypted = provider.EncryptColumnEncryptionKey(keyUrl, "RSA_OAEP", plainKey); }
        finally { CryptographicOperations.ZeroMemory(plainKey); }
        var template = await File.ReadAllTextAsync("/sql/001-schema-always-encrypted-template.sql");
        template = template.Replace("$(KeyVaultKeyUrl)", keyUrl).Replace("$(CekEncryptedValue)", Convert.ToHexString(encrypted));
        await using var transaction = (SqlTransaction)await connection.BeginTransactionAsync();
        foreach (var batch in Regex.Split(template, @"^\s*GO\s*$", RegexOptions.Multiline | RegexOptions.IgnoreCase))
        {
            if (string.IsNullOrWhiteSpace(batch)) continue;
            await using var command = new SqlCommand(batch, connection, transaction);
            await command.ExecuteNonQueryAsync();
        }
        await transaction.CommitAsync();
    }
    if (Convert.ToInt32(await Scalar(connection,
        "SELECT COUNT(*) FROM sys.columns WHERE object_id=OBJECT_ID('dbo.Documents') AND name='EncryptedPayload' AND encryption_type=2")) != 1)
        throw new InvalidOperationException("Schema is missing randomized Always Encrypted.");
    var storedKeyPath = await Scalar(connection, "SELECT key_path FROM sys.column_master_keys WHERE name=N'CMK_Documents_Akv'") as string;
    if (storedKeyPath is null || !storedKeyPath.StartsWith(Required("KEY_URL").TrimEnd('/') + "/", StringComparison.Ordinal))
        throw new InvalidOperationException("Existing CMK does not reference the configured versioned Key Vault key.");
    foreach (var user in applicationUsers)
    {
        if (user.ObjectId == administratorId)
        {
            Console.WriteLine("WARNING: an application participant is also the SQL administrator; SQL duties are not segregated for that user.");
            continue;
        }
        var name = "document-user-" + user.ObjectId.ToString("N");
        var sid = user.ObjectId.ToByteArray();
        var existing = await Scalar(connection, $"SELECT sid FROM sys.database_principals WHERE name=N'{name}'") as byte[];
        if (existing is not null && !existing.SequenceEqual(sid))
            throw new InvalidOperationException("Existing application principal belongs to a different identity.");
        await Execute(connection, $"IF USER_ID(N'{name}') IS NULL CREATE USER [{name}] WITH SID=0x{Convert.ToHexString(sid)}, TYPE=E;");
        if (user.CanSend) await Execute(connection, $"GRANT INSERT ON dbo.Documents TO [{name}];");
        if (user.CanRead) await Execute(connection, $"GRANT SELECT ON dbo.Documents TO [{name}]; GRANT UPDATE (ReadAt) ON dbo.Documents TO [{name}];");
        await Execute(connection, $"GRANT INSERT ON dbo.DocumentAccessAudit TO [{name}]; GRANT VIEW ANY COLUMN MASTER KEY DEFINITION TO [{name}]; GRANT VIEW ANY COLUMN ENCRYPTION KEY DEFINITION TO [{name}];");
    }
    Console.WriteLine("PASS: SPA, Always Encrypted schema and explicitly configured application users ready. No validation principals created.");
    return;
}

if (mode is "setup-validation" or "remove-validation")
{
    var sqlToken = (await File.ReadAllTextAsync("/bootstrap/access-token")).Trim();
    await using var connection = new SqlConnection(connectionString) { AccessToken = sqlToken };
    await connection.OpenAsync();
    if (Convert.ToInt32(await Scalar(connection, "SELECT COUNT(*) FROM sys.tables WHERE object_id=OBJECT_ID('dbo.Documents')")) != 1)
        throw new InvalidOperationException("Run the functional bootstrap before configuring validation.");
    foreach (var actor in new[] { "sender", "reader", "admin-with-key", "admin-without-key" })
    {
        var prefix = "TEST_" + actor.Replace('-', '_').ToUpperInvariant();
        // SQL contained application users match the client ID, unlike Azure RBAC and document ACLs.
        var clientSid = Guid.Parse(Required(prefix + "_CLIENT_ID")).ToByteArray();
        var objectSid = Guid.Parse(Required(prefix + "_OID")).ToByteArray();
        var sid = Convert.ToHexString(clientSid);
        var name = "test-" + actor;
        var existingSid = await Scalar(connection, $"SELECT sid FROM sys.database_principals WHERE name=N'{name}'") as byte[];
        if (mode == "remove-validation")
        {
            if (existingSid is null) continue;
            if (!existingSid.SequenceEqual(clientSid) && !existingSid.SequenceEqual(objectSid))
                throw new InvalidOperationException($"Principal {name} belongs to a different identity; refusing to remove it.");
            await Execute(connection, $"DROP USER [{name}];");
            continue;
        }
        if (existingSid is not null && !existingSid.SequenceEqual(clientSid))
        {
            if (!existingSid.SequenceEqual(objectSid))
                throw new InvalidOperationException($"Principal {name} belongs to a different identity; refusing to replace it.");
            Console.WriteLine($"Migrating PoC principal {name} from object-ID SID to client-ID SID.");
            await Execute(connection, $"DROP USER [{name}];");
        }
        await Execute(connection, $"IF USER_ID(N'{name}') IS NULL CREATE USER [{name}] WITH SID=0x{sid}, TYPE=E;");
        if (actor.StartsWith("admin"))
            await Execute(connection, $"ALTER ROLE db_owner ADD MEMBER [{name}];");
        else
        {
            await Execute(connection, $"GRANT {(actor == "sender" ? "INSERT" : "SELECT")} ON dbo.Documents TO [{name}];");
            await Execute(connection, $"GRANT INSERT ON dbo.DocumentAccessAudit TO [{name}];");
            if (actor == "reader") await Execute(connection, $"GRANT UPDATE (ReadAt) ON dbo.Documents TO [{name}];");
            await Execute(connection, $"GRANT VIEW ANY COLUMN MASTER KEY DEFINITION TO [{name}]; GRANT VIEW ANY COLUMN ENCRYPTION KEY DEFINITION TO [{name}];");
        }
    }
    Console.WriteLine(mode == "remove-validation"
        ? "PASS: optional SQL validation principals removed."
        : "PASS: optional validation principals configured; two db_owner controls are test-only.");
    return;
}

if (mode is not ("sender" or "reader" or "admin-with-key" or "admin-without-key"))
    throw new ArgumentException("Unknown validation mode.");
var documentId = Guid.Parse(Required("TEST_DOCUMENT_ID"));
var fixture = Encoding.UTF8.GetBytes("obo-integration-fixture-" + documentId);
await using var testConnection = new SqlConnection(connectionString);
var sqlAccessToken = (await credential.GetTokenAsync(new TokenRequestContext(["https://database.windows.net/.default"]))).Token;
testConnection.AccessToken = sqlAccessToken;
testConnection.RegisterColumnEncryptionKeyStoreProvidersOnConnection(new Dictionary<string, SqlColumnEncryptionKeyStoreProvider>
{
    [SqlColumnEncryptionAzureKeyVaultProvider.ProviderName] = new SqlColumnEncryptionAzureKeyVaultProvider(credential)
});
await testConnection.OpenAsync();
if (mode == "sender")
{
    await Insert(testConnection, documentId, fixture);
    await MustDenySql(() => Scalar(testConnection, "SELECT TOP 1 FileName FROM dbo.Documents"));
    Console.WriteLine("PASS S1/S2: sender encrypts INSERT; SELECT denied with SQL error 229.");
}
else if (mode == "reader")
{
    await VerifyPlaintext(testConnection, documentId, fixture);
    await MustDenySql(async () => { await Insert(testConnection, Guid.NewGuid(), fixture); return null; });
    Console.WriteLine("PASS R1/R2: exact fixture decrypted; INSERT denied with SQL error 229.");
}
else
{
    if (Convert.ToInt32(await Scalar(testConnection, "SELECT IS_ROLEMEMBER('db_owner')")) != 1)
        throw new InvalidOperationException("Admin test principal is not db_owner.");
    if (mode == "admin-with-key")
    {
        await VerifyPlaintext(testConnection, documentId, fixture);
        Console.WriteLine("PASS E1 positive control: db_owner WITH Key Vault access reads exact plaintext.");
    }
    else
    {
        var rawCs = new SqlConnectionStringBuilder(connectionString) { ColumnEncryptionSetting = SqlConnectionColumnEncryptionSetting.Disabled };
        await using var raw = new SqlConnection(rawCs.ConnectionString) { AccessToken = sqlAccessToken };
        await raw.OpenAsync();
        var ciphertext = await Payload(raw, documentId);
        if (ciphertext.Length <= fixture.Length || ciphertext.SequenceEqual(fixture))
            throw new InvalidOperationException("Raw SQL query did not return ciphertext.");
        var blocked = false;
        try { await VerifyPlaintext(testConnection, documentId, fixture); }
        catch (Exception exception) when (IsKeyVaultForbidden(exception)) { blocked = true; }
        if (!blocked) throw new InvalidOperationException("Admin WITHOUT Key Vault access recovered plaintext.");
        Console.WriteLine("PASS E2: db_owner sees ciphertext; AE unwrap denied by Key Vault (403).");
    }
}

static string Required(string name) => Environment.GetEnvironmentVariable(name) is { Length: > 0 } value
    ? value : throw new InvalidOperationException($"Missing environment variable {name}.");

static async Task<object?> Scalar(SqlConnection connection, string sql)
{
    await using var command = new SqlCommand(sql, connection);
    return await command.ExecuteScalarAsync();
}
static async Task Execute(SqlConnection connection, string sql)
{
    await using var command = new SqlCommand(sql, connection);
    await command.ExecuteNonQueryAsync();
}
static async Task Insert(SqlConnection connection, Guid id, byte[] payload)
{
    await using var command = new SqlCommand("""
        INSERT dbo.Documents (DocumentId,SenderTenantId,SenderObjectId,ReceiverTenantId,ReceiverObjectId,FileName,ContentType,EncryptedPayload)
        VALUES (@id,@tenant,@sender,@tenant,@receiver,N'fixture.txt',N'text/plain',@payload)
        """, connection);
    command.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
    command.Parameters.Add("@tenant", SqlDbType.UniqueIdentifier).Value = Guid.Parse(Required("AZURE_TENANT_ID"));
    command.Parameters.Add("@sender", SqlDbType.UniqueIdentifier).Value = Guid.Parse(Required("TEST_SENDER_OID"));
    command.Parameters.Add("@receiver", SqlDbType.UniqueIdentifier).Value = Guid.Parse(Required("TEST_READER_OID"));
    command.Parameters.Add("@payload", SqlDbType.VarBinary, -1).Value = payload;
    await command.ExecuteNonQueryAsync();
}
static async Task<byte[]> Payload(SqlConnection connection, Guid id)
{
    await using var command = new SqlCommand("SELECT EncryptedPayload FROM dbo.Documents WHERE DocumentId=@id", connection);
    command.Parameters.Add("@id", SqlDbType.UniqueIdentifier).Value = id;
    return await command.ExecuteScalarAsync() as byte[] ?? throw new InvalidOperationException("Fixture was not found.");
}
static async Task VerifyPlaintext(SqlConnection connection, Guid id, byte[] fixture)
{
    if (!(await Payload(connection, id)).SequenceEqual(fixture))
        throw new InvalidOperationException("Decrypted payload differs from the exact test fixture.");
}
static async Task MustDenySql(Func<Task<object?>> action)
{
    try { await action(); }
    catch (SqlException exception) when (exception.Number == 229) { return; }
    throw new InvalidOperationException("Expected SQL permission denial 229.");
}
static bool IsKeyVaultForbidden(Exception exception) =>
    (exception is RequestFailedException { Status: 403 } denied &&
     denied.Message.Contains("ForbiddenByRbac", StringComparison.Ordinal)) ||
    (exception.InnerException is not null && IsKeyVaultForbidden(exception.InnerException));
