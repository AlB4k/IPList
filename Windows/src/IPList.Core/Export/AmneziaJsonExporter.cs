using System.Text.Json;
using IPList.Core.Networking;

namespace IPList.Core.Export;

public static class AmneziaJsonExporter
{
    public static byte[] Serialize(IEnumerable<IPv4Network> routes)
    {
        var normalized = RouteSet.Normalize(routes);
        if (normalized.Count == 0) throw new InvalidOperationException("Selected route set is empty.");
        var records = normalized.Select(route => new
        {
            hostname = route.Prefix == 32 ? ToAddress(route.Network) : route.ToString(),
            ip = "",
            ips = Array.Empty<string>()
        });
        return JsonSerializer.SerializeToUtf8Bytes(records, new JsonSerializerOptions { WriteIndented = true });
    }

    private static string ToAddress(uint value) => $"{value >> 24}.{(value >> 16) & 255}.{(value >> 8) & 255}.{value & 255}";
}
