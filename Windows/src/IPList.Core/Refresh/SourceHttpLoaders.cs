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
            if (!row.TryGetProperty("hostname", out var hostField) || hostField.ValueKind != JsonValueKind.String)
                throw new FormatException("Address row hostname must be a string.");
            var hostname = hostField.GetString()?.Trim() ?? "";
            if (IPv4Network.TryParse(hostname, out var hostAddress)) addresses.Add(hostAddress);
            else if (LooksLikeAddress(hostname)) throw new FormatException("Invalid hostname address.");
            if (row.TryGetProperty("ip", out var ipField) && ipField.ValueKind != JsonValueKind.Null)
            {
                if (ipField.ValueKind != JsonValueKind.String) throw new FormatException("Address row ip must be a string.");
                var text = ipField.GetString()?.Trim() ?? "";
                if (text.Length > 0) AddAddress(text);
            }
            if (row.TryGetProperty("ips", out var ips) && ips.ValueKind != JsonValueKind.Null)
            {
                if (ips.ValueKind != JsonValueKind.Array) throw new FormatException("Invalid ips array.");
                foreach (var item in ips.EnumerateArray())
                {
                    if (item.ValueKind != JsonValueKind.String) throw new FormatException("Invalid ips item type.");
                    AddAddress(item.GetString()?.Trim() ?? "");
                }
            }
            if (mode == ExportMode.Targeted && IPv4Network.TryParse(hostname, out _))
                targeted.Add(new TargetedRoute(null, hostAddress));

            void AddAddress(string text)
            {
                if (!IPv4Network.TryParse(text, out var address)) throw new FormatException("Invalid IPv4 address field.");
                addresses.Add(address);
                if (mode == ExportMode.Targeted)
                    targeted.Add(new TargetedRoute(hostname.Length == 0 || IPv4Network.TryParse(hostname, out _) ? null : hostname, address));
            }
        }
        if (addresses.Count == 0) throw new FormatException("Address source is empty.");
        var routes = RouteSet.Normalize(addresses);
        return new SourceSnapshot(mode, routes, targeted.Distinct().ToArray());
    }

    private static bool LooksLikeAddress(string value) =>
        value.Contains('/') || value.Contains(':') || value.Any(char.IsWhiteSpace) ||
        value.Length > 0 && value.All(c => (c >= '0' && c <= '9') || c == '.');
}
