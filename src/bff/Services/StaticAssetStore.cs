using Azure;
using Azure.Storage.Blobs;

namespace OboSqlServer.Bff.Services;

public sealed record StaticAsset(Stream Content, string ContentType);

public interface IStaticAssetStore
{
    Task<StaticAsset?> GetAsync(string name, CancellationToken cancellationToken);
}

public sealed class StaticAssetStore(BlobContainerClient container) : IStaticAssetStore
{
    public async Task<StaticAsset?> GetAsync(string name, CancellationToken cancellationToken)
    {
        try
        {
            var response = await container.GetBlobClient(name).DownloadStreamingAsync(cancellationToken: cancellationToken);
            var contentType = name switch
            {
                "index.html" => "text/html; charset=utf-8",
                "app.js" => "text/javascript; charset=utf-8",
                "styles.css" => "text/css; charset=utf-8",
                _ => throw new ArgumentOutOfRangeException(nameof(name))
            };
            return new StaticAsset(response.Value.Content, contentType);
        }
        catch (RequestFailedException exception) when (exception.Status == 404)
        {
            return null;
        }
    }
}
