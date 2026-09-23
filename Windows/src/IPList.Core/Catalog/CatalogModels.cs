using IPList.Core.Networking;

namespace IPList.Core.Catalog;

public enum ExportMode { Targeted, Lite, Full }
public enum CatalogFreshness { Remote, Cached, Bundled }
public enum EnrichmentFreshness { Fresh, Cached, Stale, Bundled }

public sealed class CatalogService(
    string id, string name, string category, IReadOnlyList<string> domains,
    IReadOnlyList<long> asns, IReadOnlyList<IPv4Network> ipRanges)
{
    public const string DefaultSource = "pincetgore/amnezia-app-ru-list";
    public string Id { get; } = id;
    public string Name { get; } = name;
    public string Category { get; } = category;
    public IReadOnlyList<string> Domains { get; } = domains;
    public IReadOnlyList<long> Asns { get; } = asns;
    public IReadOnlyList<IPv4Network> IpRanges { get; } = ipRanges;
    public IReadOnlyList<IPv4Network> TargetedAddresses { get; set; } = [];
    public IReadOnlyList<IPv4Network> LiteAddresses { get; set; } = [];
    public IReadOnlyList<IPv4Network> FullAddresses { get; set; } = [];

    public static string StableId(string name, string source = DefaultSource)
    {
        var slug = new System.Text.StringBuilder();
        var lastSeparator = false;
        foreach (var c in name.Trim().ToLowerInvariant())
        {
            if (char.IsLetterOrDigit(c)) { slug.Append(c); lastSeparator = false; }
            else if (!lastSeparator && slug.Length > 0) { slug.Append('-'); lastSeparator = true; }
        }
        var normalized = slug.ToString().TrimEnd('-');
        return source.Trim().ToLowerInvariant() + ":" + (normalized.Length > 0 ? normalized : "unnamed");
    }
}

public sealed record ServiceCatalog(IReadOnlyList<CatalogService> Services,
    CatalogFreshness Freshness = CatalogFreshness.Remote, Uri? SourceUrl = null, DateTimeOffset? LoadedAt = null);

public sealed record TargetedRoute(string? Domain, IPv4Network Address)
{
    public string? CanonicalDomain => Domain?.Trim().TrimEnd('.').ToLowerInvariant();
}

public sealed record SourceSnapshot(ExportMode Mode, IReadOnlyList<IPv4Network> Routes,
    IReadOnlyList<TargetedRoute> TargetedRoutes);

public sealed record ServiceEnrichment(string ServiceId, IReadOnlyList<IPv4Network> DnsAddresses,
    IReadOnlyList<IPv4Network> AsnPrefixes, IReadOnlyList<string> DnsDomains,
    IReadOnlyList<long> AsnNumbers, DateTimeOffset? DnsUpdatedAt, DateTimeOffset? AsnUpdatedAt,
    EnrichmentFreshness Freshness);

public sealed record EnrichmentSnapshot(DateTimeOffset GeneratedAt, string Provenance,
    IReadOnlyDictionary<string, ServiceEnrichment> Services)
{
    public ServiceEnrichment? For(string serviceId) => Services.GetValueOrDefault(serviceId);
}

public sealed record MatchDiagnostics(string Source, string Status, string Message);

public sealed record MatchedCatalog(ServiceCatalog Catalog,
    IReadOnlyDictionary<ExportMode, IReadOnlyDictionary<string, IReadOnlyList<IPv4Network>>> RoutesByMode,
    IReadOnlyDictionary<ExportMode, IReadOnlyList<IPv4Network>> UnassignedRoutes,
    IReadOnlyList<MatchDiagnostics> Diagnostics,
    EnrichmentFreshness Freshness)
{
    public IReadOnlyList<IPv4Network> Routes(string serviceId, ExportMode mode) =>
        RoutesByMode.TryGetValue(mode, out var services) && services.TryGetValue(serviceId, out var routes) ? routes : [];
}
