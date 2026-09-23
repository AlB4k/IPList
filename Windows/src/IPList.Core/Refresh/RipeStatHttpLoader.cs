using System.Globalization;
using System.Text.Json;
using IPList.Core.Networking;

namespace IPList.Core.Refresh;

public sealed class RipeStatHttpLoader(HttpDataClient client, Uri? endpoint = null,
    Func<DateTimeOffset>? clock = null)
{
    private readonly Uri _endpoint = endpoint ?? new Uri("https://stat.ripe.net/data/announced-prefixes/data.json");
    private readonly Func<DateTimeOffset> _clock = clock ?? (() => DateTimeOffset.UtcNow);

    public async Task<IReadOnlyList<IPv4Network>> LoadPrefixesAsync(int asn, CancellationToken cancellationToken)
    {
        if (asn <= 0) throw new ArgumentOutOfRangeException(nameof(asn));
        var observationEnd = _clock();
        var observationStart = observationEnd.AddHours(-1);
        var builder = new UriBuilder(_endpoint)
        {
            Query = $"resource=AS{asn}&starttime={observationStart.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture)}" +
                    $"&endtime={observationEnd.ToString("yyyy-MM-ddTHH:mm:ss", CultureInfo.InvariantCulture)}"
        };
        using var document = JsonDocument.Parse(await client.GetLimitedAsync(builder.Uri, cancellationToken).ConfigureAwait(false));
        var payload = document.RootElement.GetProperty("data");
        if (!DateTimeOffset.TryParse(payload.GetProperty("query_endtime").GetString(), CultureInfo.InvariantCulture,
                DateTimeStyles.AssumeUniversal, out var queryEnd)) throw new FormatException("Invalid RIPEstat observation time.");
        if (queryEnd < observationStart || queryEnd > observationEnd.AddMinutes(1))
            throw new FormatException("Stale RIPEstat observation.");
        var rows = payload.GetProperty("prefixes");
        if (rows.ValueKind != JsonValueKind.Array || rows.GetArrayLength() > 100_000) throw new FormatException("Invalid RIPEstat prefixes.");
        var result = new List<IPv4Network>();
        foreach (var row in rows.EnumerateArray())
        {
            var text = row.GetProperty("prefix").GetString();
            if (!IPv4Network.TryParse(text, out var network)) continue;
            var timelines = row.GetProperty("timelines");
            if (timelines.ValueKind != JsonValueKind.Array) throw new FormatException("Invalid RIPEstat timeline.");
            if (timelines.EnumerateArray().Any(t => Covers(t, queryEnd))) result.Add(network);
        }
        if (result.Count == 0) throw new FormatException("RIPEstat returned no current IPv4 prefixes.");
        return RouteSet.Normalize(result);
    }

    private static bool Covers(JsonElement row, DateTimeOffset end)
    {
        if (!DateTimeOffset.TryParse(row.GetProperty("starttime").GetString(), CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal, out var start)) return false;
        if (!row.TryGetProperty("endtime", out var endField) || endField.ValueKind == JsonValueKind.Null) return start <= end;
        return DateTimeOffset.TryParse(endField.GetString(), CultureInfo.InvariantCulture,
            DateTimeStyles.AssumeUniversal, out var finish) && start <= end && end <= finish;
    }
}
