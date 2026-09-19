import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

private func addresses(in routes: [String]) -> Set<UInt32> {
    var result: Set<UInt32> = []
    for route in routes {
        guard let network = IPv4Network(route) else { continue }
        for offset in 0..<UInt32(network.addressCount) {
            result.insert(network.network + offset)
        }
    }
    return result
}

private enum StubFailure: Error {
    case unavailable
}

private actor StubDNS: DomainResolving {
    private let values: [String: [String]]
    private let failures: Set<String>
    private var requests: [String] = []

    init(_ values: [String: [String]], failures: Set<String> = []) {
        self.values = values
        self.failures = failures
    }

    func ipv4Addresses(for domain: String, timeout: TimeInterval) async throws -> [String] {
        requests.append(domain)
        if failures.contains(domain) { throw StubFailure.unavailable }
        return values[domain, default: []]
    }

    func recordedRequests() -> [String] { requests }
}

private actor StubASN: ASNPrefixLoading {
    private let values: [Int: [String]]
    private let failures: Set<Int>
    private var requests: [Int] = []

    init(_ values: [Int: [String]], failures: Set<Int> = []) {
        self.values = values
        self.failures = failures
    }

    func announcedPrefixes(for asn: Int, timeout: TimeInterval) async throws -> [String] {
        requests.append(asn)
        if failures.contains(asn) { throw StubFailure.unavailable }
        return values[asn, default: []]
    }

    func recordedRequests() -> [Int] { requests }
}

private actor DelayedDNS: DomainResolving {
    private let delay: Duration
    private var active = 0
    private var maximumActive = 0

    init(delay: Duration) {
        self.delay = delay
    }

    func ipv4Addresses(for domain: String, timeout: TimeInterval) async throws -> [String] {
        active += 1
        maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        try await Task.sleep(for: delay)
        return ["198.51.100.7"]
    }

    func peakConcurrency() -> Int { maximumActive }
}

private final class RIPEStubProtocol: URLProtocol {
    static let lock = NSLock()
    static var body = Data()
    static var requestedURL: URL?

    static func reset(body: Data) {
        lock.lock()
        self.body = body
        requestedURL = nil
        lock.unlock()
    }

    static func lastURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return requestedURL
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let body = Self.body
        Self.requestedURL = request.url
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main
struct EnrichmentChecks {
    static func main() async throws {
        try await testEvidenceOnlyOwnsExactSourceIntersections()
        try await testFreshEvidenceSkipsNetworkRequests()
        try await testExpiredEvidenceIsRefreshed()
        try await testFailedRefreshKeepsLastSuccessfulEvidence()
        try await testBundledEvidenceBootstrapsCleanInstall()
        try await testRIPEStatUsesAnnouncedPrefixesEndpoint()
        try await testLiveSystemDNSResolver()
        try await testRefreshHonorsRequestConcurrencyLimit()
        try await testExpiredRefreshUsesDeadlineAndKeepsCache()
        print("Enrichment checks passed")
    }

    // This catches a matcher that assigns an entire source /24 to a service
    // after it finds a single DNS address inside that source network.
    private static func testEvidenceOnlyOwnsExactSourceIntersections() async throws {
        let aeroflot = CatalogService(
            id: "aeroflot",
            name: "Аэрофлот",
            domains: ["aeroflot.ru"],
            asn: [34571]
        )
        let shared = CatalogService(
            id: "shared",
            name: "Общий адрес",
            domains: ["shared.example"]
        )
        let dns = StubDNS([
            "aeroflot.ru": ["212.193.153.14"],
            "shared.example": ["212.193.153.14"]
        ])
        let asn = StubASN([34571: ["195.209.0.0/17"]])
        let evidence = try await ServiceEnricher(dns: dns, asn: asn).enrich(
            catalog: ServiceCatalog(services: [aeroflot, shared]),
            cached: nil,
            now: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let matched = try CatalogMatcher().match(
            catalog: ServiceCatalog(services: [aeroflot, shared]),
            targeted: [TargetedRoute(domain: "aeroflot.ru", address: "212.193.153.14")],
            lite: ["212.193.153.0/24"],
            full: ["195.209.0.0/16"],
            cached: evidence.snapshot
        )

        check(matched.routes(for: "aeroflot", mode: .targeted) == ["212.193.153.14/32"], "targeted Aeroflot route")
        check(matched.routes(for: "aeroflot", mode: .lite) == ["212.193.153.14/32"], "a /32 must not widen inside Lite /24")
        check(matched.routes(for: "shared", mode: .lite) == ["212.193.153.14/32"], "shared evidence is retained")
        check(matched.routes(for: "aeroflot", mode: .full) == ["195.209.0.0/17"], "ASN intersection")
        check(matched.unassignedRoutes[.lite] != nil, "Lite remainder is visible")
        check(matched.unassignedRoutes[.full] == ["195.209.128.0/17"], "Full remainder")

        let liteSource = addresses(in: ["212.193.153.0/24"])
        let liteReconstructed = addresses(in: matched.routes(for: "aeroflot", mode: .lite))
            .union(addresses(in: matched.routes(for: "shared", mode: .lite)))
            .union(addresses(in: matched.unassignedRoutes[.lite] ?? []))
        check(liteReconstructed == liteSource, "Lite IP-set equality")
        check(liteReconstructed.count == 256, "all 256 Lite addresses remain represented")
        let dnsRequests = await dns.recordedRequests()
        let asnRequests = await asn.recordedRequests()
        check(dnsRequests.sorted() == ["aeroflot.ru", "shared.example"], "DNS was injected")
        check(asnRequests == [34571], "ASN was injected")
    }

    // This catches a refresh that needlessly sends every catalog domain over
    // the network although its evidence is still inside the configured TTL.
    private static func testFreshEvidenceSkipsNetworkRequests() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = CatalogService(id: "cached", name: "Cached", domains: ["cached.example"], asn: [64500])
        let cached = EnrichmentSnapshot(generatedAt: now, provenance: "fixture", entries: [
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["192.0.2.8"], asnPrefixes: ["192.0.2.0/24"],
                              dnsUpdatedAt: now.addingTimeInterval(-60), asnUpdatedAt: now.addingTimeInterval(-60))
        ])
        let dns = StubDNS([:])
        let asn = StubASN([:])
        let result = try await ServiceEnricher(dns: dns, asn: asn, limits: EnrichmentLimits(cacheTTL: 3_600))
            .enrich(catalog: ServiceCatalog(services: [service]), cached: cached, now: now)
        let dnsRequests = await dns.recordedRequests()
        let asnRequests = await asn.recordedRequests()
        check(result.snapshot[service.id]?.dnsAddresses == ["192.0.2.8"], "fresh DNS cache survives")
        check(result.snapshot[service.id]?.asnPrefixes == ["192.0.2.0/24"], "fresh ASN cache survives")
        check(dnsRequests.isEmpty, "fresh DNS evidence must not call the network")
        check(asnRequests.isEmpty, "fresh ASN evidence must not call the network")
    }

    // This catches a cache implementation that never renews old evidence.
    private static func testExpiredEvidenceIsRefreshed() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = CatalogService(id: "expired", name: "Expired", domains: ["expired.example"], asn: [64501])
        let cached = EnrichmentSnapshot(generatedAt: now.addingTimeInterval(-7_200), provenance: "fixture", entries: [
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["192.0.2.8"], asnPrefixes: ["192.0.2.0/24"],
                              dnsUpdatedAt: now.addingTimeInterval(-7_200), asnUpdatedAt: now.addingTimeInterval(-7_200))
        ])
        let dns = StubDNS(["expired.example": ["198.51.100.9"]])
        let asn = StubASN([64501: ["198.51.100.0/24"]])
        let result = try await ServiceEnricher(dns: dns, asn: asn, limits: EnrichmentLimits(cacheTTL: 3_600))
            .enrich(catalog: ServiceCatalog(services: [service]), cached: cached, now: now)
        let dnsRequests = await dns.recordedRequests()
        let asnRequests = await asn.recordedRequests()
        check(result.snapshot[service.id]?.dnsAddresses == ["198.51.100.9/32"], "expired DNS evidence refreshes")
        check(result.snapshot[service.id]?.asnPrefixes == ["198.51.100.0/24"], "expired ASN evidence refreshes")
        check(dnsRequests == ["expired.example"], "expired DNS calls the resolver")
        check(asnRequests == [64501], "expired ASN calls RIPEstat")
    }

    // This catches an error path that replaces a nonempty last-known-good
    // mapping with an empty response from a failed DNS or RIPEstat request.
    private static func testFailedRefreshKeepsLastSuccessfulEvidence() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = CatalogService(id: "failed", name: "Failed", domains: ["failed.example"], asn: [64502])
        let cached = EnrichmentSnapshot(generatedAt: now.addingTimeInterval(-7_200), provenance: "fixture", entries: [
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["203.0.113.10"], asnPrefixes: ["203.0.113.0/24"],
                              dnsUpdatedAt: now.addingTimeInterval(-7_200), asnUpdatedAt: now.addingTimeInterval(-7_200))
        ])
        let dns = StubDNS([:], failures: ["failed.example"])
        let asn = StubASN([:], failures: [64502])
        let result = try await ServiceEnricher(dns: dns, asn: asn, limits: EnrichmentLimits(cacheTTL: 3_600))
            .enrich(catalog: ServiceCatalog(services: [service]), cached: cached, now: now)
        let evidence = result.snapshot[service.id]
        check(evidence?.dnsAddresses == ["203.0.113.10"], "DNS failure retains nonempty evidence")
        check(evidence?.asnPrefixes == ["203.0.113.0/24"], "RIPEstat failure retains nonempty evidence")
        check(evidence?.freshness == .stale, "failed refresh is visibly stale")
        check(result.diagnostics.filter { $0.freshness == .stale }.count == 2, "both failures are diagnosed")
    }

    // This catches a clean-install path that ignores the shipped evidence and
    // starts by resolving every domain before it can construct a catalog.
    private static func testBundledEvidenceBootstrapsCleanInstall() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = CatalogService(id: "bundled", name: "Bundled", domains: ["bundled.example"], asn: [64503])
        let bundled = EnrichmentSnapshot(generatedAt: now, provenance: "bundled fixture", entries: [
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["192.0.2.42"], asnPrefixes: ["192.0.2.0/24"],
                              dnsUpdatedAt: now, asnUpdatedAt: now, freshness: .bundled)
        ])
        let dns = StubDNS([:])
        let asn = StubASN([:])
        let result = try await ServiceEnricher(dns: dns, asn: asn, bundled: bundled, limits: EnrichmentLimits(cacheTTL: 3_600))
            .enrich(catalog: ServiceCatalog(services: [service]), cached: nil, now: now)
        let dnsRequests = await dns.recordedRequests()
        let asnRequests = await asn.recordedRequests()
        check(result.snapshot[service.id]?.dnsAddresses == ["192.0.2.42"], "bundled DNS evidence loads")
        check(result.snapshot[service.id]?.freshness == .bundled, "bundled provenance survives")
        check(dnsRequests.isEmpty, "bundled DNS avoids first-run request")
        check(asnRequests.isEmpty, "bundled ASN avoids first-run request")
    }

    // This catches a client that substitutes a different ASN data source or
    // includes IPv6/malformed strings in an IPv4 route-matching result.
    private static func testRIPEStatUsesAnnouncedPrefixesEndpoint() async throws {
        let body = Data(#"{"data":{"prefixes":[{"prefix":"192.0.2.17/24"},{"prefix":"2001:db8::/32"},{"prefix":"invalid"}]}}"#.utf8)
        RIPEStubProtocol.reset(body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RIPEStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let prefixes = try await RIPEStatASNPrefixLoader(session: session).announcedPrefixes(for: 34571, timeout: 1)
        let url = RIPEStubProtocol.lastURL()
        check(prefixes == ["192.0.2.0/24"], "only normalized announced IPv4 prefixes are returned")
        check(url?.host == "stat.ripe.net", "RIPEstat host")
        check(url?.path == "/data/announced-prefixes/data.json", "official announced-prefixes endpoint")
        check(URLComponents(url: url!, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "resource", value: "AS34571")) == true,
              "request identifies the ASN as AS34571")
    }

    private static func testLiveSystemDNSResolver() async throws {
        guard ProcessInfo.processInfo.environment["IPLIST_LIVE_TEST"] == "1" else { return }
        let addresses = try await SystemDNSResolver().ipv4Addresses(for: "aeroflot.ru", timeout: 12)
        check(!addresses.isEmpty, "system DNS resolves Aeroflot without public DoH")
    }

    // This catches sequential fan-out: a large catalog must use the bounded
    // concurrency configured for the refresh, rather than one DNS query at a time.
    private static func testRefreshHonorsRequestConcurrencyLimit() async throws {
        let services = (0..<4).map { index in
            CatalogService(id: "parallel-\(index)", name: "Parallel \(index)", domains: ["parallel-\(index).example"])
        }
        let dns = DelayedDNS(delay: .milliseconds(70))
        _ = try await ServiceEnricher(
            dns: dns,
            asn: StubASN([:]),
            limits: EnrichmentLimits(maximumConcurrentRequests: 2, perRequestTimeout: 1, overallTimeout: 2)
        ).enrich(catalog: ServiceCatalog(services: services), cached: nil)
        let peakConcurrency = await dns.peakConcurrency()
        check(peakConcurrency == 2, "DNS fan-out obeys and uses the configured limit")
    }

    // This catches a refresh that waits forever on a resolver which ignores a
    // resource timeout. It must return the previous evidence as stale instead.
    private static func testExpiredRefreshUsesDeadlineAndKeepsCache() async throws {
        let now = Date()
        let service = CatalogService(id: "deadline", name: "Deadline", domains: ["deadline.example"])
        let cached = EnrichmentSnapshot(generatedAt: now.addingTimeInterval(-10), provenance: "fixture", entries: [
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["203.0.113.11"], dnsUpdatedAt: now.addingTimeInterval(-10))
        ])
        let started = ContinuousClock.now
        let result = try await ServiceEnricher(
            dns: DelayedDNS(delay: .milliseconds(250)),
            asn: StubASN([:]),
            limits: EnrichmentLimits(perRequestTimeout: 0.02, overallTimeout: 0.04, cacheTTL: 0)
        ).enrich(catalog: ServiceCatalog(services: [service]), cached: cached, now: now)
        let elapsed = started.duration(to: .now)
        check(elapsed < .milliseconds(120), "overall timeout bounds a slow resolver")
        check(result.snapshot[service.id]?.dnsAddresses == ["203.0.113.11"], "deadline retains cached DNS evidence")
        check(result.snapshot[service.id]?.freshness == .stale, "deadline result is stale")
    }
}
