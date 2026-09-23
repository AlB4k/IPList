using System.Net;
using IPList.Core.Catalog;
using IPList.Core.Networking;

namespace IPList.Core.Refresh;

public interface IDomainResolver
{
    Task<IReadOnlyList<IPAddress>> ResolveIPv4Async(string domain, CancellationToken cancellationToken);
}

public interface IAsnPrefixLoader
{
    Task<IReadOnlyList<IPv4Network>> LoadAsync(int asn, CancellationToken cancellationToken);
}

public interface IServiceCatalogLoader
{
    Task<ServiceCatalog> LoadAsync(Uri uri, CancellationToken cancellationToken);
}

public interface IAddressListLoader
{
    Task<SourceSnapshot> LoadAsync(Uri uri, ExportMode mode, CancellationToken cancellationToken);
}

public sealed class SystemDomainResolver : IDomainResolver
{
    public async Task<IReadOnlyList<IPAddress>> ResolveIPv4Async(string domain, CancellationToken cancellationToken) =>
        (await Dns.GetHostAddressesAsync(domain, cancellationToken).ConfigureAwait(false))
        .Where(x => x.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork).Distinct().ToArray();
}

public sealed class AsnPrefixAdapter(RipeStatHttpLoader loader) : IAsnPrefixLoader
{
    public Task<IReadOnlyList<IPv4Network>> LoadAsync(int asn, CancellationToken cancellationToken) => loader.LoadPrefixesAsync(asn, cancellationToken);
}

public sealed record RefreshSourceUrls(Uri Metadata, Uri Targeted, Uri Lite, Uri Full)
{
    public static RefreshSourceUrls Default { get; } = new(
        new Uri("https://raw.githubusercontent.com/pincetgore/amnezia-app-ru-list/main/config.yaml"),
        new Uri("https://raw.githubusercontent.com/lib4u/amnezia-tunneling-ru/main/amnezia.json"),
        new Uri("https://raw.githubusercontent.com/lib4u/amnezia-tunneling-ru/main/amnezia-ip-lite.json"),
        new Uri("https://raw.githubusercontent.com/lib4u/amnezia-tunneling-ru/main/amnezia-ip.json"));
}

public sealed record RefreshRequest(RefreshSourceUrls Urls, ServiceCatalog? PreviousCatalog = null,
    EnrichmentSnapshot? CachedEvidence = null, DateTimeOffset? Now = null);

public sealed record RefreshTransaction(MatchedCatalog MatchedCatalog, EnrichmentSnapshot Enrichment,
    IReadOnlyList<MatchDiagnostics> Diagnostics,
    IReadOnlyDictionary<ExportMode, SourceSnapshot> SourceSnapshots, DateTimeOffset CompletedAt);
