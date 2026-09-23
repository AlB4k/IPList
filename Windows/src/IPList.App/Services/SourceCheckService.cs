using System.Diagnostics;
using System.Text.Json;
using IPList.Core.Catalog;
using IPList.Core.Networking;
using IPList.Core.Refresh;

namespace IPList.Windows.Services;

public sealed class SourceCheckService
{
    private static readonly HttpDataClient Client = HttpDataClient.CreateProduction();

    public async Task<string> CheckAsync(string name, Uri uri, bool metadata, CancellationToken cancellationToken)
    {
        var watch = Stopwatch.StartNew();
        try
        {
            var bytes = await Client.GetLimitedAsync(uri, cancellationToken);
            var count = metadata ? ServiceCatalogParser.Parse(bytes).Services.Count : CountAddresses(bytes);
            return $"{name}: HTTPS OK, {watch.ElapsedMilliseconds} мс, {count} записей";
        }
        catch (OperationCanceledException) { return $"{name}: время ожидания истекло"; }
        catch (HttpRequestException) { return $"{name}: HTTP/сетевая ошибка"; }
        catch { return $"{name}: некорректный ответ"; }
    }

    private static int CountAddresses(byte[] bytes)
    {
        using var json = JsonDocument.Parse(bytes);
        if (json.RootElement.ValueKind != JsonValueKind.Array) throw new FormatException();
        var count = 0;
        foreach (var row in json.RootElement.EnumerateArray())
        {
            if (row.ValueKind != JsonValueKind.Object) throw new FormatException();
            foreach (var key in new[] { "hostname", "ip" })
                if (row.TryGetProperty(key, out var value) && value.ValueKind == JsonValueKind.String &&
                    IPv4Network.TryParse(value.GetString(), out _)) count++;
            if (row.TryGetProperty("ips", out var ips) && ips.ValueKind == JsonValueKind.Array)
                foreach (var value in ips.EnumerateArray())
                    if (value.ValueKind == JsonValueKind.String && IPv4Network.TryParse(value.GetString(), out _)) count++;
        }
        return count;
    }
}
