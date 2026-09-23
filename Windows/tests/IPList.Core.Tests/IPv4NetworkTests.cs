using IPList.Core.Networking;

namespace IPList.Core.Tests;

public sealed class IPv4NetworkTests
{
    [Theory]
    [InlineData("192.0.2.129/24", "192.0.2.0/24")]
    [InlineData("192.0.2.1", "192.0.2.1/32")]
    [InlineData("0.0.0.0/0", "0.0.0.0/0")]
    [InlineData("203.0.113.3/31", "203.0.113.2/31")]
    public void ParsesAndNormalizes(string input, string expected)
    {
        Assert.True(IPv4Network.TryParse(input, out var network));
        Assert.Equal(expected, network.ToString());
    }

    [Theory]
    [InlineData("256.0.0.1")]
    [InlineData("1.2.3.4/33")]
    [InlineData("1.2.3.4/-1")]
    [InlineData("1.2.3.4/24/8")]
    [InlineData("01.2.3.4")]
    public void RejectsMalformedAddress(string input) => Assert.False(IPv4Network.TryParse(input, out _));

    [Fact]
    public void IntersectionAndContainmentAreExact()
    {
        var broad = IPv4Network.Parse("10.2.0.0/16");
        var narrow = IPv4Network.Parse("10.2.7.0/24");
        Assert.True(broad.Contains(narrow));
        Assert.True(broad.Intersects(narrow));
        Assert.Equal(narrow, broad.Intersect(narrow));
        Assert.Null(broad.Intersect(IPv4Network.Parse("10.3.0.0/16")));
    }

    [Fact]
    public void SubtractionMatchesPerAddressOracle()
    {
        var random = new Random(714);
        for (var i = 0; i < 150; i++)
        {
            var a = IPv4Network.Parse($"192.0.2.{random.Next(256)}/{random.Next(24, 33)}");
            var b = IPv4Network.Parse($"192.0.2.{random.Next(256)}/{random.Next(24, 33)}");
            var actual = a.Subtract(b, 250_000);
            var expectedSet = Expand(a).Except(Expand(b)).ToHashSet();
            Assert.Equal(expectedSet.Order(), actual.SelectMany(Expand).Distinct().Order());
        }
    }

    [Fact]
    public void CollapseAndSemanticEqualityNeverWiden()
    {
        var normalized = RouteSet.Normalize([IPv4Network.Parse("10.0.0.128/25"), IPv4Network.Parse("10.0.0.0/25"), IPv4Network.Parse("10.0.0.1/32")]);
        Assert.Equal(new[] { IPv4Network.Parse("10.0.0.0/24") }, normalized);
        Assert.True(RouteSet.UnionEquals(normalized, [IPv4Network.Parse("10.0.0.0/25"), IPv4Network.Parse("10.0.0.128/25")]));
        Assert.Equal(new[] { IPv4Network.Parse("2.0.0.0/8"), IPv4Network.Parse("10.0.0.0/8") }, RouteSet.Normalize([IPv4Network.Parse("10.0.0.0/8"), IPv4Network.Parse("2.0.0.0/8")]));
    }

    [Fact]
    public void FragmentLimitRejectsBeforePublishingPartialSet()
    {
        Assert.Throws<InvalidOperationException>(() => IPv4Network.Parse("0.0.0.0/0").Subtract(IPv4Network.Parse("192.0.2.1/32"), 1));
    }

    private static IEnumerable<uint> Expand(IPv4Network n)
    {
        for (ulong value = n.Network; value <= n.LastAddress; value++) yield return (uint)value;
    }
}
