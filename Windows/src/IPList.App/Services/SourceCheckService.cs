using System.Diagnostics;
using System.Text.Json;
using IPList.Core.Catalog;
using IPList.Core.Networking;

namespace IPList.Windows.Services;

public sealed class SourceCheckService
{
    private static readonly HttpClient Client = new() { Timeout = TimeSpan.FromSeconds(12) };

    public async Task<string> CheckAsync(string name, Uri uri, bool metadata, CancellationToken cancellationToken)
    {
        var watch = Stopwatch.StartNew();
        try
        {
            using var response = await Client.GetAsync(uri, HttpCompletionOption.ResponseHeadersRead, cancellationToken);
            if (!response.IsSuccessStatusCode)
                return $"{name}: HTTP {(int)response.StatusCode}, {watch.ElapsedMilliseconds} мс, источник недоступен";
            await using var stream = await response.Content.ReadAsStreamAsync(cancellationToken);
            using var bytes = new MemoryStream();
            var buffer = new byte[32 * 1024];
            int read;
            while ((read = await stream.ReadAsync(buffer, cancellationToken)) > 0)
            {
                if (bytes.Length + read > 4 * 1024 * 1024) throw new FormatException();
                bytes.Write(buffer, 0, read);
            }
            var count = metadata ? ServiceCatalogParser.Parse(bytes.ToArray()).Services.Count : CountAddresses(bytes.ToArray());
            return $"{name}: HTTP {(int)response.StatusCode}, {watch.ElapsedMilliseconds} мс, {count} записей";
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
