namespace OboSqlServer.Bff;

public sealed class BffOptions
{
    public required string PublicOrigin { get; init; }
    public required string ApiBaseUrl { get; init; }
    public required string ApiScope { get; init; }
    public required string BlobContainerUrl { get; init; }

    public static bool IsHttpsOrigin(string value) =>
        Uri.TryCreate(value, UriKind.Absolute, out var uri) &&
        uri.Scheme == Uri.UriSchemeHttps && uri.AbsolutePath == "/" &&
        string.IsNullOrEmpty(uri.UserInfo + uri.Query + uri.Fragment);
}
