using System.Text.Json;
using IPList.Core.Export;
using IPList.Core.Networking;

namespace IPList.Core.Tests;

public sealed class ExporterTests
{
    [Fact]
    public void AllowedIPsNormalizesDeduplicatesAndSortsRoutes()
    {
        var value = AllowedIPsExporter.Format([
            IPv4Network.Parse("10.0.0.128/25"), IPv4Network.Parse("2.0.0.1"),
            IPv4Network.Parse("10.0.0.0/25"), IPv4Network.Parse("2.0.0.1/32")]);

        Assert.Equal("AllowedIPs = 2.0.0.1/32, 10.0.0.0/24", value);
    }

    [Fact]
    public void AllowedIPsRejectsEmptySelection()
    {
        Assert.Throws<InvalidOperationException>(() => AllowedIPsExporter.Format([]));
    }

    [Fact]
    public void AmneziaJsonEncodesHostsAndNetworksInExpectedShape()
    {
        var bytes = AmneziaJsonExporter.Serialize([
            IPv4Network.Parse("192.0.2.7"), IPv4Network.Parse("198.51.100.0/24")]);
        using var json = JsonDocument.Parse(bytes);
        var items = json.RootElement.EnumerateArray().ToArray();

        Assert.Equal(2, items.Length);
        Assert.Equal("192.0.2.7", items[0].GetProperty("hostname").GetString());
        Assert.Equal("", items[0].GetProperty("ip").GetString());
        Assert.Empty(items[0].GetProperty("ips").EnumerateArray());
        Assert.Equal("198.51.100.0/24", items[1].GetProperty("hostname").GetString());
        Assert.Equal("", items[1].GetProperty("ip").GetString());
        Assert.Empty(items[1].GetProperty("ips").EnumerateArray());
    }
}
