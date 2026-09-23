using System.Text;
using IPList.Core.Amnezia;
using IPList.Core.Networking;

namespace IPList.Core.Tests;

public sealed class AmneziaConfigDocumentTests
{
    private static readonly byte[] Fixture = File.ReadAllBytes(Path.Combine(AppContext.BaseDirectory, "Fixtures", "sample.conf"));

    [Fact]
    public void AddMergesAndNormalizesOnlySelectedPeerPreservingOtherContent()
    {
        var document = AmneziaConfigDocument.Parse(Fixture);
        var output = Encoding.UTF8.GetString(document.Render(0, AllowedIPsOperation.Add,
            [IPv4Network.Parse("10.20.0.0/16"), IPv4Network.Parse("10.10.1.1")]));

        Assert.Contains("AllowedIPs = 10.10.0.0/16, 10.20.0.0/16, 2001:db8::/32", output);
        Assert.Contains("Endpoint = 192.0.2.10:51820", output);
        Assert.Contains("AllowedIPs = 172.16.0.0/16", output);
        Assert.Contains("PrivateKey = dGVzdC1vbmx5LWZha2Uta2V5", output);
    }

    [Fact]
    public void ReplaceUsesSelectedRoutesAndCanPreserveOrDropIPv6()
    {
        var document = AmneziaConfigDocument.Parse(Fixture);
        var routes = new[] { IPv4Network.Parse("203.0.113.7/24") };

        var withIpv6 = Encoding.UTF8.GetString(document.Render(0, AllowedIPsOperation.Replace, routes));
        var withoutIpv6 = Encoding.UTF8.GetString(document.Render(0, AllowedIPsOperation.Replace, routes, preserveIPv6: false));

        Assert.Contains("AllowedIPs = 203.0.113.0/24, 2001:db8::/32", withIpv6);
        Assert.Contains("AllowedIPs = 203.0.113.0/24", withoutIpv6);
    }

    [Fact]
    public void BypassSubtractsSelectedRangeFromExistingRoutes()
    {
        var output = Encoding.UTF8.GetString(AmneziaConfigDocument.Parse(Fixture).Render(0,
            AllowedIPsOperation.Bypass, [IPv4Network.Parse("10.10.4.0/24")]));

        Assert.Contains("AllowedIPs = 10.10.0.0/22, 10.10.5.0/24, 10.10.6.0/23, 10.10.8.0/21, 10.10.16.0/20, 10.10.32.0/19, 10.10.64.0/18, 10.10.128.0/17, 2001:db8::/32", output);
        Assert.Contains("AllowedIPs = 172.16.0.0/16", output);
    }

    [Fact]
    public void InsertsAllowedIPsWhenAbsentAndPreservesUtf8Bom()
    {
        var source = new byte[] { 0xEF, 0xBB, 0xBF }.Concat(Encoding.UTF8.GetBytes("[Peer]\r\nPublicKey = fake\r\nEndpoint = 192.0.2.1:1\r\n")).ToArray();
        var output = AmneziaConfigDocument.Parse(source).Render(0, AllowedIPsOperation.Replace,
            [IPv4Network.Parse("192.0.2.4")]);

        Assert.Equal(new byte[] { 0xEF, 0xBB, 0xBF }, output[..3]);
        var text = Encoding.UTF8.GetString(output[3..]);
        Assert.Contains("PublicKey = fake\r\nAllowedIPs = 192.0.2.4/32\r\nEndpoint", text);
    }

    [Fact]
    public void BatchNamingIsDeterministicAcrossCaseInsensitiveDuplicateStems()
    {
        using var temp = new TempDirectory();
        var paths = BatchOutputNamer.Create(["a/home.conf", "b/HOME.conf", "c/home.conf"], temp.Path);

        Assert.Equal(new[]
        {
            Path.Combine(temp.Path, "home-iplist.conf"),
            Path.Combine(temp.Path, "HOME-iplist-2.conf"),
            Path.Combine(temp.Path, "home-iplist-3.conf")
        }, paths);
    }
}
