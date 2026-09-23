using IPList.Core.Networking;

namespace IPList.Core.Catalog;

public sealed class CatalogMatcher(int maximumFragments = IPv4Network.MaximumFragments,
    IReadOnlyList<IPv4Network>? forbiddenSourceRoutes = null)
{
    private readonly IReadOnlyList<IPv4Network> _forbidden = forbiddenSourceRoutes ?? [];

    public MatchedCatalog Match(ServiceCatalog catalog,
        IReadOnlyDictionary<ExportMode, SourceSnapshot> sources, EnrichmentSnapshot? cachedEvidence)
    {
        if (catalog.Services.Count == 0) throw new InvalidOperationException("Empty catalog.");
        var services = catalog.Services.Select(Clone).ToList();
        var targeted = Require(sources, ExportMode.Targeted);
        var targetedSources = Validate(targeted.Routes);
        foreach (var route in targeted.TargetedRoutes)
        {
            if (!targetedSources.Any(x => x.Contains(route.Address))) throw new InvalidOperationException("Targeted route is outside its source.");
            var domain = route.CanonicalDomain;
            if (domain is null || services.Any(x => x.Domains.Contains(domain, StringComparer.OrdinalIgnoreCase))) continue;
            var id = CatalogService.StableId(domain, "lib4u");
            if (services.All(x => x.Id != id))
                services.Add(new CatalogService(id, domain, "Дополнительные ресурсы lib4u", [domain], [], []));
        }
        if (services.Select(x => x.Id).Distinct().Count() != services.Count) throw new InvalidOperationException("Duplicate service ID.");
        var routesByMode = new Dictionary<ExportMode, IReadOnlyDictionary<string, IReadOnlyList<IPv4Network>>>();
        var remainderByMode = new Dictionary<ExportMode, IReadOnlyList<IPv4Network>>();
        var representationCount = 0;

        foreach (var mode in Enum.GetValues<ExportMode>())
        {
            var source = Require(sources, mode);
            var sourceRoutes = Validate(source.Routes);
            var owned = new Dictionary<string, IReadOnlyList<IPv4Network>>(StringComparer.Ordinal);
            foreach (var service in services)
            {
                var evidence = new List<IPv4Network>(service.IpRanges);
                var cache = cachedEvidence?.For(service.Id);
                var domains = service.Domains.Select(x => x.ToLowerInvariant().TrimEnd('.')).Order().ToArray();
                var asns = service.Asns.Order().ToArray();
                if (cache is not null)
                {
                    if ((cache.DnsDomains.Count > 0 || domains.Length == 0) &&
                        cache.DnsDomains.All(domain => domains.Contains(domain))) evidence.AddRange(cache.DnsAddresses);
                    if (mode != ExportMode.Targeted && (cache.AsnNumbers.Count > 0 || asns.Length == 0) &&
                        cache.AsnNumbers.All(asn => asns.Contains(asn))) evidence.AddRange(cache.AsnPrefixes);
                }
                evidence.AddRange(targeted.TargetedRoutes.Where(x => x.CanonicalDomain is { } d && domains.Contains(d)).Select(x => x.Address));
                var proofs = Validate(evidence);
                IReadOnlyList<IPv4Network> result;
                if (mode == ExportMode.Targeted) result = proofs;
                else
                {
                    var intersections = new List<IPv4Network>();
                    foreach (var proof in proofs) intersections.AddRange(Intersections(sourceRoutes, proof));
                    result = RouteSet.Normalize(intersections, maximumFragments);
                }
                representationCount = checked(representationCount + result.Count);
                if (representationCount > maximumFragments) throw new InvalidOperationException("CIDR fragment limit exceeded.");
                owned[service.Id] = result;
                switch (mode)
                {
                    case ExportMode.Targeted: service.TargetedAddresses = result; break;
                    case ExportMode.Lite: service.LiteAddresses = result; break;
                    case ExportMode.Full: service.FullAddresses = result; break;
                }
            }
            var allOwned = RouteSet.Normalize(owned.Values.SelectMany(x => x), maximumFragments);
            var insideSource = mode == ExportMode.Targeted
                ? RouteSet.Normalize(allOwned.SelectMany(proof => Intersections(sourceRoutes, proof)), maximumFragments)
                : allOwned;
            var remaining = RouteSet.Subtract(sourceRoutes, insideSource, maximumFragments);
            representationCount = checked(representationCount + remaining.Count);
            if (representationCount > maximumFragments) throw new InvalidOperationException("CIDR fragment limit exceeded.");
            if (!RouteSet.UnionEquals(sourceRoutes, insideSource.Concat(remaining), maximumFragments))
                throw new InvalidOperationException("Source union changed during matching.");
            if (mode != ExportMode.Targeted && !RouteSet.UnionEquals(sourceRoutes, allOwned.Concat(remaining), maximumFragments))
                throw new InvalidOperationException("Source union changed during matching.");
            if (mode == ExportMode.Targeted) Validate(allOwned.Concat(remaining));
            routesByMode[mode] = owned;
            remainderByMode[mode] = remaining;
        }

        var freshness = cachedEvidence is null ? EnrichmentFreshness.Fresh
            : cachedEvidence.Services.Values.Any(x => x.Freshness == EnrichmentFreshness.Stale) ? EnrichmentFreshness.Stale
            : cachedEvidence.Services.Values.Any(x => x.Freshness == EnrichmentFreshness.Bundled) ? EnrichmentFreshness.Bundled
            : EnrichmentFreshness.Cached;
        return new MatchedCatalog(catalog with { Services = services }, routesByMode, remainderByMode, [], freshness);
    }

    private IReadOnlyList<IPv4Network> Validate(IEnumerable<IPv4Network> input)
    {
        var routes = RouteSet.Normalize(input, maximumFragments);
        if (routes.Any(x => x.Prefix == 0)) throw new InvalidOperationException("Default route rejected.");
        if (routes.Any(x => _forbidden.Any(y => x.Intersects(y)))) throw new InvalidOperationException("Forbidden source route.");
        return routes;
    }

    private static CatalogService Clone(CatalogService service) => new(service.Id, service.Name, service.Category,
        service.Domains.ToArray(), service.Asns.ToArray(), service.IpRanges.ToArray());

    private static IEnumerable<IPv4Network> Intersections(IReadOnlyList<IPv4Network> source, IPv4Network proof)
    {
        var low = 0;
        var high = source.Count;
        while (low < high)
        {
            var middle = low + (high - low) / 2;
            if (source[middle].LastAddress < proof.Network) low = middle + 1;
            else high = middle;
        }
        for (var index = low; index < source.Count && source[index].Network <= proof.LastAddress; index++)
            if (source[index].Intersect(proof) is { } overlap) yield return overlap;
    }

    private static SourceSnapshot Require(IReadOnlyDictionary<ExportMode, SourceSnapshot> sources, ExportMode mode) =>
        sources.TryGetValue(mode, out var source) && source.Mode == mode
            ? source : throw new InvalidOperationException($"Missing {mode} source.");
}
