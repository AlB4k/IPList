using IPList.Core.Catalog;
using IPList.Core.Networking;

namespace IPList.Core.Tests;

public sealed class CatalogMatcherTests
{
    [Fact]
    public void BroadSourceIsPartitionedByNarrowAndSharedEvidence()
    {
        var first = new CatalogService("a", "A", "X", ["a.example"], [], [IPv4Network.Parse("198.51.100.16/28")]);
        var second = new CatalogService("b", "B", "X", [], [], [IPv4Network.Parse("198.51.100.16/28")]);
        var source = IPv4Network.Parse("198.51.100.0/24");
        var matched = new CatalogMatcher().Match(new ServiceCatalog([first, second]), Sources(source), null);
        Assert.Equal(new[] { IPv4Network.Parse("198.51.100.16/28") }, matched.Routes("a", ExportMode.Lite));
        Assert.Equal(matched.Routes("a", ExportMode.Lite), matched.Routes("b", ExportMode.Lite));
        var ownedPlusRemainder = matched.Routes("a", ExportMode.Lite).Concat(matched.Routes("b", ExportMode.Lite)).Concat(matched.UnassignedRoutes[ExportMode.Lite]);
        Assert.True(RouteSet.UnionEquals([source], ownedPlusRemainder));
        Assert.DoesNotContain(matched.UnassignedRoutes[ExportMode.Lite], x => x.Intersects(IPv4Network.Parse("198.51.100.16/28")));
    }

    [Fact]
    public void TargetedDomainAndCachedEvidenceAddConfirmedRoutes()
    {
        var service = new CatalogService("a", "A", "X", ["a.example"], [], []);
        var source = new SourceSnapshot(ExportMode.Targeted, [IPv4Network.Parse("203.0.113.2/32")],
            [new TargetedRoute("a.example", IPv4Network.Parse("203.0.113.2/32"))]);
        var evidence = new EnrichmentSnapshot(DateTimeOffset.UtcNow, "test",
            new Dictionary<string, ServiceEnrichment> { ["a"] = new("a", [IPv4Network.Parse("203.0.113.3/32")], [], ["a.example"], [], null, null, EnrichmentFreshness.Cached) });
        var matched = new CatalogMatcher().Match(new ServiceCatalog([service]),
            new Dictionary<ExportMode, SourceSnapshot> { [ExportMode.Targeted] = source,
                [ExportMode.Lite] = new(ExportMode.Lite, [], []), [ExportMode.Full] = new(ExportMode.Full, [], []) }, evidence);
        Assert.True(RouteSet.UnionEquals([IPv4Network.Parse("203.0.113.2/31")], matched.Routes("a", ExportMode.Targeted)));
    }

    [Fact]
    public void DefaultAndPrivateSourceAndFragmentExplosionAreRejected()
    {
        var catalog = new ServiceCatalog([new CatalogService("a", "A", "X", [], [], [IPv4Network.Parse("8.8.8.8")])]);
        Assert.Throws<InvalidOperationException>(() => new CatalogMatcher().Match(catalog, Sources(IPv4Network.Parse("0.0.0.0/0")), null));
        Assert.Throws<InvalidOperationException>(() => new CatalogMatcher(forbiddenSourceRoutes: [IPv4Network.Parse("10.0.0.0/8")]).Match(catalog, Sources(IPv4Network.Parse("10.0.0.0/8")), null));
        Assert.Throws<InvalidOperationException>(() => new CatalogMatcher(1).Match(catalog, Sources(IPv4Network.Parse("8.8.8.0/24")), null));
    }

    [Fact]
    public void FullModeKeepsExactUnionAndUnknownTargetedDomainsStaySelectable()
    {
        var known = new CatalogService("a", "A", "X", [], [], [IPv4Network.Parse("203.0.0.0/17")]);
        var sources = new Dictionary<ExportMode, SourceSnapshot>
        {
            [ExportMode.Targeted] = new(ExportMode.Targeted, [IPv4Network.Parse("198.51.100.1")],
                [new TargetedRoute("unknown.example", IPv4Network.Parse("198.51.100.1"))]),
            [ExportMode.Lite] = new(ExportMode.Lite, [], []),
            [ExportMode.Full] = new(ExportMode.Full, [IPv4Network.Parse("203.0.0.0/16")], [])
        };
        var matched = new CatalogMatcher().Match(new ServiceCatalog([known]), sources, null);
        Assert.Contains(matched.Catalog.Services, x => x.Category == "Дополнительные ресурсы lib4u" && x.Domains.Contains("unknown.example"));
        Assert.True(RouteSet.UnionEquals(sources[ExportMode.Full].Routes,
            matched.Routes("a", ExportMode.Full).Concat(matched.UnassignedRoutes[ExportMode.Full])));
        Assert.Equal(new[] { IPv4Network.Parse("203.0.128.0/17") }, matched.UnassignedRoutes[ExportMode.Full]);
    }

    private static IReadOnlyDictionary<ExportMode, SourceSnapshot> Sources(IPv4Network route) =>
        new Dictionary<ExportMode, SourceSnapshot>
        {
            [ExportMode.Targeted] = new(ExportMode.Targeted, [], []),
            [ExportMode.Lite] = new(ExportMode.Lite, [route], []),
            [ExportMode.Full] = new(ExportMode.Full, [route], [])
        };
}
