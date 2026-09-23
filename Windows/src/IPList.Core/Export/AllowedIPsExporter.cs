using IPList.Core.Networking;

namespace IPList.Core.Export;

public static class AllowedIPsExporter
{
    public static string Format(IEnumerable<IPv4Network> routes)
    {
        var values = RouteSet.Normalize(routes).Select(route => route.ToString()).ToArray();
        if (values.Length == 0) throw new InvalidOperationException("Selected route set is empty.");
        return "AllowedIPs = " + string.Join(", ", values);
    }
}
