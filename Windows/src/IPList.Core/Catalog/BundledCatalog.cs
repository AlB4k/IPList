using System.Text.Json;
using IPList.Core.Networking;

namespace IPList.Core.Catalog;

public static class BundledCatalog
{
    private static byte[] ReadResource(string name)
    {
        var assembly = typeof(BundledCatalog).Assembly;
        var fullName = assembly.GetManifestResourceNames().Single(x => x.EndsWith(".Resources.ThirdParty." + name, StringComparison.Ordinal));
        using var stream = assembly.GetManifestResourceStream(fullName) ?? throw new InvalidOperationException("Bundled resource missing.");
        using var output = new MemoryStream();
        stream.CopyTo(output);
        return output.ToArray();
    }

    public static ServiceCatalog Load()
    {
        var catalog = ServiceCatalogParser.Parse(ReadResource("pincetgore-config.yaml"));
        return ApplyOverrides(catalog, ReadResource("iplist-service-overrides.json")) with { Freshness = CatalogFreshness.Bundled };
    }

    public static ServiceCatalog ApplyOverrides(ServiceCatalog catalog, ReadOnlySpan<byte> json)
    {
        using var document = JsonDocument.Parse(json.ToArray());
        if (document.RootElement.ValueKind != JsonValueKind.Array) throw new FormatException("Overrides must be an array.");
        var services = catalog.Services.ToList();
        foreach (var element in document.RootElement.EnumerateArray())
        {
            var id = element.GetProperty("id").GetString() ?? throw new FormatException("Override ID missing.");
            var name = element.GetProperty("name").GetString() ?? throw new FormatException("Override name missing.");
            var category = element.GetProperty("category").GetString() ?? "Без категории";
            var domains = ReadStrings(element, "domains").Select(x => x.ToLowerInvariant().TrimEnd('.')).Distinct().ToArray();
            var asns = element.GetProperty("asn").EnumerateArray().Select(x => x.GetInt64()).ToArray();
            var ranges = ReadStrings(element, "ipRanges").Select(IPv4Network.Parse).ToArray();
            var detached = ReadStrings(element, "detachDomains").Select(x => x.ToLowerInvariant().TrimEnd('.')).ToHashSet();
            services = services.Select(s => new CatalogService(s.Id, s.Name, s.Category,
                s.Domains.Where(d => !detached.Contains(d)).ToArray(), s.Asns, s.IpRanges)).
                Where(s => s.Domains.Count + s.Asns.Count + s.IpRanges.Count > 0 && s.Id != id).ToList();
            services.Add(new CatalogService(id, name, category, domains, asns, ranges));
        }
        if (services.Select(x => x.Id).Distinct().Count() != services.Count) throw new FormatException("Duplicate override ID.");
        return catalog with { Services = services };
    }

    public static ServiceCatalog ApplyBundledOverrides(ServiceCatalog catalog) =>
        ApplyOverrides(catalog, ReadResource("iplist-service-overrides.json"));

    public static EnrichmentSnapshot LoadEvidence()
    {
        using var document = JsonDocument.Parse(ReadResource("enrichment-snapshot.json"));
        var root = document.RootElement;
        var services = new Dictionary<string, ServiceEnrichment>(StringComparer.Ordinal);
        foreach (var property in root.GetProperty("services").EnumerateObject())
        {
            var item = property.Value;
            var freshness = item.TryGetProperty("freshness", out var f) && f.GetString() == "stale"
                ? EnrichmentFreshness.Stale : EnrichmentFreshness.Bundled;
            services[property.Name] = new ServiceEnrichment(property.Name,
                ReadStrings(item, "dnsAddresses").Select(IPv4Network.Parse).ToArray(),
                ReadStrings(item, "asnPrefixes").Select(IPv4Network.Parse).ToArray(),
                ReadStrings(item, "dnsDomains"), ReadLongs(item, "asnNumbers"),
                ReadTimestamp(item, "dnsUpdatedAt"), ReadTimestamp(item, "asnUpdatedAt"), freshness);
        }
        return new EnrichmentSnapshot(DateTimeOffset.FromUnixTimeSeconds((long)root.GetProperty("generatedAt").GetDouble()),
            root.GetProperty("provenance").GetString() ?? "", services);
    }

    private static IReadOnlyList<string> ReadStrings(JsonElement parent, string name) =>
        parent.TryGetProperty(name, out var item) && item.ValueKind == JsonValueKind.Array
            ? item.EnumerateArray().Select(x => x.GetString() ?? "").ToArray() : [];

    private static IReadOnlyList<long> ReadLongs(JsonElement parent, string name) =>
        parent.TryGetProperty(name, out var item) && item.ValueKind == JsonValueKind.Array
            ? item.EnumerateArray().Select(x => x.GetInt64()).ToArray() : [];

    private static DateTimeOffset? ReadTimestamp(JsonElement parent, string name) =>
        parent.TryGetProperty(name, out var item) && item.ValueKind == JsonValueKind.Number
            ? DateTimeOffset.FromUnixTimeSeconds((long)item.GetDouble()) : null;
}
