using IPList.Core.Catalog;

namespace IPList.Core.Refresh;

public sealed class ServiceCatalogHttpLoader(HttpDataClient client) : IServiceCatalogLoader
{
    public async Task<ServiceCatalog> LoadAsync(Uri uri, CancellationToken cancellationToken)
    {
        var catalog = BundledCatalog.ApplyBundledOverrides(
            ServiceCatalogParser.Parse(await client.GetLimitedAsync(uri, cancellationToken).ConfigureAwait(false)));
        return catalog with { SourceUrl = uri, LoadedAt = DateTimeOffset.UtcNow };
    }

    public async Task<ServiceCatalog> LoadOrFallbackAsync(Uri uri, ServiceCatalog? previous, CancellationToken cancellationToken)
    {
        try
        {
            var catalog = await LoadAsync(uri, cancellationToken).ConfigureAwait(false);
            if (previous is not null && catalog.Services.Count < Math.Ceiling(previous.Services.Count * 0.5))
                throw new FormatException("Suspicious catalog shrink.");
            return catalog;
        }
        catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
        catch
        {
            return previous is not null ? previous with { Freshness = CatalogFreshness.Cached } : BundledCatalog.Load();
        }
    }
}
