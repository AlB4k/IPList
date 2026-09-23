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
        using var client = new HttpClient(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new ByteArrayContent(new byte[33]) })));
        var data = new HttpDataClient(client, maxResponseBytes: 32);
        await Assert.ThrowsAsync<InvalidOperationException>(() => data.GetLimitedAsync(new Uri("http://example.test/"), CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => data.GetLimitedAsync(new Uri("https://example.test/"), CancellationToken.None));
        using var failed = new HttpClient(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable))));
        await Assert.ThrowsAsync<HttpRequestException>(() => new HttpDataClient(failed).GetLimitedAsync(new Uri("https://example.test/"), CancellationToken.None));
    }

    [Fact]
    public async Task ParsesAllThreeSourceModesAndRipePrefixes()
    {
        const string targeted = "[{\"hostname\":\"a.example\",\"ip\":\"203.0.113.1\",\"ips\":[\"203.0.113.2/32\"]}]";
        const string ranges = "[{\"hostname\":\"198.51.100.0/24\",\"ip\":\"\",\"ips\":[]}]";
        const string ripe = "{\"data\":{\"query_endtime\":\"2026-09-23T12:00:00\",\"prefixes\":[{\"prefix\":\"203.0.113.0/24\",\"timelines\":[{\"starttime\":\"2026-09-23T11:00:00\",\"endtime\":\"2026-09-23T13:00:00\"}]}]}}";
        using var client = new HttpClient(new Handler((request, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent(request.RequestUri!.AbsolutePath.Contains("ripe") ? ripe : request.RequestUri.AbsolutePath.Contains("targeted") ? targeted : ranges, Encoding.UTF8) })));
        var data = new HttpDataClient(client);
        var loader = new AddressListHttpLoader(data);
        var target = await loader.LoadAsync(new Uri("https://example.test/targeted"), ExportMode.Targeted, CancellationToken.None);
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
        using var client = new HttpClient(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.ServiceUnavailable))));
        var catalog = await new ServiceCatalogHttpLoader(new HttpDataClient(client)).LoadOrFallbackAsync(new Uri("https://example.test/catalog"), null, CancellationToken.None);
        Assert.Equal(CatalogFreshness.Bundled, catalog.Freshness);
        Assert.True(catalog.Services.Count > 200);
    }

    [Fact]
    public async Task PerRequestDeadlineReturnsWhenHandlerIgnoresCancellation()
    {
        using var client = new HttpClient(new Handler(async (_, _) =>
        {
            await Task.Delay(Timeout.InfiniteTimeSpan);
            throw new Exception("unreachable");
        }));
        var loader = new HttpDataClient(client, requestTimeout: TimeSpan.FromMilliseconds(15));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() =>
            loader.GetLimitedAsync(new Uri("https://example.test/hang"), CancellationToken.None));
    }

    [Fact]
    public async Task RipeStatRejectsOldObservation()
    {
        const string old = "{\"data\":{\"query_endtime\":\"2020-01-01T00:00:00\",\"prefixes\":[{\"prefix\":\"203.0.113.0/24\",\"timelines\":[{\"starttime\":\"2019-01-01T00:00:00\",\"endtime\":\"2021-01-01T00:00:00\"}]}]}}";
        using var client = new HttpClient(new Handler((_, _) => Task.FromResult(new HttpResponseMessage(HttpStatusCode.OK)
        { Content = new StringContent(old) })));
        await Assert.ThrowsAsync<FormatException>(() => new RipeStatHttpLoader(new HttpDataClient(client),
            clock: () => new DateTimeOffset(2026, 9, 23, 12, 0, 0, TimeSpan.Zero))
            .LoadPrefixesAsync(34571, CancellationToken.None));
    }

    private sealed class Handler(Func<HttpRequestMessage, CancellationToken, Task<HttpResponseMessage>> send) : HttpMessageHandler
    {
        protected override Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken cancellationToken) => send(request, cancellationToken);
    }
}
