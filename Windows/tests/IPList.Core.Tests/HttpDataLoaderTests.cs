using System.Net;
using System.Net.Http;
using System.Text;
using IPList.Core.Catalog;
using IPList.Core.Refresh;

namespace IPList.Core.Tests;

public sealed class HttpDataLoaderTests
{
    [Fact]
    public async Task RejectsNonHttpsHttpErrorAndOversizedBody()
    {
        using var transport = new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new ByteArrayContent(new byte[33]) }));
        var data = new HttpDataClient(transport, maxResponseBytes: 32);
        await Assert.ThrowsAsync<InvalidOperationException>(() => data.GetLimitedAsync(new Uri("http://example.test/"), CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => data.GetLimitedAsync(new Uri("https://example.test/"), CancellationToken.None));
        using var failed = new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)));
        await Assert.ThrowsAsync<HttpRequestException>(() => new HttpDataClient(failed).GetLimitedAsync(new Uri("https://example.test/"), CancellationToken.None));
    }

    [Fact]
    public async Task ParsesAllThreeSourceModesAndRipePrefixes()
    {
        const string targeted = "[{\"hostname\":\"a.example\",\"ip\":\"203.0.113.1\",\"ips\":[\"203.0.113.2/32\"]}]";
        const string ranges = "[{\"hostname\":\"198.51.100.0/24\",\"ip\":\"\",\"ips\":[]}]";
        const string ripe = "{\"data\":{\"query_endtime\":\"2026-09-23T12:00:00\",\"prefixes\":[{\"prefix\":\"203.0.113.0/24\",\"timelines\":[{\"starttime\":\"2026-09-23T11:00:00\",\"endtime\":\"2026-09-23T13:00:00\"}]}]}}";
        using var transport = new Handler((request, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent(request.RequestUri!.AbsolutePath.Contains("ripe") ? ripe : request.RequestUri.AbsolutePath.Contains("targeted") ? targeted : ranges, Encoding.UTF8) }));
        var data = new HttpDataClient(transport);
        var loader = new AddressListHttpLoader(data);
        var target = await loader.LoadAsync(new Uri("https://example.test/targeted"), ExportMode.Targeted, CancellationToken.None);
        Assert.Equal(2, target.TargetedRoutes.Count);
        Assert.Equal(2, target.Routes.Count);
        Assert.Contains(target.TargetedRoutes, x => x.CanonicalDomain == "a.example");
        var lite = await loader.LoadAsync(new Uri("https://example.test/lite"), ExportMode.Lite, CancellationToken.None);
        Assert.Equal("198.51.100.0/24", Assert.Single(lite.Routes).ToString());
        Assert.Single(await new RipeStatHttpLoader(data, new Uri("https://example.test/ripe"),
            () => new DateTimeOffset(2026, 9, 23, 12, 0, 0, TimeSpan.Zero)).LoadPrefixesAsync(34571, CancellationToken.None));
    }

    [Fact]
    public async Task CatalogLoaderFallsBackToLicensedBundleWhenRemoteFails()
    {
        using var transport = new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable)));
        var catalog = await new ServiceCatalogHttpLoader(new HttpDataClient(transport)).LoadOrFallbackAsync(new Uri("https://example.test/catalog"), null, CancellationToken.None);
        Assert.Equal(CatalogFreshness.Bundled, catalog.Freshness);
        Assert.True(catalog.Services.Count > 200);
    }

    [Fact]
    public async Task PerRequestDeadlineReturnsWhenHandlerIgnoresCancellation()
    {
        using var transport = new Handler(async (_, _) =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan);
            throw new Exception("unreachable");
        });
        var loader = new HttpDataClient(transport, requestTimeout: TimeSpan.FromMilliseconds(15));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            loader.GetLimitedAsync(new Uri("https://example.test/hang"), CancellationToken.None));
    }

    [Fact]
    public async Task RipeStatRejectsOldObservation()
    {
        const string old = "{\"data\":{\"query_endtime\":\"2020-01-01T00:00:00\",\"prefixes\":[{\"prefix\":\"203.0.113.0/24\",\"timelines\":[{\"starttime\":\"2019-01-01T00:00:00\",\"endtime\":\"2021-01-01T00:00:00\"}]}]}}";
        using var transport = new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent(old) }));
        await Assert.ThrowsAsync<FormatException>(() => new RipeStatHttpLoader(new HttpDataClient(transport),
            clock: () => new DateTimeOffset(2026, 9, 23, 12, 0, 0, TimeSpan.Zero))
            .LoadPrefixesAsync(34571, CancellationToken.None));
    }

    [Theory]
    [InlineData(ExportMode.Targeted, "[{\"hostname\":\"a.example\",\"ip\":\"203.0.113.1\",\"ips\":[\"broken\"]}]")]
    [InlineData(ExportMode.Lite, "[{\"hostname\":\"198.51.100.0/24\",\"ip\":\"broken\",\"ips\":[] }]")]
    [InlineData(ExportMode.Full, "[{\"hostname\":\"198.51.100.0/24\",\"ip\":\"\",\"ips\":[\"not-an-address\"]}]")]
    [InlineData(ExportMode.Targeted, "[{\"hostname\":\"999.51.100.1\",\"ip\":\"203.0.113.1\",\"ips\":[]}]")]
    [InlineData(ExportMode.Targeted, "[{\"hostname\":\"a.example\",\"ip\":\"203.0.113.1\",\"ips\":[7]}]")]
    public async Task MixedValidAndInvalidAddressFieldsRejectWholeSource(ExportMode mode, string body)
    {
        using var transport = new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent(body) }));
        await Assert.ThrowsAsync<FormatException>(() => new AddressListHttpLoader(new HttpDataClient(transport))
            .LoadAsync(new Uri("https://example.test/list"), mode, CancellationToken.None));
    }

    [Fact]
    public async Task InvalidLaterRowRejectsEarlierValidAddressesToo()
    {
        const string body = "[{\"hostname\":\"198.51.100.0/24\",\"ip\":\"\",\"ips\":[]}," +
            "{\"hostname\":\"203.0.113.0/24\",\"ip\":\"999.0.0.1\",\"ips\":[]}]";
        using var transport = new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent(body) }));
        await Assert.ThrowsAsync<FormatException>(() => new AddressListHttpLoader(new HttpDataClient(transport))
            .LoadAsync(new Uri("https://example.test/list"), ExportMode.Full, CancellationToken.None));
    }

    [Fact]
    public async Task HttpsToHttpRedirectIsRejectedBeforeHttpRequest()
    {
        var seen = new List<Uri>();
        using var transport = new Handler((request, _) =>
        {
            seen.Add(request.RequestUri!);
            return Task.FromResult(new HttpResponseMessage(HttpStatusCode.Redirect)
            { Headers = { Location = new Uri("http://example.test/leak") } });
        });
        var data = new HttpDataClient(transport);
        await Assert.ThrowsAsync<InvalidOperationException>(() => data.GetLimitedAsync(new Uri("https://example.test/source"), CancellationToken.None));
        Assert.Single(seen);
        Assert.All(seen, uri => Assert.Equal(Uri.UriSchemeHttps, uri.Scheme));
    }

    [Fact]
    public void AutoRedirectEnabledHandlerCannotBeInjected()
    {
        using var transport = new SocketsHttpHandler { AllowAutoRedirect = true };
        Assert.Throws<ArgumentException>(() => new HttpDataClient(transport));
    }

    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request, cancellationToken);
    }
}
