using System.Net;
using IPList.Core.Catalog;
using IPList.Core.Networking;
using IPList.Core.Refresh;

namespace IPList.Core.Tests;

public sealed class RefreshPipelineTests
{
    [Fact]
    public async Task BuildsCandidateWithoutMutatingPreviousCatalogOrCache()
    {
        var prior = Catalog("a.example");
        var snapshot = new EnrichmentSnapshot(DateTimeOffset.UtcNow, "test", new Dictionary<string, ServiceEnrichment>());
        var pipeline = Pipeline(prior, new StubAddressLoader(), new StubDns(), new StubAsn());
        var candidate = await pipeline.RunAsync(new RefreshRequest(RefreshSourceUrls.Default, prior, snapshot), CancellationToken.None);
        Assert.True(RouteSet.UnionEquals([IPv4Network.Parse("198.51.100.0/24")],
            candidate.MatchedCatalog.Routes("a", ExportMode.Lite).Concat(candidate.MatchedCatalog.UnassignedRoutes[ExportMode.Lite])));
        Assert.Empty(prior.Services.Single().LiteAddresses);
        Assert.Empty(snapshot.Services);
        Assert.Equal(3, candidate.SourceSnapshots.Count);
    }

    [Fact]
    public async Task FailedSourceAndSuspiciousShrinkLeavePriorObjectsUntouched()
    {
        var prior = Catalog("a.example", "b.example", "c.example", "d.example");
        var request = new RefreshRequest(RefreshSourceUrls.Default, prior);
        await Assert.ThrowsAnyAsync<Exception>(() => Pipeline(prior, new StubAddressLoader(failMode: ExportMode.Lite), new StubDns(), new StubAsn()).RunAsync(request, CancellationToken.None));
        await Assert.ThrowsAsync<InvalidOperationException>(() => Pipeline(Catalog("a.example"), new StubAddressLoader(), new StubDns(), new StubAsn()).RunAsync(request, CancellationToken.None));
        Assert.Equal(4, prior.Services.Count);
        Assert.All(prior.Services, x => Assert.Empty(x.LiteAddresses));
    }

    [Fact]
    public async Task MetadataShrinkBelowSeventyPercentIsRejected()
    {
        var prior = new ServiceCatalog(Enumerable.Range(0, 10)
            .Select(i => new CatalogService($"prior-{i}", $"Prior {i}", "X", [$"prior-{i}.example"], [], []))
            .ToArray());
        var candidate = new ServiceCatalog(Enumerable.Range(0, 6)
            .Select(i => new CatalogService($"candidate-{i}", $"Candidate {i}", "X", [$"candidate-{i}.example"], [], []))
            .ToArray());
        var request = new RefreshRequest(RefreshSourceUrls.Default, prior);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Pipeline(candidate, new StubAddressLoader(), new StubDns(), new StubAsn())
            .RunAsync(request, CancellationToken.None));
    }

    [Fact]
    public async Task HardDeadlineAndCancellationDoNotPublishLateResult()
    {
        var prior = Catalog("a.example");
        var hanging = new StubAddressLoader(hang: true);
        var pipeline = Pipeline(prior, hanging, new StubDns(), new StubAsn(), TimeSpan.FromMilliseconds(20));
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pipeline.RunAsync(new RefreshRequest(RefreshSourceUrls.Default, prior), CancellationToken.None));
        using var canceled = new CancellationTokenSource();
        canceled.Cancel();
        await Assert.ThrowsAnyAsync<OperationCanceledException>(() => pipeline.RunAsync(new RefreshRequest(RefreshSourceUrls.Default, prior), canceled.Token));
        Assert.Empty(prior.Services.Single().LiteAddresses);
    }

    [Fact]
    public async Task PartialDnsOutageKeepsOnlyApplicableCachedEvidence()
    {
        var oldDate = DateTimeOffset.UtcNow.AddDays(-2);
        var cached = new EnrichmentSnapshot(oldDate, "fixture", new Dictionary<string, ServiceEnrichment>
        {
            ["a"] = new("a", [IPv4Network.Parse("198.51.100.1")], [], ["a.example"], [], oldDate, oldDate, EnrichmentFreshness.Fresh)
        });
        var prior = Catalog("a.example");
        var pipeline = Pipeline(prior, new StubAddressLoader(), new FailingDns(), new StubAsn());
        var candidate = await pipeline.RunAsync(new RefreshRequest(RefreshSourceUrls.Default, prior, cached), CancellationToken.None);
        Assert.Equal(EnrichmentFreshness.Stale, candidate.Enrichment.Services["a"].Freshness);
        Assert.Contains(IPv4Network.Parse("198.51.100.1"), candidate.MatchedCatalog.Routes("a", ExportMode.Lite));
        Assert.Equal(EnrichmentFreshness.Fresh, cached.Services["a"].Freshness);
        var changed = await Pipeline(Catalog("changed.example"), new StubAddressLoader(), new FailingDns(), new StubAsn())
            .RunAsync(new RefreshRequest(RefreshSourceUrls.Default, prior, cached), CancellationToken.None);
        Assert.Empty(changed.Enrichment.Services["a"].DnsAddresses);
    }

    [Fact]
    public async Task AddedDomainKeepsOldEvidenceWithoutClaimingNewInputWasResolved()
    {
        var oldDate = DateTimeOffset.UtcNow.AddDays(-2);
        var cached = new EnrichmentSnapshot(oldDate, "fixture", new Dictionary<string, ServiceEnrichment>
        {
            ["a"] = new("a", [IPv4Network.Parse("198.51.100.1")], [], ["a.example"], [], oldDate, oldDate, EnrichmentFreshness.Fresh)
        });
        var expanded = new ServiceCatalog([new CatalogService("a", "A", "X", ["a.example", "new.example"], [], [])]);
        var candidate = await Pipeline(expanded, new StubAddressLoader(), new FailingDns(), new StubAsn())
            .RunAsync(new RefreshRequest(RefreshSourceUrls.Default, null, cached), CancellationToken.None);
        Assert.Equal(new[] { "a.example" }, candidate.Enrichment.Services["a"].DnsDomains);
        Assert.Equal(EnrichmentFreshness.Stale, candidate.Enrichment.Services["a"].Freshness);
    }

    [Theory]
    [InlineData(ExportMode.Targeted, false)]
    [InlineData(ExportMode.Lite, false)]
    [InlineData(ExportMode.Full, false)]
    [InlineData(ExportMode.Targeted, true)]
    [InlineData(ExportMode.Lite, true)]
    [InlineData(ExportMode.Full, true)]
    public async Task SuspiciousSourceAddressShrinkRejectsCandidateWithoutMutation(ExportMode shrinkingMode, bool useCountBaseline)
    {
        var prior = Catalog("a.example");
        var previous = new Dictionary<ExportMode, SourceSnapshot>
        {
            [shrinkingMode] = new(shrinkingMode, [IPv4Network.Parse("198.51.100.0/29")], [])
        };
        var loader = new SmallSourceLoader(shrinkingMode);
        var request = new RefreshRequest(RefreshSourceUrls.Default, prior,
            PreviousSourceSnapshots: useCountBaseline ? null : previous,
            PreviousSourceAddressCounts: useCountBaseline ? new Dictionary<ExportMode, ulong> { [shrinkingMode] = 8 } : null);
        await Assert.ThrowsAsync<InvalidOperationException>(() => Pipeline(prior, loader, new StubDns(), new StubAsn())
            .RunAsync(request, CancellationToken.None));
        Assert.Empty(prior.Services.Single().LiteAddresses);
    }

    [Fact]
    public async Task EquivalentSourceAddressCoverageDoesNotTriggerShrink()
    {
        var prior = Catalog("a.example");
        var previous = new Dictionary<ExportMode, SourceSnapshot>
        {
            [ExportMode.Lite] = new(ExportMode.Lite,
                [IPv4Network.Parse("198.51.100.0/25"), IPv4Network.Parse("198.51.100.128/25")], [])
        };
        var candidate = await Pipeline(prior, new StubAddressLoader(), new StubDns(), new StubAsn())
            .RunAsync(new RefreshRequest(RefreshSourceUrls.Default, prior,
                PreviousSourceSnapshots: previous), CancellationToken.None);
        Assert.True(candidate.SourceSnapshots.ContainsKey(ExportMode.Lite));
    }

    private static RefreshPipeline Pipeline(ServiceCatalog catalog, IAddressListLoader lists, IDomainResolver dns,
        IAsnPrefixLoader asn, TimeSpan? deadline = null) => new(new StubCatalogLoader(catalog), lists, lists, lists, dns, asn,
            deadline ?? TimeSpan.FromSeconds(60));

    private static ServiceCatalog Catalog(params string[] domains) => new(domains.Select((domain, i) =>
        new CatalogService(i == 0 ? "a" : $"a{i}", domain, "X", [domain], [], [])).ToArray());

    private sealed class StubCatalogLoader(ServiceCatalog catalog) : IServiceCatalogLoader
    {
        public Task<ServiceCatalog> LoadAsync(Uri uri, CancellationToken cancellationToken) => Task.FromResult(catalog);
    }

    private sealed class StubAddressLoader(ExportMode? failMode = null, bool hang = false) : IAddressListLoader
    {
        public async Task<SourceSnapshot> LoadAsync(Uri uri, ExportMode mode, CancellationToken cancellationToken)
        {
            if (hang) await Task.Delay(Timeout.InfiniteTimeSpan);
            if (mode == failMode) throw new HttpRequestException("source failure");
            IReadOnlyList<IPv4Network> routes = mode == ExportMode.Targeted ? [IPv4Network.Parse("198.51.100.1")] : [IPv4Network.Parse("198.51.100.0/24")];
            return new SourceSnapshot(mode, routes, mode == ExportMode.Targeted
                ? [new TargetedRoute("a.example", IPv4Network.Parse("198.51.100.1"))] : []);
        }
    }

    private sealed class SmallSourceLoader(ExportMode smallMode) : IAddressListLoader
    {
        public Task<SourceSnapshot> LoadAsync(Uri uri, ExportMode mode, CancellationToken cancellationToken)
        {
            IReadOnlyList<IPv4Network> routes = mode == smallMode
                ? [IPv4Network.Parse("198.51.100.1/32")]
                : [IPv4Network.Parse("198.51.100.0/24")];
            return Task.FromResult(new SourceSnapshot(mode, routes,
                mode == ExportMode.Targeted ? [new TargetedRoute("a.example", routes[0])] : []));
        }
    }

    private sealed class StubDns : IDomainResolver
    {
        public Task<IReadOnlyList<IPAddress>> ResolveIPv4Async(string domain, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<IPAddress>>([IPAddress.Parse("198.51.100.1")]);
    }

    private sealed class FailingDns : IDomainResolver
    {
        public Task<IReadOnlyList<IPAddress>> ResolveIPv4Async(string domain, CancellationToken cancellationToken) =>
            throw new HttpRequestException("DNS unavailable");
    }

    private sealed class StubAsn : IAsnPrefixLoader
    {
        public Task<IReadOnlyList<IPv4Network>> LoadAsync(int asn, CancellationToken cancellationToken) =>
            Task.FromResult<IReadOnlyList<IPv4Network>>([]);
    }
}
