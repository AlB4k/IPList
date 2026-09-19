import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

@main
struct CatalogChecks {
    static func main() async throws {
        try testAeroflotFixture()
        try testValidationAndUnknownFields()
        try await testCollisionAndShrinkGuard()
        try await testFallbackMetadata()
        try await testNoFallbackFails()
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
