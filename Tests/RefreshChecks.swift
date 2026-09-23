import Foundation
import Dispatch

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

@main
struct RefreshChecks {
    static func main() async throws {
        try await testSuccessfulRefreshReplacesEveryModeAndUsesCustomURLs()
        try await testTargetedOnlyDomainBecomesSelectableService()
        try await testFailedSourceDoesNotMutateWorkingState()
        try await testFailedSourceReportsEveryRouteSource()
        try await testSuspiciousCatalogShrinkDoesNotMutateWorkingState()
        try await testSyntheticServicesDoNotTriggerMetadataShrink()
        try await testCachedPartialEnrichmentCanCommit()
        try await testBundledEvidenceBootstrapsFirstRefresh()
        try await testOverallDeadlineDoesNotMutateWorkingState()
        try await testUncooperativeSourceCannotDelayDeadline()
        try await testFragmentLimitDoesNotMutateWorkingState()
        try await testCancelledRefreshDoesNotMutateWorkingState()
        try await testCancellationDoesNotAwaitUncooperativeSource()
        try await testRefreshCommitsRawSourceSnapshotsAtomically()
        try await testPartitionedUnchangedSourceHasNoRawRouteChange()
        try testPreMigrationBackupIsRawAndCreatedOnlyOnce()
        try testPreMigrationBackupDoesNotReplaceV11Backup()
        print("Refresh checks passed")
    }

    private static func testTargetedOnlyDomainBecomesSelectableService() async throws {
        let pipeline = RefreshPipeline(dependencies: RefreshPipelineDependencies(
            loadCatalog: { _ in ServiceCatalog(services: [CatalogService(id: "known", name: "Known", domains: ["known.example"])]) },
            loadTargeted: { _ in [TargetedRoute(domain: "source-only.example", address: "192.0.2.44")] },
            loadLite: { _ in [] }, loadFull: { _ in [] },
            enrich: { catalog, _ in
                check(catalog.services.contains { $0.id == "domain:source-only.example" }, "targeted-only domain is enriched as a selectable service")
                return EnrichmentRefreshResult(snapshot: EnrichmentSnapshot(generatedAt: .now, provenance: "fixture", entries: []), diagnostics: [])
            },
            match: { catalog, targeted, lite, full, cache in
                try CatalogMatcher().match(catalog: catalog, targeted: targeted, lite: lite, full: full, cached: cache)
            }
        ))
        let transaction = try await pipeline.run(RefreshRequest(state: AppState()))
        var state = AppState()
        check(state.applyRefreshTransaction(transaction), "targeted-only refresh commits")
        check(state.catalog?.services.contains { $0.id == "domain:source-only.example" && $0.targetedAddresses == ["192.0.2.44/32"] } == true,
              "targeted-only service remains visible with its owned route")
    }

    // This catches the former mode-by-mode update path: it could publish one
    // source before a later source failed, and it dropped custom source URLs.
    private static func testSuccessfulRefreshReplacesEveryModeAndUsesCustomURLs() async throws {
        let state = legacyState()
        let urls = RefreshSourceURLs(
            metadata: "https://example.test/catalog.yaml",
            targeted: "https://example.test/targeted.json",
            lite: "https://example.test/lite.json",
            full: "https://example.test/full.json"
        )
        let recorder = URLRecorder()
        let service = CatalogService(id: "new", name: "New", domains: ["new.example"])
        let pipeline = RefreshPipeline(
            dependencies: RefreshPipelineDependencies(
                loadCatalog: { request in
                    await recorder.record(request.urls)
                    return ServiceCatalog(services: [service], freshness: .remote)
                },
                loadTargeted: { _ in [TargetedRoute(domain: "new.example", address: "192.0.2.9")] },
                loadLite: { _ in ["198.51.100.0/24"] },
                loadFull: { _ in ["203.0.113.0/24"] },
                enrich: { _, _ in EnrichmentRefreshResult(snapshot: EnrichmentSnapshot(generatedAt: .now, provenance: "fixture", entries: []), diagnostics: []) },
                match: { catalog, targeted, lite, full, cache in
                    try CatalogMatcher().match(catalog: catalog, targeted: targeted, lite: lite, full: full, cached: cache)
                }
            )
        )

        let transaction = try await pipeline.run(RefreshRequest(state: state, urls: urls))
        let seenURLs = await recorder.urls
        check(seenURLs == urls, "refresh keeps user-configured source URLs")
        var committed = state
        check(committed.applyRefreshTransaction(transaction), "complete refresh transaction is accepted")
        check(committed.catalog?.services.map(\.id).contains("new") == true, "new metadata replaces legacy catalog")
        check(committed.exportRoutes(for: .targeted).contains("192.0.2.9/32"), "targeted source is applied")
        check(committed.exportRoutes(for: .lite).contains("198.51.100.0/24"), "lite source is applied")
        check(committed.exportRoutes(for: .full).contains("203.0.113.0/24"), "full source is applied")
        check(ExportMode.allCases.allSatisfy { committed.lastCheck(for: $0) != nil }, "one transaction marks every mode as checked")
        check(Set(transaction.sourceChecks.map(\.id)).isSuperset(of: ["metadata", "targeted", "lite", "full", "dns", "ripeStat"]), "transaction exposes every source diagnostic")
    }

    // Production mutation that this test catches: assigning a loaded Targeted
    // list before the Lite or Full fetch throws.
    private static func testFailedSourceDoesNotMutateWorkingState() async throws {
        let state = legacyState()
        let before = encoded(state)
        let export = state.export
        let pipeline = fixturePipeline(loadLite: { _ in throw FixtureError.unavailable })

        do {
            _ = try await pipeline.run(RefreshRequest(state: state))
            check(false, "one failed source must reject the whole transaction")
        } catch let error as RefreshPipelineError {
            check(error.sourceChecks.contains { $0.id == "lite" && !$0.success }, "failed source has an actionable diagnostic")
        }
        check(encoded(state) == before && state.export == export, "failed source leaves working state and export unchanged")
    }

    // A rejected refresh is still useful only when its diagnostics identify
    // every source that did complete, rather than cancelling healthy loads as
    // soon as the first failure happens.
    private static func testFailedSourceReportsEveryRouteSource() async throws {
        let state = legacyState()
        let pipeline = fixturePipeline(
            loadLite: { _ in throw FixtureError.unavailable },
            loadFull: { _ in
                try await Task.sleep(nanoseconds: 20_000_000)
                return ["203.0.113.0/24"]
            }
        )

        do {
            _ = try await pipeline.run(RefreshRequest(state: state))
            check(false, "one failed source must reject the whole transaction")
        } catch let error as RefreshPipelineError {
            check(
                Set(error.sourceChecks.map(\.id)).isSuperset(of: ["metadata", "targeted", "lite", "full"]),
                "a failed refresh reports every completed route-source diagnostic"
            )
        }
    }

    // Production mutation that this test catches: accepting a shrunken remote
    // metadata catalog and publishing the accompanying route changes.
    private static func testSuspiciousCatalogShrinkDoesNotMutateWorkingState() async throws {
        var state = legacyState()
        state.catalog = ServiceCatalog(services: (0..<4).map { CatalogService(id: "old-\($0)", name: "Old \($0)", domains: ["old\($0).example"]) })
        let before = encoded(state)
        let pipeline = fixturePipeline(loadCatalog: { _ in
            throw ServiceCatalogError.suspiciousShrink(previous: 4, candidate: 1)
        })

        do {
            _ = try await pipeline.run(RefreshRequest(state: state))
            check(false, "suspicious catalog shrink must reject the transaction")
        } catch let error as RefreshPipelineError {
            check(error.sourceChecks.contains { $0.id == "metadata" && !$0.success }, "metadata shrink is surfaced as metadata failure")
        }
        check(encoded(state) == before, "suspicious metadata shrink leaves state unchanged")
    }

    // The persisted catalog combines YAML services with domains discovered in
    // the targeted list. Only YAML services may be used as the shrink baseline.
    private static func testSyntheticServicesDoNotTriggerMetadataShrink() async throws {
        let metadata = (0..<276).map {
            CatalogService(id: "pincetgore:service-\($0)", name: "Service \($0)", domains: ["service\($0).example"])
        }
        let synthetic = (0..<1486).map {
            CatalogService(id: "domain:extra\($0).example", name: "extra\($0).example",
                           category: "Прочие ресурсы", domains: ["extra\($0).example"])
        }
        var state = AppState()
        state.catalog = ServiceCatalog(services: metadata + synthetic)
        let persisted = try JSONDecoder().decode(AppState.self, from: encoded(state))
        check(persisted.catalog?.services.count == 1762, "fixture reproduces the saved service count")
        let previous = RefreshRequest(state: persisted).previousCatalog
        check(previous?.services.count == 276, "synthetic services are excluded from YAML shrink baseline")

        let yaml = "services:\n" + (0..<276).map {
            "  - name: Service \($0)\n    domains: [service\($0).example]\n"
        }.joined()
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [RefreshCatalogURLProtocol.self]
        RefreshCatalogURLProtocol.body = Data(yaml.utf8)
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let loaded = try await ServiceCatalogLoader(session: session).load(
            remoteURL: URL(string: "https://example.test/catalog.yaml")!, previousCatalog: previous)
        check(loaded.services.count == 276 && loaded.freshness == .remote,
              "complete YAML catalog refresh succeeds after a synthetic-service expansion")
    }

    // Production mutation that this test catches: treating a stale cached DNS
    // result as a refresh failure and losing a service's last known route.
    private static func testCachedPartialEnrichmentCanCommit() async throws {
        let state = legacyState()
        let service = CatalogService(id: "cached", name: "Cached", domains: ["cached.example"])
        let stale = EnrichmentSnapshot(
            generatedAt: .now,
            provenance: "fixture",
            entries: [ServiceEnrichment(serviceID: service.id, dnsAddresses: ["192.0.2.88"], dnsDomains: service.domains, freshness: .stale)]
        )
        let pipeline = fixturePipeline(
            loadCatalog: { _ in ServiceCatalog(services: [service]) },
            enrich: { _, cached in
                check(cached == state.cachedEnrichment, "pipeline supplies persisted enrichment to the refresh")
                return EnrichmentRefreshResult(
                    snapshot: stale,
                    diagnostics: [EnrichmentDiagnostic(serviceID: service.id, source: .dns, freshness: .stale, message: "Источник недоступен; использован кэш", updatedAt: .now)]
                )
            }
        )

        let transaction = try await pipeline.run(RefreshRequest(state: state))
        var committed = state
        check(committed.applyRefreshTransaction(transaction), "stale cache remains a valid complete transaction")
        check(committed.exportRoutes(for: .targeted).contains("192.0.2.88/32"), "cached evidence remains exportable")
        check(transaction.sourceChecks.first { $0.id == "dns" }?.message.contains("кэш") == true, "diagnostic identifies cache fallback")
    }

    // Production mutation that this test catches: passing nil instead of the
    // app bundle snapshot on a first refresh, which needlessly empties route
    // ownership while DNS and RIPEstat are unavailable.
    private static func testBundledEvidenceBootstrapsFirstRefresh() async throws {
        let state = legacyState()
        let service = CatalogService(id: "bundled", name: "Bundled", domains: ["bundled.example"])
        let bundled = EnrichmentSnapshot(
            generatedAt: .now,
            provenance: "bundled fixture",
            entries: [ServiceEnrichment(serviceID: service.id, dnsAddresses: ["192.0.2.77"], dnsDomains: service.domains, freshness: .bundled)]
        )
        let pipeline = fixturePipeline(
            loadCatalog: { _ in ServiceCatalog(services: [service]) },
            enrich: { _, cached in
                check(cached == nil, "clean install has no persisted enrichment")
                return EnrichmentRefreshResult(snapshot: bundled, diagnostics: [
                    EnrichmentDiagnostic(serviceID: service.id, source: .dns, freshness: .bundled, message: "Использован включённый снимок", updatedAt: .now)
                ])
            }
        )

        let transaction = try await pipeline.run(RefreshRequest(state: state))
        var committed = state
        check(committed.applyRefreshTransaction(transaction), "bundled evidence transaction is accepted")
        check(committed.exportRoutes(for: .targeted).contains("192.0.2.77/32"), "bundled evidence can bootstrap targeted export")
        check(transaction.sourceChecks.first { $0.id == "dns" }?.message.contains("снимок") == true, "diagnostic identifies bundled evidence")
    }

    // Production mutation that this test catches: allowing a slow network task
    // to outlive the refresh deadline and commit after the UI already gave up.
    private static func testOverallDeadlineDoesNotMutateWorkingState() async throws {
        let state = legacyState()
        let before = encoded(state)
        let pipeline = fixturePipeline(
            overallTimeout: 0.02,
            loadFull: { _ in
                try await Task.sleep(nanoseconds: 200_000_000)
                return ["203.0.113.0/24"]
            }
        )

        do {
            _ = try await pipeline.run(RefreshRequest(state: state))
            check(false, "overall deadline must reject an incomplete transaction")
        } catch let error as RefreshPipelineError {
            check(error.isDeadlineExceeded, "deadline failure is actionable")
        }
        check(encoded(state) == before, "deadline expiry leaves working state unchanged")
    }

    // A real URLSession continuation can outlive task cancellation. The
    // deadline must still release the caller and ignore its late value.
    private static func testUncooperativeSourceCannotDelayDeadline() async throws {
        let state = legacyState()
        let pipeline = fixturePipeline(overallTimeout: 0.02, loadFull: { _ in
            try await delayedIgnoringCancellation(["203.0.113.0/24"], after: 0.25)
        })
        let started = Date()
        do {
            _ = try await pipeline.run(RefreshRequest(state: state))
            check(false, "uncooperative source must still hit the overall deadline")
        } catch let error as RefreshPipelineError {
            check(error.isDeadlineExceeded, "uncooperative source returns the deadline error")
        }
        check(Date().timeIntervalSince(started) < 0.12, "deadline does not await a cancellation-uncooperative source")
    }

    // Production mutation that this test catches: committing a partially
    // partitioned source when the matcher reaches its representation limit.
    private static func testFragmentLimitDoesNotMutateWorkingState() async throws {
        let state = legacyState()
        let before = encoded(state)
        let service = CatalogService(id: "fragment", name: "Fragment", ipRanges: ["192.0.2.1"])
        let pipeline = fixturePipeline(
            loadCatalog: { _ in ServiceCatalog(services: [service]) },
            loadTargeted: { _ in [TargetedRoute(address: "192.0.2.0/24")] },
            match: { catalog, targeted, lite, full, cache in
                try CatalogMatcher(options: CatalogMatchOptions(maximumFragments: 1))
                    .match(catalog: catalog, targeted: targeted, lite: lite, full: full, cached: cache)
            }
        )

        do {
            _ = try await pipeline.run(RefreshRequest(state: state))
            check(false, "fragment limit must reject the transaction")
        } catch let error as RefreshPipelineError {
            check(error.sourceChecks.contains { $0.id == "matching" && !$0.success }, "matcher rejection is diagnosed")
        }
        check(encoded(state) == before, "fragment-limit rejection leaves working state unchanged")
    }

    // Production mutation that this test catches: swallowing cancellation,
    // then applying the late result after a scheduled refresh is stopped.
    private static func testCancelledRefreshDoesNotMutateWorkingState() async throws {
        let state = legacyState()
        let before = encoded(state)
        let pipeline = fixturePipeline(loadTargeted: { _ in
            try await Task.sleep(nanoseconds: 200_000_000)
            return [TargetedRoute(address: "192.0.2.9")]
        })
        let task = Task { try await pipeline.run(RefreshRequest(state: state)) }
        await Task.yield()
        task.cancel()
        do {
            _ = try await task.value
            check(false, "cancelled refresh must not return a transaction")
        } catch is CancellationError { }
        check(encoded(state) == before, "cancelled refresh leaves working state unchanged")
    }

    private static func testCancellationDoesNotAwaitUncooperativeSource() async throws {
        let state = legacyState()
        let pipeline = fixturePipeline(overallTimeout: 1, loadFull: { _ in
            try await delayedIgnoringCancellation(["203.0.113.0/24"], after: 0.25)
        })
        let task = Task { try await pipeline.run(RefreshRequest(state: state)) }
        await Task.yield()
        let started = Date()
        task.cancel()
        do {
            _ = try await task.value
            check(false, "cancelled uncooperative source must not return a transaction")
        } catch is CancellationError { }
        check(Date().timeIntervalSince(started) < 0.12, "cancellation does not await an uncooperative source")
    }

    private static func testRefreshCommitsRawSourceSnapshotsAtomically() async throws {
        let state = legacyState()
        let pipeline = fixturePipeline(
            loadLite: { _ in ["198.51.100.0/24"] },
            loadFull: { _ in ["203.0.113.0/24"] }
        )
        let transaction = try await pipeline.run(RefreshRequest(state: state))
        var committed = state
        check(committed.applyRefreshTransaction(transaction), "valid transaction is committed")
        check(committed.sourceRouteSnapshots == transaction.sourceRoutes, "state preserves canonical raw source routes with the matched catalog")

        let before = encoded(committed)
        let rejected = fixturePipeline(loadLite: { _ in throw FixtureError.unavailable })
        do {
            _ = try await rejected.run(RefreshRequest(state: committed))
            check(false, "failed source must not produce a transaction")
        } catch { }
        check(encoded(committed) == before, "failed refresh cannot replace raw source snapshots")
    }

    private static func testPartitionedUnchangedSourceHasNoRawRouteChange() async throws {
        let state = legacyState()
        let service = CatalogService(id: "partitioned", name: "Partitioned", ipRanges: ["198.51.100.1"])
        let pipeline = fixturePipeline(
            loadCatalog: { _ in ServiceCatalog(services: [service]) },
            loadLite: { _ in ["198.51.100.0/24"] },
            loadFull: { _ in ["203.0.113.0/24"] }
        )
        let first = try await pipeline.run(RefreshRequest(state: state))
        var committed = state
        check(committed.applyRefreshTransaction(first), "partitioned transaction is committed")
        let storedFragments = (committed.catalog?.services.first?.liteAddresses ?? [])
            + (committed.unassignedRoutes[.lite] ?? [])
        check(storedFragments.count > 1, "matcher partitions the stored Lite route")

        let second = try await pipeline.run(RefreshRequest(state: committed))
        check(
            sourceRouteChanges(before: committed.sourceRouteSnapshots, after: second.sourceRoutes).isEmpty,
            "identical raw source routes do not become synthetic changes after catalog partitioning"
        )
    }

    // Production mutation that this test catches: serializing the migrated
    // schema before preserving the literal pre-1.4 bytes, or overwriting the
    // one-time backup on a later write.
    private static func testPreMigrationBackupIsRawAndCreatedOnlyOnce() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iplist-refresh-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let legacy = Data("{\"services\":[]}".utf8)
        var state = AppState()
        state.stateVersion = 14
        try StatePersistence.write(state, to: directory, rawPreMigrationState: legacy)
        let backup = directory.appendingPathComponent("state-before-v1.4.json")
        let firstBackup = try Data(contentsOf: backup)
        check(firstBackup == legacy, "migration backup contains exact raw legacy state")
        state.manual = [ManualEntry(address: "192.0.2.55")]
        try StatePersistence.write(state, to: directory, rawPreMigrationState: Data("different".utf8))
        let secondBackup = try Data(contentsOf: backup)
        check(secondBackup == legacy, "migration backup is created only once")
    }

    private static func testPreMigrationBackupDoesNotReplaceV11Backup() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("iplist-refresh-check-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let v11Backup = directory.appendingPathComponent("state-before-v1.1.json")
        let original = Data("v1.1 bytes".utf8)
        try original.write(to: v11Backup)
        try StatePersistence.write(AppState(), to: directory, rawPreMigrationState: Data("legacy bytes".utf8))
        let preserved = try Data(contentsOf: v11Backup)
        check(preserved == original, "v1.4 migration leaves the existing v1.1 backup untouched")
    }

    private static func fixturePipeline(
        overallTimeout: TimeInterval = 1,
        loadCatalog: @escaping @Sendable (RefreshRequest) async throws -> ServiceCatalog = { _ in
            ServiceCatalog(services: [CatalogService(id: "fixture", name: "Fixture", domains: ["fixture.example"])])
        },
        loadTargeted: @escaping @Sendable (RefreshRequest) async throws -> [TargetedRoute] = { _ in
            [TargetedRoute(domain: "fixture.example", address: "192.0.2.9")]
        },
        loadLite: @escaping @Sendable (RefreshRequest) async throws -> [String] = { _ in ["198.51.100.0/24"] },
        loadFull: @escaping @Sendable (RefreshRequest) async throws -> [String] = { _ in ["203.0.113.0/24"] },
        enrich: @escaping @Sendable (ServiceCatalog, EnrichmentSnapshot?) async throws -> EnrichmentRefreshResult = { _, _ in
            EnrichmentRefreshResult(snapshot: EnrichmentSnapshot(generatedAt: .now, provenance: "fixture", entries: []), diagnostics: [])
        },
        match: @escaping @Sendable (ServiceCatalog, [TargetedRoute], [String], [String], EnrichmentSnapshot?) throws -> MatchedCatalog = { catalog, targeted, lite, full, cached in
            try CatalogMatcher().match(catalog: catalog, targeted: targeted, lite: lite, full: full, cached: cached)
        }
    ) -> RefreshPipeline {
        RefreshPipeline(
            dependencies: RefreshPipelineDependencies(
                loadCatalog: loadCatalog,
                loadTargeted: loadTargeted,
                loadLite: loadLite,
                loadFull: loadFull,
                enrich: enrich,
                match: match
            ),
            overallTimeout: overallTimeout
        )
    }

    private static func legacyState() -> AppState {
        var state = AppState()
        state.stateVersion = 13
        state.services = [Service(id: "legacy", name: "Legacy", category: "Legacy", domains: ["legacy.example"], addresses: ["198.18.0.1"])]
        state.selected = ["legacy"]
        state.selectedCatalogIDs = ["legacy"]
        state.selectionInitialized = true
        state.manual = [ManualEntry(address: "203.0.113.250")]
        return state
    }

    private static func encoded(_ state: AppState) -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try! encoder.encode(state)
    }

    private static func delayedIgnoringCancellation<T: Sendable>(_ value: T, after seconds: TimeInterval) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) {
                continuation.resume(returning: value)
            }
        }
    }
}

private enum FixtureError: LocalizedError {
    case unavailable
    var errorDescription: String? { "fixture unavailable" }
}

private actor URLRecorder {
    private(set) var urls: RefreshSourceURLs?
    func record(_ urls: RefreshSourceURLs) { self.urls = urls }
}

private final class RefreshCatalogURLProtocol: URLProtocol {
    static var body = Data()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
