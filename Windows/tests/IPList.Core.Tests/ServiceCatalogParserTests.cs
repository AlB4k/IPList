using System.Text;
using IPList.Core.Catalog;

namespace IPList.Core.Tests;

public sealed class ServiceCatalogParserTests
{
    [Fact]
    public void ParsesCategoriesAndAeroflotMetadata()
    {
        var fixture = Path.Combine(AppContext.BaseDirectory, "Fixtures", "catalog.yaml");
        var catalog = ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes(File.ReadAllText(fixture)));
        var aeroflot = Assert.Single(catalog.Services, x => x.Name == "Аэрофлот");
        Assert.Equal("Транспорт, авто и каршеринг", aeroflot.Category);
        Assert.Contains("aeroflot.ru", aeroflot.Domains);
        Assert.Contains("api.aeroflot.ru", aeroflot.Domains);
        Assert.Contains(34571, aeroflot.Asns);
        Assert.Contains("95.163.0.0/16", aeroflot.IpRanges.Select(x => x.ToString()));
        Assert.Equal("Без категории", catalog.Services.Single(x => x.Name == "Unknown").Category);
    }

    [Fact]
    public void RejectsCollisionInvalidListsAndBounds()
    {
        const string header = "services:\n  - name: A\n    domains: [a.example]\n";
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes(header + "  - name: A\n    domains: [b.example]\n")));
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes("services:\n  - name: A\n    asn: [0]\n")));
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes("services:\n  - name: A\n    ip_ranges: [1.2.3.4/33]\n")));
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes("services:\n  - name: A\n    domains: broken\n")));
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(new byte[4 * 1024 * 1024 + 1]));
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes($"services:\n  - name: {new string('x', 513)}\n    domains: [a.example]\n")));
    }

    [Fact]
    public void EnforcesEachItemLimitInUtf8Bytes()
    {
        var serviceCount = "services:\n  - name: A\n    domains: [a.example]\n  - name: B\n    domains: [b.example]\n";
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes(serviceCount), new ServiceCatalogLimits(MaxServices: 1)));
        var threeKinds = "services:\n  - name: A\n    domains: [a.example, b.example]\n    asn: [1, 2]\n    ip_ranges: [1.1.1.1, 2.2.2.2]\n";
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes(threeKinds), new ServiceCatalogLimits(MaxDomains: 1)));
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes(threeKinds), new ServiceCatalogLimits(MaxAsns: 1)));
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes(threeKinds), new ServiceCatalogLimits(MaxRanges: 1)));
        var unicode = "services:\n  - name: ЖЖ\n    domains: [a.example]\n";
        Assert.Throws<FormatException>(() => ServiceCatalogParser.Parse(Encoding.UTF8.GetBytes(unicode), new ServiceCatalogLimits(MaxFieldBytes: 3)));
    }

    [Fact]
    public void BundledCatalogAndVerifiedOverrideLoadOnCleanInstall()
    {
        var catalog = BundledCatalog.Load();
        Assert.True(catalog.Services.Count > 200);
        var oneC = Assert.Single(catalog.Services, x => x.Id == "iplist:1c");
        Assert.Contains("1c.ru", oneC.Domains);
        Assert.DoesNotContain(catalog.Services.Where(x => x.Id != "iplist:1c"), x => x.Domains.Contains("1c.ru"));
        var snapshot = BundledCatalog.LoadEvidence();
        Assert.Contains(snapshot.Services.Values, x => x.Freshness == EnrichmentFreshness.Bundled);
    }
}
