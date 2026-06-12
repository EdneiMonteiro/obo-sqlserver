namespace OboSqlServer.Api;

public sealed class SqlOptions
{
    public required string ConnectionString { get; init; }

    public string DatabaseScope { get; init; } = "https://database.windows.net/user_impersonation";

    public int MaxDocumentBytes { get; init; } = 10 * 1024 * 1024;
}

