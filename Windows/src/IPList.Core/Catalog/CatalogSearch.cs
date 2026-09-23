using IPList.Core.Networking;

namespace IPList.Core.Catalog;

public static class CatalogSearch
{
    public static bool Matches(CatalogService service, string query, ExportMode mode)
    {
        var text = query.Trim();
        if (text.Length == 0) return true;
        if (service.Name.Contains(text, StringComparison.OrdinalIgnoreCase) ||
            service.Category.Contains(text, StringComparison.OrdinalIgnoreCase) ||
            service.Domains.Any(x => x.Contains(text, StringComparison.OrdinalIgnoreCase)) ||
            service.Asns.Any(x => $"AS{x}".Contains(text, StringComparison.OrdinalIgnoreCase))) return true;
        var routes = mode switch
        {
            ExportMode.Targeted => service.TargetedAddresses,
            ExportMode.Lite => service.LiteAddresses,
            _ => service.FullAddresses
        };
        var all = routes.Concat(service.IpRanges);
        if (IPv4Network.TryParse(text, out var network))
            return all.Any(route => route.Intersects(network));
        return all.Any(route => route.ToString().Contains(text, StringComparison.OrdinalIgnoreCase));
    }
}
