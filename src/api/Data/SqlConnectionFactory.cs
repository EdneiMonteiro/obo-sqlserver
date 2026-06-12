using Microsoft.Data.SqlClient;
using Microsoft.Data.SqlClient.AlwaysEncrypted.AzureKeyVaultProvider;
using Microsoft.Extensions.Options;
using Microsoft.Identity.Web;
using OboSqlServer.Api.Security;

namespace OboSqlServer.Api.Data;

public sealed class SqlConnectionFactory(
    IOptions<SqlOptions> sqlOptions,
    ITokenAcquisition tokenAcquisition,
    IHttpContextAccessor httpContextAccessor)
{
    private readonly SqlOptions _options = sqlOptions.Value;

    public async Task<SqlConnection> OpenAsync(CancellationToken cancellationToken)
    {
        var connection = new SqlConnection(_options.ConnectionString);
        var keyVaultProvider = new SqlColumnEncryptionAzureKeyVaultProvider(
            new DelegatedTokenCredential(tokenAcquisition, httpContextAccessor));

        connection.RegisterColumnEncryptionKeyStoreProvidersOnConnection(
            new Dictionary<string, SqlColumnEncryptionKeyStoreProvider>
            {
                [SqlColumnEncryptionAzureKeyVaultProvider.ProviderName] = keyVaultProvider
            });

        var databaseToken = await tokenAcquisition.GetAccessTokenForUserAsync(
            new[] { _options.DatabaseScope },
            user: httpContextAccessor.HttpContext?.User);

        connection.AccessToken = databaseToken;
        await connection.OpenAsync(cancellationToken);

        return connection;
    }
}

