import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

@main
struct CatalogChecks {
    static func main() async throws {
        try testAeroflotFixture()
        try testCategoryCommentsRequireSupportedHeading()
        try testValidationAndUnknownFields()
        try testKnownListShapeValidation()
        try await testCollisionAndShrinkGuard()
        try testLegacyCodableDefaults()
        try await testFallbackMetadata()
        try await testLastSuccessfulCatalogFallback()
        try await testNoFallbackFails()
        try await testLiveCatalog()
        print("Catalog checks passed")
    }

    static func testAeroflotFixture() throws {
        let fixture = #"""
        services:
          # ============================================================
          # ТРАНСПОРТ, АВТО И КАРШЕРИНГ
          # ============================================================
          - name: "Аэрофлот"
            asn: [34571]
            ip_ranges:
              - 203.0.113.0/24
            domains: ["aeroflot.ru", "api.aeroflot.ru"]
            labels:
              - must-not-change-parser-state
          - name: "Без категории"
            unknown: ["ignored"]
            domains:
              - example.ru
        """#
        let catalog = try ServiceCatalogParser.parse(fixture)
        let aeroflot = try require(catalog.services.first { $0.name == "Аэрофлот" })
        check(aeroflot.category == "Транспорт, авто и каршеринг", "category")
        check(aeroflot.domains == ["aeroflot.ru", "api.aeroflot.ru"], "domains")
        check(aeroflot.asn == [34571], "asn")
        check(aeroflot.ipRanges == ["203.0.113.0/24"], "ranges")
        check(catalog.services.count == 2, "unknown fields must not create services")
    }

    static func testCategoryCommentsRequireSupportedHeading() throws {
        let ordinary = "services:\n  # an ordinary note\n  - name: Ordinary\n    domains: [ordinary.example]\n"
        let ordinaryCatalog = try ServiceCatalogParser.parse(ordinary)
        check(ordinaryCatalog.services[0].category == "Без категории", "ordinary comments must not become categories")

        let missingClosingDivider = "services:\n  # ============================================================\n  # ТРАНСПОРТ, АВТО И КАРШЕРИНГ\n  - name: Missing closing divider\n    domains: [missing.example]\n"
        let missingCatalog = try ServiceCatalogParser.parse(missingClosingDivider)
        check(missingCatalog.services[0].category == "Без категории", "incomplete headings must fall back")

        let changedComment = "services:\n  # ============================================================\n  # changed comment\n  # ============================================================\n  - name: Changed\n    domains: [changed.example]\n"
        let changedCatalog = try ServiceCatalogParser.parse(changedComment)
        check(changedCatalog.services[0].category == "Без категории", "unsupported headings must fall back")

        let supportedThenOrdinary = """
        services:
          # ============================================================
          # ТРАНСПОРТ, АВТО И КАРШЕРИНГ
          # ============================================================
          - name: Supported
            domains: [supported.example]
          # ordinary note
          - name: Ordinary after heading
            domains: [ordinary-after.example]
        """
        let mixedCatalog = try ServiceCatalogParser.parse(supportedThenOrdinary)
        check(mixedCatalog.services[0].category == "Транспорт, авто и каршеринг", "supported heading")
        check(mixedCatalog.services[1].category == "Без категории", "ordinary comment resets category")
    }

    static func testValidationAndUnknownFields() throws {
        do {
            _ = try ServiceCatalogParser.parse("services:\n  - name: x\n    asn: [-1]\n    domains: [x.ru]\n")
            preconditionFailure("invalid ASN must be rejected")
        } catch let error as ServiceCatalogError {
            check(error == .invalidASN(-1), "invalid ASN error")
        }

        do {
            _ = try ServiceCatalogParser.parse("services:\n  - name: x\n    ip_ranges: [203.0.113.1/33]\n")
            preconditionFailure("invalid range must be rejected")
        } catch let error as ServiceCatalogError {
            check(error.isInvalidIPRange, "invalid range error")
        }

        let unknown = "services:\n  - name: one\n    ignored:\n      - not-a-domain\n    domains:\n      - one.example\n"
        let parsed = try ServiceCatalogParser.parse(unknown)
        check(parsed.services[0].domains == ["one.example"], "unknown array must not shift state")
    }

    static func testKnownListShapeValidation() throws {
        let scalar = "services:\n  - name: scalar\n    domains: scalar.example\n"
        do {
            _ = try ServiceCatalogParser.parse(scalar)
            preconditionFailure("scalar known list field must be rejected")
        } catch let error as ServiceCatalogError {
            if case .malformed = error {} else { preconditionFailure("wrong scalar error: \(error)") }
        }

        let emptyBlock = "services:\n  - name: empty\n    domains:\n  - name: next\n    domains: [next.example]\n"
        do {
            _ = try ServiceCatalogParser.parse(emptyBlock)
            preconditionFailure("opened empty block list must be rejected")
        } catch let error as ServiceCatalogError {
            if case .malformed = error {} else { preconditionFailure("wrong empty-list error: \(error)") }
        }
    }

    static func testCollisionAndShrinkGuard() async throws {
        let collision = "services:\n  - name: Foo Bar\n    domains: [foo.example]\n  - name: foo-bar\n    domains: [bar.example]\n"
        do {
            _ = try ServiceCatalogParser.parse(collision)
            preconditionFailure("stable ID collision must be rejected")
        } catch let error as ServiceCatalogError {
            if case .duplicateStableID = error {} else { preconditionFailure("wrong collision error: \(error)") }
        }

        let old = ServiceCatalog(services: (0..<4).map { CatalogService(name: "old\($0)", domains: ["old\($0).example"]) })
        let candidate = Data("services:\n  - name: new\n    domains: [new.example]\n".utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StaticURLProtocol.self]
        StaticURLProtocol.body = candidate
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ServiceCatalogLoader(session: session).load(
                remoteURL: URL(string: "https://example.test/catalog.yaml")!, previousCatalog: old)
            preconditionFailure("suspicious shrink must be rejected")
        } catch let error as ServiceCatalogError {
            if case .suspiciousShrink = error {} else { preconditionFailure("wrong shrink error: \(error)") }
        }
    }

    static func testLegacyCodableDefaults() throws {
        let legacyService = Data("{\"id\":\"legacy\",\"name\":\"Legacy\",\"category\":\"Без категории\",\"domains\":[\"legacy.example\"],\"asn\":[],\"ipRanges\":[]}".utf8)
        let service = try JSONDecoder().decode(CatalogService.self, from: legacyService)
        check(service.targetedAddresses.isEmpty && service.liteAddresses.isEmpty && service.fullAddresses.isEmpty, "legacy service defaults")

        let legacyCatalog = Data("{\"services\":[\(String(decoding: legacyService, as: UTF8.self))]}".utf8)
        let catalog = try JSONDecoder().decode(ServiceCatalog.self, from: legacyCatalog)
        check(catalog.freshness == .cached, "legacy catalog defaults to cached")
    }

    static func testFallbackMetadata() async throws {
        let fallback = Data("services:\n  - name: cached\n    domains: [cached.example]\n".utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let loader = ServiceCatalogLoader(session: session)
        let result = try await loader.load(remoteURL: URL(string: "https://example.test/catalog.yaml")!, fallbackData: fallback)
        check(result.freshness == .cached, "fallback freshness")
        check(result.services.first?.name == "cached", "fallback data")
    }

    static func testLastSuccessfulCatalogFallback() async throws {
        let remote = Data("services:\n  - name: remote\n    domains: [remote.example]\n".utf8)
        let callerFallback = Data("services:\n  - name: caller\n    domains: [caller.example]\n".utf8)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FlakyURLProtocol.self]
        FlakyURLProtocol.body = remote
        FlakyURLProtocol.shouldFail = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let loader = ServiceCatalogLoader(session: session)
        let first = try await loader.load(remoteURL: URL(string: "https://example.test/catalog.yaml")!)
        check(first.freshness == .remote && first.services.first?.name == "remote", "remote success")

        FlakyURLProtocol.shouldFail = true
        let second = try await loader.load(remoteURL: URL(string: "https://example.test/catalog.yaml")!, fallbackData: callerFallback)
        check(second.freshness == .cached, "last-successful freshness")
        check(second.services.first?.name == "remote", "last-successful catalog precedes caller fallback")
        check(second.sourceURL == "last-successful-catalog", "last-successful source metadata")
    }

    static func testNoFallbackFails() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [FailingURLProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        do {
            _ = try await ServiceCatalogLoader(session: session).load(remoteURL: URL(string: "https://example.test/catalog.yaml")!)
            preconditionFailure("missing fallback must fail")
        } catch let error as ServiceCatalogError {
            check(error.errorDescription?.isEmpty == false, "fallback error should be actionable")
        }
    }

    static func testLiveCatalog() async throws {
        guard ProcessInfo.processInfo.environment["IPLIST_LIVE_TEST"] == "1" else { return }
        let url = URL(string: "https://raw.githubusercontent.com/pincetgore/amnezia-app-ru-list/main/config.yaml")!
        let catalog = try await ServiceCatalogLoader().load(remoteURL: url)
        check(catalog.freshness == .remote, "live catalog freshness")
        check(catalog.services.count >= 200, "live catalog service count")
        let aeroflot = try require(catalog.services.first { $0.name == "Аэрофлот" })
        check(aeroflot.category == "Транспорт, авто и каршеринг", "live Aeroflot category")
        check(aeroflot.domains.contains("aeroflot.ru"), "live Aeroflot domain")
        check(aeroflot.domains.contains("api.aeroflot.ru"), "live Aeroflot API domain")
        check(aeroflot.asn.contains(34571), "live Aeroflot ASN")
    }
}

private extension CatalogChecks {
    static func require<T>(_ value: T?) throws -> T {
        guard let value else { throw NSError(domain: "CatalogChecks", code: 1) }
        return value
    }
}

private final class FailingURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}

private final class StaticURLProtocol: URLProtocol {
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

private final class FlakyURLProtocol: URLProtocol {
    static var body = Data()
    static var shouldFail = false
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if Self.shouldFail {
            client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
