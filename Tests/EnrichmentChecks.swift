import Foundation
import Darwin

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

private final class AdvancingClock: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Date]

    init(_ values: [Date]) {
        self.values = values
    }

    func next() -> Date {
        lock.lock()
        defer { lock.unlock() }
        precondition(!values.isEmpty, "clock exhausted")
        return values.removeFirst()
    }
}

private final class RIPEStubProtocol: URLProtocol {
    static let lock = NSLock()
    static var body = Data()
    static var headers: [String: String] = [:]
    static var requestedURL: URL?
    static var requestedURLs: [URL] = []

    static func reset(body: Data, headers: [String: String] = [:]) {
        lock.lock()
        self.body = body
        self.headers = headers
        requestedURL = nil
        requestedURLs = []
        lock.unlock()
    }

    static func lastURL() -> URL? {
        lock.lock()
        defer { lock.unlock() }
        return requestedURL
    }

    static func allURLs() -> [URL] {
        lock.lock()
        defer { lock.unlock() }
        return requestedURLs
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let body = Self.body
        let headers = Self.headers
        Self.requestedURL = request.url
        if let url = request.url { Self.requestedURLs.append(url) }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: headers)!
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
        try testProducedFragmentsRespectSharedRepresentationLimit()
        try testTargetedEvidenceCarriesAcrossModesAndAddsConfirmedRoutes()
        try testTargetedAdditionsAreSafetyValidated()
        try testNormalizedDefaultRouteIsRejected()
        try await testFreshEvidenceSkipsNetworkRequests()
        try await testExpiredEvidenceIsRefreshed()
        try await testFailedRefreshKeepsLastSuccessfulEvidence()
        try await testChangedAndRemovedEvidenceInputsRetireObsoleteCache()
        try await testAddedEvidenceInputsKeepUnchangedCacheDuringOutage()
        try await testBundledEvidenceBootstrapsCleanInstall()
        try testBundledSnapshotPreservesProvenance()
        try await testRIPEStatUsesAnnouncedPrefixesEndpoint()
        try await testRIPEStatKeepsOnlyCurrentObservationPrefixes()
        try await testRIPEObservationAdvancesForEachRequest()
        try await testRIPEStatRejectsOversizedResponseBeforeDecode()
        try await testRIPEStatRejectsTooManyPrefixesBeforeRouteConstruction()
        testDNSCallbackCopiesIPv4BeforeReturning()
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

    // Shared fragments count once for every emitted service ownership. This
    // keeps the cap meaningful even when the unassigned complement is empty.
    private static func testProducedFragmentsRespectSharedRepresentationLimit() throws {
        let services = (0..<4).map { index in
            CatalogService(id: "owned-\(index)", name: "Owned \(index)")
        }
        let catalog = ServiceCatalog(services: services)
        let cache = EnrichmentSnapshot(generatedAt: .now, provenance: "fixture", entries: services.enumerated().map { index, service in
            ServiceEnrichment(serviceID: service.id, asnPrefixes: ["192.0.2.\(index)/32"])
        })
        do {
            _ = try CatalogMatcher(options: CatalogMatchOptions(maximumFragments: 1)).match(
                catalog: catalog, targeted: [] as [TargetedRoute], lite: ["192.0.2.0/30"], full: [], cached: cache
            )
            check(false, "fully owned output cannot bypass the representation cap")
        } catch let error as EnrichmentError {
            check(error == .fragmentLimitExceeded(1), "owned fragments use the same cap")
        }

        let exact = try CatalogMatcher(options: CatalogMatchOptions(maximumFragments: 4)).match(
            catalog: catalog, targeted: [] as [TargetedRoute], lite: ["192.0.2.0/30"], full: [], cached: cache
        )
        let emitted = services.flatMap { exact.routes(for: $0.id, mode: .lite) }
        check(emitted.count == 4, "the exact representation boundary is accepted")
        check(exact.unassignedRoutes[.lite] == [], "all four source addresses are owned")

        let shared = [
            CatalogService(id: "shared-a", name: "Shared A"),
            CatalogService(id: "shared-b", name: "Shared B")
        ]
        let sharedCache = EnrichmentSnapshot(generatedAt: .now, provenance: "fixture", entries: shared.map {
            ServiceEnrichment(serviceID: $0.id, asnPrefixes: ["198.51.100.7/32"])
        })
        do {
            _ = try CatalogMatcher(options: CatalogMatchOptions(maximumFragments: 1)).match(
                catalog: ServiceCatalog(services: shared), targeted: [] as [TargetedRoute],
                lite: ["198.51.100.7/32"], full: [], cached: sharedCache
            )
            check(false, "a shared fragment counts once for each service owner")
        } catch let error as EnrichmentError {
            check(error == .fragmentLimitExceeded(1), "shared ownership uses the documented cap policy")
        }
    }

    // A direct domain binding from targeted remains evidence in Lite and Full;
    // targeted additionally exposes confirmed DNS and explicit catalog CIDRs.
    private static func testTargetedEvidenceCarriesAcrossModesAndAddsConfirmedRoutes() throws {
        let service = CatalogService(id: "service", name: "Service", domains: ["s.example"], ipRanges: ["203.0.113.0/24"])
        let cache = EnrichmentSnapshot(generatedAt: .now, provenance: "fixture", entries: [
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["198.51.100.8"])
        ])
        let matched = try CatalogMatcher().match(
            catalog: ServiceCatalog(services: [service]),
            targeted: [TargetedRoute(domain: "s.example", address: "192.0.2.7")],
            lite: ["192.0.2.0/24"],
            full: ["192.0.2.0/24"],
            cached: cache
        )
        check(matched.routes(for: service.id, mode: .targeted) == ["192.0.2.7/32", "198.51.100.8/32", "203.0.113.0/24"],
              "targeted adds confirmed DNS and explicit CIDRs outside the old source")
        check(matched.routes(for: service.id, mode: .lite) == ["192.0.2.7/32"],
              "targeted domain evidence partitions Lite")
        check(matched.routes(for: service.id, mode: .full) == ["192.0.2.7/32"],
              "targeted domain evidence partitions Full")
        check(addresses(in: matched.unassignedRoutes[.lite] ?? []).count == 255, "Lite keeps its precise remainder")
        check(addresses(in: matched.unassignedRoutes[.full] ?? []).count == 255, "Full keeps its precise remainder")
    }

    // Targeted additions are published outside the old targeted universe, so
    // they must receive the same semantic default/private-range checks.
    private static func testTargetedAdditionsAreSafetyValidated() throws {
        func catalog(_ ranges: [String]) -> ServiceCatalog {
            ServiceCatalog(services: [CatalogService(id: "targeted-safety", name: "Targeted safety", ipRanges: ranges)])
        }
        for ranges in [["0.0.0.0/0"], ["0.0.0.0/1", "128.0.0.0/1"]] {
            do {
                _ = try CatalogMatcher().match(
                    catalog: catalog(ranges), targeted: [] as [TargetedRoute], lite: [], full: [], cached: nil
                )
                check(false, "targeted default-route additions must be rejected")
            } catch let error as EnrichmentError {
                check(error == .rejectedDefaultRoute, "targeted additions reject semantic defaults")
            }
        }
        do {
            _ = try CatalogMatcher(options: CatalogMatchOptions(forbiddenSourceRoutes: ["10.0.0.0/8"])).match(
                catalog: catalog(["10.0.0.0/24"]), targeted: [] as [TargetedRoute], lite: [], full: [], cached: nil
            )
            check(false, "targeted forbidden additions must be rejected")
        } catch let error as EnrichmentError {
            check(error == .forbiddenSourceRoute("10.0.0.0/24"), "targeted additions respect configured forbidden routes")
        }
    }

    // CIDR normalization must apply before the default-route safety guard.
    private static func testNormalizedDefaultRouteIsRejected() throws {
        do {
            _ = try CatalogMatcher().match(
                catalog: ServiceCatalog(services: []), targeted: [] as [TargetedRoute],
                lite: ["0.0.0.0/1", "128.0.0.0/1"], full: [], cached: nil
            )
            check(false, "a split default route must be rejected")
        } catch let error as EnrichmentError {
            check(error == .rejectedDefaultRoute, "normalized default route is rejected")
        }
    }

    // This catches a refresh that needlessly sends every catalog domain over
    // the network although its evidence is still inside the configured TTL.
    private static func testFreshEvidenceSkipsNetworkRequests() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = CatalogService(id: "cached", name: "Cached", domains: ["cached.example"], asn: [64500])
        let cached = EnrichmentSnapshot(generatedAt: now, provenance: "fixture", entries: [
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["192.0.2.8"], asnPrefixes: ["192.0.2.0/24"],
                              dnsDomains: service.domains, asnNumbers: service.asn,
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
                              dnsDomains: service.domains, asnNumbers: service.asn,
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
                              dnsDomains: service.domains, asnNumbers: service.asn,
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

    // A timestamp alone cannot make evidence reusable: it must have been
    // generated for the unchanged DNS and ASN inputs. Removed inputs retire
    // their old addresses instead of preserving them as a false success.
    private static func testChangedAndRemovedEvidenceInputsRetireObsoleteCache() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = CatalogService(id: "identity", name: "Identity", domains: ["old.example"], asn: [64509])
        let cache = EnrichmentSnapshot(generatedAt: now, provenance: "fixture", entries: [
            ServiceEnrichment(
                serviceID: old.id,
                dnsAddresses: ["192.0.2.1"],
                asnPrefixes: ["192.0.2.0/24"],
                dnsDomains: old.domains,
                asnNumbers: old.asn,
                dnsUpdatedAt: now,
                asnUpdatedAt: now
            )
        ])
        let updated = CatalogService(id: old.id, name: old.name, domains: ["new.example"], asn: [64510])
        let dns = StubDNS(["new.example": ["198.51.100.9"]])
        let asn = StubASN([64510: ["198.51.100.0/24"]])
        let refreshed = try await ServiceEnricher(dns: dns, asn: asn, limits: EnrichmentLimits(cacheTTL: 3_600))
            .enrich(catalog: ServiceCatalog(services: [updated]), cached: cache, now: now)
        let dnsRequests = await dns.recordedRequests()
        let asnRequests = await asn.recordedRequests()
        check(dnsRequests == ["new.example"], "changed domain is refreshed")
        check(asnRequests == [64510], "changed ASN is refreshed")
        check(refreshed.snapshot[old.id]?.dnsAddresses == ["198.51.100.9/32"], "old DNS evidence is retired")
        check(refreshed.snapshot[old.id]?.asnPrefixes == ["198.51.100.0/24"], "old ASN evidence is retired")

        let removed = CatalogService(id: old.id, name: old.name)
        let retired = try await ServiceEnricher(dns: dns, asn: asn, limits: EnrichmentLimits(cacheTTL: 0))
            .enrich(catalog: ServiceCatalog(services: [removed]), cached: refreshed.snapshot, now: now.addingTimeInterval(1_000_000))
        check(retired.snapshot[old.id]?.dnsAddresses.isEmpty == true, "removed domains retire cached DNS evidence")
        check(retired.snapshot[old.id]?.asnPrefixes.isEmpty == true, "removed ASNs retire cached ASN evidence")
        check(retired.snapshot[old.id]?.dnsDomains.isEmpty == true, "DNS input identity records removal")
        check(retired.snapshot[old.id]?.asnNumbers.isEmpty == true, "ASN input identity records removal")
    }

    // Adding inputs must retry them, but an outage cannot erase evidence from
    // existing domain/ASN inputs that remain in the catalog.
    private static func testAddedEvidenceInputsKeepUnchangedCacheDuringOutage() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let old = CatalogService(id: "addition", name: "Addition", domains: ["existing.example"], asn: [64520])
        let cache = EnrichmentSnapshot(generatedAt: now, provenance: "fixture", entries: [
            ServiceEnrichment(
                serviceID: old.id,
                dnsAddresses: ["192.0.2.1"],
                asnPrefixes: ["192.0.2.0/24"],
                dnsDomains: old.domains,
                asnNumbers: old.asn,
                dnsUpdatedAt: now,
                asnUpdatedAt: now
            )
        ])
        let updated = CatalogService(
            id: old.id, name: old.name,
            domains: ["existing.example", "added.example"],
            asn: [64520, 64521]
        )
        let dns = StubDNS([:], failures: Set(updated.domains))
        let asn = StubASN([:], failures: Set(updated.asn))
        let result = try await ServiceEnricher(dns: dns, asn: asn, limits: EnrichmentLimits(cacheTTL: 3_600))
            .enrich(catalog: ServiceCatalog(services: [updated]), cached: cache, now: now)
        check(result.snapshot[old.id]?.dnsAddresses == ["192.0.2.1"], "unchanged domain evidence survives an added-domain outage")
        check(result.snapshot[old.id]?.asnPrefixes == ["192.0.2.0/24"], "unchanged ASN evidence survives an added-ASN outage")
        check(result.snapshot[old.id]?.freshness == .stale, "addition outage remains visibly stale")
        let dnsRequests = await dns.recordedRequests()
        let asnRequests = await asn.recordedRequests()
        check(Set(dnsRequests) == Set(updated.domains), "all domains including the addition are retried")
        check(Set(asnRequests) == Set(updated.asn), "all ASNs including the addition are retried")
    }

    // This catches a clean-install path that ignores the shipped evidence and
    // starts by resolving every domain before it can construct a catalog.
    private static func testBundledEvidenceBootstrapsCleanInstall() async throws {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let service = CatalogService(id: "bundled", name: "Bundled", domains: ["bundled.example"], asn: [64503])
        let bundled = EnrichmentSnapshot(generatedAt: now, provenance: "bundled fixture", entries: [
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["192.0.2.42"], asnPrefixes: ["192.0.2.0/24"],
                              dnsDomains: service.domains, asnNumbers: service.asn,
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
        check(result.snapshot.provenance == "cache-only; base=bundled fixture", "cache-only bundle retains its provenance")
        check(dnsRequests.isEmpty, "bundled DNS avoids first-run request")
        check(asnRequests.isEmpty, "bundled ASN avoids first-run request")
    }

    // This catches a bundled-resource path that drops the provenance or
    // per-source timestamps needed to decide whether clean-install evidence is stale.
    private static func testBundledSnapshotPreservesProvenance() throws {
        let data = Data(#"{"generatedAt":1700000000,"provenance":"system DNS + RIPEstat","services":{"bundled":{"serviceID":"bundled","dnsAddresses":["192.0.2.42"],"asnPrefixes":["192.0.2.0/24"],"dnsDomains":["bundled.example"],"asnNumbers":[64503],"dnsUpdatedAt":1700000000,"asnUpdatedAt":1700000000,"freshness":"fresh"}}}"#.utf8)
        let snapshot = try EnrichmentSnapshot.decodeBundled(data)
        check(snapshot.provenance == "system DNS + RIPEstat", "bundled provenance")
        check(snapshot["bundled"]?.freshness == .bundled, "bundled source is visibly distinct from a refresh")
        check(snapshot["bundled"]?.dnsDomains == ["bundled.example"], "bundled cache identity")
        check(snapshot["bundled"]?.dnsUpdatedAt == Date(timeIntervalSince1970: 1_700_000_000), "bundled timestamp")

        let bundledURL = URL(fileURLWithPath: "Resources/ThirdParty/enrichment-snapshot.json")
        let bundledFile = try EnrichmentSnapshot.decodeBundled(Data(contentsOf: bundledURL))
        check(bundledFile.services.count == 275, "checked-in bundled evidence decodes")
        check(bundledFile["pincetgore/amnezia-app-ru-list:2гис"]?.freshness == .bundled,
              "checked-in fresh evidence is identified as bundled")
        check(bundledFile["pincetgore/amnezia-app-ru-list:2гис"]?.dnsDomains.isEmpty == false,
              "checked-in bundle binds evidence to catalog inputs")
    }

    // This catches a client that substitutes a different ASN data source or
    // includes IPv6/malformed strings in an IPv4 route-matching result.
    private static func testRIPEStatUsesAnnouncedPrefixesEndpoint() async throws {
        let body = Data(#"{"data":{"query_endtime":"2026-09-19T00:00:00","prefixes":[{"prefix":"192.0.2.17/24","timelines":[{"starttime":"2026-09-19T00:00:00","endtime":"2026-09-19T00:00:00"}]},{"prefix":"2001:db8::/32","timelines":[{"starttime":"2026-09-19T00:00:00","endtime":"2026-09-19T00:00:00"}]},{"prefix":"invalid","timelines":[{"starttime":"2026-09-19T00:00:00","endtime":"2026-09-19T00:00:00"}]}]}}"#.utf8)
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

    // A prefix seen only before the request's observation time must not be
    // treated as current ASN evidence.
    private static func testRIPEStatKeepsOnlyCurrentObservationPrefixes() async throws {
        let body = Data(#"{"data":{"query_endtime":"2026-09-19T00:00:00","prefixes":[{"prefix":"192.0.2.0/24","timelines":[{"starttime":"2026-09-01T00:00:00","endtime":"2026-09-06T00:00:00"}]},{"prefix":"198.51.100.0/24","timelines":[{"starttime":"2026-09-18T00:00:00","endtime":"2026-09-19T00:00:00"}]}]}}"#.utf8)
        RIPEStubProtocol.reset(body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RIPEStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let observation = Date(timeIntervalSince1970: 1_789_776_000)
        let prefixes = try await RIPEStatASNPrefixLoader(session: session, observationTime: observation, observationWindow: 3_600)
            .announcedPrefixes(for: 64511, timeout: 1)
        check(prefixes == ["198.51.100.0/24"], "only timelines covering the current observation are accepted")
        let query = URLComponents(url: RIPEStubProtocol.lastURL()!, resolvingAgainstBaseURL: false)?.queryItems ?? []
        check(query.contains(URLQueryItem(name: "endtime", value: "2026-09-19T00:00:00Z")), "RIPE query fixes its observation time")
    }

    // A retained loader refreshes over time, so the default observation must be
    // read at each request rather than captured when the client is constructed.
    private static func testRIPEObservationAdvancesForEachRequest() async throws {
        let body = Data(#"{"data":{"query_endtime":"2026-09-19T01:00:00","prefixes":[{"prefix":"198.51.100.0/24","timelines":[{"starttime":"2026-09-19T00:00:00","endtime":"2026-09-19T02:00:00"}]}]}}"#.utf8)
        RIPEStubProtocol.reset(body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RIPEStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let clock = AdvancingClock([
            Date(timeIntervalSince1970: 1_789_776_000),
            Date(timeIntervalSince1970: 1_789_779_600)
        ])
        let loader = RIPEStatASNPrefixLoader(session: session, observationClock: { clock.next() })
        _ = try await loader.announcedPrefixes(for: 64514, timeout: 1)
        _ = try await loader.announcedPrefixes(for: 64514, timeout: 1)
        let urls = RIPEStubProtocol.allURLs()
        check(urls.count == 2, "two refreshes reached RIPEstat")
        let ends = urls.compactMap { url in
            URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?
                .first(where: { $0.name == "endtime" })?.value
        }
        check(ends == ["2026-09-19T00:00:00Z", "2026-09-19T01:00:00Z"], "RIPE observation advances per request")
    }

    // The client must reject Content-Length before buffering or decoding a
    // response that exceeds the 4 MiB defensive response limit.
    private static func testRIPEStatRejectsOversizedResponseBeforeDecode() async throws {
        let padding = String(repeating: "x", count: 5 * 1_024 * 1_024)
        let body = Data(#"{"data":{"prefixes":[{"prefix":"192.0.2.0/24"}]},"padding":"\#(padding)"}"#.utf8)
        RIPEStubProtocol.reset(body: body, headers: ["Content-Length": String(body.count)])
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RIPEStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await RIPEStatASNPrefixLoader(session: session).announcedPrefixes(for: 64512, timeout: 1)
            check(false, "oversized RIPE response must fail before JSON construction")
        } catch let error as EnrichmentError {
            check(error == .ripeResponseTooLarge, "oversized response reports the defensive limit")
        }
    }

    // Prefix records have an independent cap so a valid-but-enormous JSON
    // response cannot allocate an unbounded route collection under 4 MiB.
    private static func testRIPEStatRejectsTooManyPrefixesBeforeRouteConstruction() async throws {
        let body = Data(#"{"data":{"query_endtime":"2026-09-19T00:00:00","prefixes":[{"prefix":"192.0.2.0/24","timelines":[{"starttime":"2026-09-19T00:00:00","endtime":"2026-09-19T00:00:00"}]},{"prefix":"198.51.100.0/24","timelines":[{"starttime":"2026-09-19T00:00:00","endtime":"2026-09-19T00:00:00"}]}]}}"#.utf8)
        RIPEStubProtocol.reset(body: body)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RIPEStubProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await RIPEStatASNPrefixLoader(session: session, maximumPrefixCount: 1)
                .announcedPrefixes(for: 64513, timeout: 1)
            check(false, "too many RIPE prefixes must fail before CIDR construction")
        } catch let error as EnrichmentError {
            check(error == .tooManyRIPEPrefixes(2), "prefix-count limit is explicit")
        }
    }

    private static func testLiveSystemDNSResolver() async throws {
        guard ProcessInfo.processInfo.environment["IPLIST_LIVE_TEST"] == "1" else { return }
        let addresses = try await SystemDNSResolver().ipv4Addresses(for: "aeroflot.ru", timeout: 12)
        check(!addresses.isEmpty, "system DNS resolves Aeroflot without public DoH")
    }

    // This catches callback handling that retains DNS-SD's temporary sockaddr
    // pointer and reads it later on another queue.
    private static func testDNSCallbackCopiesIPv4BeforeReturning() {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = UInt32(0xD4C1990E).bigEndian
        let rendered = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemDNSIPv4Address($0) }
        }
        check(rendered == "212.193.153.14/32", "callback sockaddr is copied while valid")
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
            ServiceEnrichment(serviceID: service.id, dnsAddresses: ["203.0.113.11"], dnsDomains: service.domains,
                              dnsUpdatedAt: now.addingTimeInterval(-10))
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
