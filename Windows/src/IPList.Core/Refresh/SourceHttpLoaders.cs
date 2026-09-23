using System.Text.Json;
using IPList.Core.Catalog;
using IPList.Core.Networking;

namespace IPList.Core.Refresh;

public sealed class AddressListHttpLoader(HttpDataClient client) : IAddressListLoader
{
    public async Task<SourceSnapshot> LoadAsync(Uri uri, ExportMode mode, CancellationToken cancellationToken)
    {
        using var document = JsonDocument.Parse(await client.GetLimitedAsync(uri, cancellationToken).ConfigureAwait(false));
        if (document.RootElement.ValueKind != JsonValueKind.Array) throw new FormatException("Address source must be an array.");
        var addresses = new List<IPv4Network>();
        var targeted = new List<TargetedRoute>();
        foreach (var row in document.RootElement.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object) throw new FormatException("Invalid address row.");
            var hostname = String(row, "hostname");
            var values = new List<string> { hostname, String(row, "ip") };
            if (row.TryGetProperty("ips", out var ips) && ips.ValueKind != JsonValueKind.Null)
            {
                if (ips.ValueKind != JsonValueKind.Array) throw new FormatException("Invalid ips array.");
                values.AddRange(ips.EnumerateArray().Select(x => x.GetString() ?? ""));
            }
            foreach (var value in values)
            {
                if (!IPv4Network.TryParse(value, out var address)) continue;
                addresses.Add(address);
                if (mode == ExportMode.Targeted)
                    targeted.Add(new TargetedRoute(IPv4Network.TryParse(hostname, out _) || hostname.Length == 0 ? null : hostname, address));
            }
        }
        if (addresses.Count == 0) throw new FormatException("Address source is empty.");
        var routes = RouteSet.Normalize(addresses);
        return new SourceSnapshot(mode, routes, targeted.Distinct().ToArray());
    }

    private static string String(JsonElement row, string name) =>
        row.TryGetProperty(name, out var value) && value.ValueKind == JsonValueKind.String ? value.GetString() ?? "" : "";
}
