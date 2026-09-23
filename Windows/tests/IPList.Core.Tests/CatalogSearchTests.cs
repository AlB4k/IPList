using IPList.Core.Catalog;
using IPList.Core.Networking;

namespace IPList.Core.Tests;

public sealed class CatalogSearchTests
{
    [Theory]
    [InlineData("Аэрофлот")]
    [InlineData("api.aeroflot.ru")]
    [InlineData("AS34571")]
    [InlineData("95.163.1.2")]
    [InlineData("95.163.0.0/15")]
    public void FindsAeroflotByMetadataOrContainingRoute(string query)
    {
        var service = new CatalogService("pincetgore:aeroflot", "Аэрофлот", "Транспорт", ["aeroflot.ru", "api.aeroflot.ru"], [34571],
            [IPv4Network.Parse("95.163.0.0/16")]);
        Assert.True(CatalogSearch.Matches(service, query, ExportMode.Targeted));
    }

    [Fact]
    public void FindsMatchedIpAndCidRInCurrentMode()
    {
        var service = new CatalogService("a", "A", "X", [], [], [IPv4Network.Parse("8.8.8.8")]);
        var source = new Dictionary<ExportMode, SourceSnapshot>
        {
            [ExportMode.Targeted] = new(ExportMode.Targeted, [], []),
            [ExportMode.Lite] = new(ExportMode.Lite, [IPv4Network.Parse("203.0.113.0/24")], []),
            [ExportMode.Full] = new(ExportMode.Full, [IPv4Network.Parse("203.0.113.0/24")], [])
        };
        var cached = new EnrichmentSnapshot(DateTimeOffset.UtcNow, "fixture", new Dictionary<string, ServiceEnrichment>
        {
            ["a"] = new("a", [IPv4Network.Parse("203.0.113.9")], [], [], [], null, null, EnrichmentFreshness.Cached)
        });
        var matched = new CatalogMatcher().Match(new ServiceCatalog([service]), source, cached);
        Assert.True(CatalogSearch.Matches(matched.Catalog.Services.Single(), "203.0.113.9", ExportMode.Lite));
    }
}
