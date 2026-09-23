using System.Net;
using IPList.Core.Catalog;
using IPList.Core.Networking;

namespace IPList.Core.Refresh;

public sealed class RefreshPipeline(
    IServiceCatalogLoader catalogLoader,
    IAddressListLoader targetedLoader,
    IAddressListLoader liteLoader,
    IAddressListLoader fullLoader,
    IDomainResolver domainResolver,
    IAsnPrefixLoader asnLoader,
    TimeSpan? overallDeadline = null,
    CatalogMatcher? matcher = null)
{
    private readonly TimeSpan _deadline = overallDeadline ?? TimeSpan.FromSeconds(60);
    private readonly CatalogMatcher _matcher = matcher ?? new CatalogMatcher();

    public static RefreshPipeline Live() => Live(HttpDataClient.CreateProduction());

    public static RefreshPipeline Live(HttpDataClient data) {
        ArgumentNullException.ThrowIfNull(data);
        var lists = new AddressListHttpLoader(data);
        return new RefreshPipeline(new ServiceCatalogHttpLoader(data), lists, lists, lists,
            new SystemDomainResolver(), new AsnPrefixAdapter(new RipeStatHttpLoader(data)));
    }

    public async Task<RefreshTransaction> RunAsync(RefreshRequest request, CancellationToken cancellationToken)
    {
        cancellationToken.ThrowIfCancellationRequested();
        using var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        try
        {
            return await BuildCandidateAsync(request, linked.Token).WaitAsync(_deadline, cancellationToken).ConfigureAwait(false);
        }
        catch (TimeoutException)
        {
            linked.Cancel();
            throw new OperationCanceledException("Refresh deadline exceeded; previous state remains unchanged.");
        }
        catch { linked.Cancel(); throw; }
    }

    private async Task<RefreshTransaction> BuildCandidateAsync(RefreshRequest request, CancellationToken cancellationToken)
    {
        var checks = new List<MatchDiagnostics>();
        var catalogTask = catalogLoader.LoadAsync(request.Urls.Metadata, cancellationToken);
        var targetedTask = targetedLoader.LoadAsync(request.Urls.Targeted, ExportMode.Targeted, cancellationToken);
        var liteTask = liteLoader.LoadAsync(request.Urls.Lite, ExportMode.Lite, cancellationToken);
        var fullTask = fullLoader.LoadAsync(request.Urls.Full, ExportMode.Full, cancellationToken);
        await Task.WhenAll(targetedTask, liteTask, fullTask).ConfigureAwait(false);
        ServiceCatalog catalog;
        try { catalog = await catalogTask.ConfigureAwait(false); }
        catch (Exception ex) when (ex is HttpRequestException ||
            ex is OperationCanceledException && !cancellationToken.IsCancellationRequested)
        {
            catalog = request.PreviousCatalog is { } previousCatalog
                ? previousCatalog with { Freshness = CatalogFreshness.Cached }
                : BundledCatalog.Load();
        }
        var metadataCount = catalog.Services.Count(IsMetadataService);
        if (request.PreviousCatalog is { } previous && metadataCount < Math.Ceiling(previous.Services.Count(IsMetadataService) * 0.7))
            throw new InvalidOperationException("Suspicious catalog shrink; previous state retained.");
        if (metadataCount == 0) throw new InvalidOperationException("Catalog is empty.");
        checks.Add(new MatchDiagnostics("metadata", "ok", $"{metadataCount} services"));
        var sources = new Dictionary<ExportMode, SourceSnapshot>
        {
            [ExportMode.Targeted] = await targetedTask.ConfigureAwait(false),
            [ExportMode.Lite] = await liteTask.ConfigureAwait(false),
            [ExportMode.Full] = await fullTask.ConfigureAwait(false)
        };
        ValidateSourceShrink(request, sources);
        foreach (var mode in Enum.GetValues<ExportMode>())
            checks.Add(new MatchDiagnostics(mode.ToString().ToLowerInvariant(), "ok", $"{sources[mode].Routes.Count} routes"));
        var now = request.Now ?? DateTimeOffset.UtcNow;
        var cache = request.CachedEvidence ?? BundledCatalog.LoadEvidence();
        var refreshed = await EnrichAsync(catalog, cache, now, checks,
            request.CachedEvidence is null, cancellationToken).ConfigureAwait(false);
        var matched = _matcher.Match(catalog, sources, refreshed);
        checks.Add(new MatchDiagnostics("matching", "ok", "Source unions verified"));
        return new RefreshTransaction(matched, refreshed, checks, sources, now);
    }

    private static bool IsMetadataService(CatalogService service) =>
        !service.Id.StartsWith("lib4u:", StringComparison.OrdinalIgnoreCase);

    private static void ValidateSourceShrink(RefreshRequest request,
        IReadOnlyDictionary<ExportMode, SourceSnapshot> sources)
    {
        foreach (var mode in Enum.GetValues<ExportMode>())
        {
            ulong previousCount = 0;
            if (request.PreviousSourceSnapshots?.TryGetValue(mode, out var previous) == true)
            {
                if (previous.Mode != mode) throw new InvalidOperationException("Previous source snapshot mode mismatch.");
                previousCount = AddressCount(previous.Routes);
            }
            if (request.PreviousSourceAddressCounts?.TryGetValue(mode, out var count) == true)
                previousCount = Math.Max(previousCount, count);
            if (previousCount > (1UL << 32)) throw new InvalidOperationException("Invalid previous IPv4 address count.");
            if (previousCount == 0) continue;
            var currentCount = AddressCount(sources[mode].Routes);
            // Match the Swift catalog's 50% shrink guard. Address coverage
            // avoids false alarms when equivalent CIDRs are split or collapsed.
            if (currentCount < (previousCount + 1) / 2)
                throw new InvalidOperationException($"Suspicious {mode} source shrink; previous state retained.");
        }
    }

    private static ulong AddressCount(IEnumerable<IPv4Network> routes) =>
        RouteSet.Normalize(routes).Aggregate(0UL, (total, route) => checked(total + route.AddressCount));

    private async Task<EnrichmentSnapshot> EnrichAsync(ServiceCatalog catalog, EnrichmentSnapshot cache,
        DateTimeOffset now, List<MatchDiagnostics> checks, bool usingBundledSnapshot,
        CancellationToken cancellationToken)
    {
        using var gate = new SemaphoreSlim(8, 8);
        var tasks = catalog.Services.Select(async service =>
        {
            var domains = service.Domains.Select(x => x.Trim().TrimEnd('.').ToLowerInvariant()).Distinct().Order().ToArray();
            var asns = service.Asns.Distinct().Order().ToArray();
            var old = cache.For(service.Id);
            var matchingDns = old is not null && domains.SequenceEqual(old.DnsDomains.Order(), StringComparer.Ordinal);
            var matchingAsn = old is not null && asns.SequenceEqual(old.AsnNumbers.Order());
            var compatibleDns = old is not null && (old.DnsDomains.Count > 0 || domains.Length == 0) &&
                old.DnsDomains.All(domain => domains.Contains(domain));
            var compatibleAsn = old is not null && (old.AsnNumbers.Count > 0 || asns.Length == 0) &&
                old.AsnNumbers.All(asn => asns.Contains(asn));
            var dnsFresh = matchingDns && old!.DnsUpdatedAt is { } dnsDate &&
                (now - dnsDate < TimeSpan.FromHours(24) || usingBundledSnapshot);
            var asnFresh = matchingAsn && old!.AsnUpdatedAt is { } asnDate &&
                (now - asnDate < TimeSpan.FromHours(24) || usingBundledSnapshot);
            IReadOnlyList<IPv4Network> dns = dnsFresh ? old!.DnsAddresses : [];
            IReadOnlyList<IPv4Network> prefixes = asnFresh ? old!.AsnPrefixes : [];
            var dnsStale = false;
            var asnStale = false;
            if (!dnsFresh && domains.Length > 0)
            {
                try
                {
                    var results = await Task.WhenAll(domains.Select(async domain =>
                    {
                        var values = await LimitedAsync(gate, ct => domainResolver.ResolveIPv4Async(domain, ct), cancellationToken).ConfigureAwait(false);
                        return values.Where(ip => ip.AddressFamily == System.Net.Sockets.AddressFamily.InterNetwork)
                            .Select(ip => IPv4Network.Parse(ip.ToString())).ToArray();
                    })).ConfigureAwait(false);
                    dns = RouteSet.Normalize(results.SelectMany(x => x));
                    if (dns.Count == 0 && compatibleDns && old!.DnsAddresses.Count > 0)
                    { dns = old.DnsAddresses; dnsStale = true; }
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
                catch
                {
                    dns = compatibleDns ? old!.DnsAddresses : [];
                    dnsStale = true;
                }
            }
            if (!asnFresh && asns.Length > 0)
            {
                try
                {
                    var results = await Task.WhenAll(asns.Select(async asn =>
                    {
                        if (asn > int.MaxValue) throw new FormatException("ASN exceeds resolver range.");
                        return await LimitedAsync(gate, ct => asnLoader.LoadAsync((int)asn, ct), cancellationToken).ConfigureAwait(false);
                    })).ConfigureAwait(false);
                    prefixes = RouteSet.Normalize(results.SelectMany(x => x));
                    if (prefixes.Count == 0 && compatibleAsn && old!.AsnPrefixes.Count > 0)
                    { prefixes = old.AsnPrefixes; asnStale = true; }
                }
                catch (OperationCanceledException) when (cancellationToken.IsCancellationRequested) { throw; }
                catch
                {
                    prefixes = compatibleAsn ? old!.AsnPrefixes : [];
                    asnStale = true;
                }
            }
            var carriedFreshness = old is not null &&
                (domains.Length == 0 ? old.DnsDomains.Count == 0 : dnsFresh) &&
                (asns.Length == 0 ? old.AsnNumbers.Count == 0 : asnFresh);
            return new ServiceEnrichment(service.Id, dns, prefixes,
                dnsStale && compatibleDns ? old!.DnsDomains : domains,
                asnStale && compatibleAsn ? old!.AsnNumbers : asns,
                dnsFresh || dnsStale && compatibleDns ? old?.DnsUpdatedAt : now,
                asnFresh || asnStale && compatibleAsn ? old?.AsnUpdatedAt : now,
                dnsStale || asnStale ? EnrichmentFreshness.Stale
                    : carriedFreshness ? old!.Freshness : EnrichmentFreshness.Fresh);
        }).ToArray();
        var results = await Task.WhenAll(tasks).ConfigureAwait(false);
        var evidence = results.ToDictionary(x => x.ServiceId, x => x, StringComparer.Ordinal);
        checks.Add(new MatchDiagnostics("DNS", evidence.Values.Any(x => x.Freshness == EnrichmentFreshness.Stale) ? "stale" : "ok", "DNS evidence evaluated"));
        checks.Add(new MatchDiagnostics("RIPEstat", evidence.Values.Any(x => x.Freshness == EnrichmentFreshness.Stale) ? "stale" : "ok", "ASN evidence evaluated"));
        return new EnrichmentSnapshot(now, "Windows system DNS and RIPEstat announced-prefixes", evidence);
    }

    private static async Task<T> LimitedAsync<T>(SemaphoreSlim gate, Func<CancellationToken, Task<T>> operation, CancellationToken cancellationToken)
    {
        await gate.WaitAsync(cancellationToken).ConfigureAwait(false);
        var linked = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
        linked.CancelAfter(TimeSpan.FromSeconds(12));
        Task<T> running;
        try { running = operation(linked.Token); }
        catch { linked.Dispose(); gate.Release(); throw; }
        _ = running.ContinueWith(_ => { linked.Dispose(); gate.Release(); },
            CancellationToken.None, TaskContinuationOptions.ExecuteSynchronously, TaskScheduler.Default);
        return await running.WaitAsync(TimeSpan.FromSeconds(12), cancellationToken).ConfigureAwait(false);
    }
}
