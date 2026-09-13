import Foundation
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Expected \(b), got \(a)") }
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertGreaterThan(_ a: Int, _ b: Int) { precondition(a > b) }
@main struct CoreTests {
    static func main() async throws {
        let tests = CoreTests()
        tests.testIPv4AndCIDR(); try tests.testImportAndExport(); tests.testSelectionAndDeduplication(); tests.testRules(); try tests.testMigration(); try tests.testModesAndProfiles(); tests.testCatalogDefaults(); try await tests.testNetworkFailures(); try await tests.testLiveCatalog()
        print("All checks passed")
    }
    func testIPv4AndCIDR() {
        XCTAssertEqual(normalizeIP("192.0.2.129/24"), "192.0.2.0/24")
        XCTAssertEqual(normalizeIP("1.2.3.4/0"), "0.0.0.0/0")
        XCTAssertEqual(normalizeIP("1.2.3.4/32"), "1.2.3.4")
        for bad in ["", "1.2.3.999", "example.com", "::1", "1.2.3.4/33", "1.2.3.4/", "1.2.3.4/8/9"] { XCTAssertNil(normalizeIP(bad)) }
    }
    func testImportAndExport() throws {
        let data = Data("[{\"hostname\":\"example.com\",\"ip\":\"1.2.3.4\",\"ips\":[\"1.2.3.5\"]},{\"hostname\":\"192.0.2.123/24\",\"ip\":\"\",\"ips\":[]}]".utf8)
        let entries = try JSONDecoder().decode([AmneziaEntry].self, from: data)
        let ips = Set(entries.flatMap(\.addresses))
        XCTAssertEqual(ips, ["1.2.3.4", "1.2.3.5", "192.0.2.0/24"])
        let exported = try JSONDecoder().decode([AmneziaEntry].self, from: exportData(ips))
        XCTAssertEqual(Set(exported.map(\.hostname)), ips)
        XCTAssertTrue(exported.allSatisfy { $0.ip == "" && $0.ips == [] })
    }
    func testSelectionAndDeduplication() {
        var state = AppState()
        state.services = [Service(id: "a", name: "A", category: "C", domains: [], addresses: ["1.2.3.4"]), Service(id: "b", name: "B", category: "C", domains: [], addresses: ["1.2.3.4", "2.3.4.5"])]
        XCTAssertTrue(state.export.isEmpty)
        state.selected = ["a"]; state.manual = ["1.2.3.4", "3.4.5.6"]
        XCTAssertEqual(state.export, ["1.2.3.4", "3.4.5.6"])
        state.manualEnabled = false; XCTAssertEqual(state.export, ["1.2.3.4"])
    }
    func testRules() {
        let rules = parseRules("# Bank\nfull:bank.ru @ru\ndomain:api.bank.ru # comment\ninclude:sber\nregexp:.*\\.ru\nkeyword:bank\n")
        XCTAssertEqual(rules.domains, ["bank.ru", "api.bank.ru"])
        XCTAssertEqual(rules.includes, ["sber"])
        XCTAssertEqual(rules.groups["Bank"], rules.domains)
    }
    func testMigration() throws {
        let partial = Data("{\"services\":[{\"id\":\"a\",\"name\":\"A\",\"category\":\"C\",\"domains\":[],\"addresses\":[\"1.2.3.4\"]},{\"id\":\"b\",\"name\":\"B\",\"category\":\"C\",\"domains\":[],\"addresses\":[\"2.3.4.5\"]}],\"selected\":[\"a\"],\"manual\":[\"3.4.5.6\"]}".utf8)
        let migrated = try JSONDecoder().decode(AppState.self, from: partial)
        XCTAssertEqual(migrated.selected, ["a"])
        XCTAssertTrue(migrated.selectionInitialized)
        XCTAssertTrue(!migrated.selectAllByDefault)
        XCTAssertEqual(migrated.mode, .targeted)
        XCTAssertEqual(migrated.manual, ["3.4.5.6"])
        let emptySelection = Data(String(decoding: partial, as: UTF8.self).replacingOccurrences(of: "\"selected\":[\"a\"]", with: "\"selected\":[]").utf8)
        let defaults = try JSONDecoder().decode(AppState.self, from: emptySelection)
        XCTAssertEqual(defaults.selected, ["a", "b"])
        XCTAssertTrue(defaults.selectAllByDefault)
        let roundtrip = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(migrated))
        XCTAssertEqual(roundtrip.selected, migrated.selected)
        XCTAssertEqual(roundtrip.manual, migrated.manual)
    }
    func testCatalogDefaults() {
        let a = Service(id: "a", name: "A", category: "C", domains: [], addresses: ["1.2.3.4"])
        let b = Service(id: "b", name: "B", category: "C", domains: [], addresses: ["2.3.4.5"])
        var state = AppState()
        state.applyCatalog([a]); XCTAssertEqual(state.selected, ["a"])
        state.applyCatalog([a, b]); XCTAssertEqual(state.selected, ["a", "b"])
        state.selected = []; state.selectAllByDefault = false
        state.applyCatalog([a, b]); XCTAssertTrue(state.selected.isEmpty)
        state.selected = ["a", "b"]
        state.applyCatalog([b]); XCTAssertEqual(state.selected, ["b"])
    }
    func testModesAndProfiles() throws {
        var state = AppState()
        state.applyCatalog([Service(id: "a", name: "A", category: "C", domains: [], addresses: ["1.2.3.4"])])
        state.liteAddresses = ["192.0.2.0/24"]
        state.fullAddresses = ["198.51.100.0/24"]
        state.manual = ["203.0.113.9"]
        for mode in ExportMode.allCases {
            state.mode = mode
            let expected: Set<String> = mode == .targeted ? ["1.2.3.4"] : (mode == .lite ? ["192.0.2.0/24"] : ["198.51.100.0/24"])
            state.manualEnabled = false; XCTAssertEqual(state.export, expected)
            state.manualEnabled = true; XCTAssertEqual(state.export, expected.union(["203.0.113.9"]))
            let rows = try JSONDecoder().decode([AmneziaEntry].self, from: exportData(state.export))
            XCTAssertEqual(Set(rows.map(\.hostname)), state.export)
        }
        state.mode = .lite; state.manualEnabled = false
        state.saveProfile(name: "Mobile")
        let id = state.profiles[0].id
        state.mode = .full; state.manualEnabled = true; state.selected = []
        XCTAssertTrue(state.applyProfile(id: id))
        XCTAssertEqual(state.mode, .lite); XCTAssertTrue(!state.manualEnabled); XCTAssertEqual(state.selected, ["a"])
        let restored = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(restored.profiles, state.profiles)
        state.markChecked(.lite, at: Date(timeIntervalSince1970: 123))
        XCTAssertEqual(state.lastCheck(for: .lite), Date(timeIntervalSince1970: 123))
        XCTAssertNil(state.lastCheck(for: .full))
        state.deleteProfile(id: id); XCTAssertTrue(state.profiles.isEmpty)
    }
    func testNetworkFailures() async throws {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        StubProtocol.reset("retry")
        let loader = CatalogLoader(session: session, timeout: 0.1, retryCount: 1)
        let ranges = try await loader.loadRanges(mode: .lite, source: "https://example.test/list.json")
        XCTAssertEqual(ranges, ["192.0.2.0/24"])
        XCTAssertEqual(StubProtocol.requests.count, 2)
        StubProtocol.reset("fallback")
        let fallback = try await loader.loadRanges(mode: .lite, source: CatalogSources.liteRelease)
        XCTAssertEqual(fallback, ["192.0.2.0/24"])
        XCTAssertTrue(StubProtocol.requests.contains(CatalogSources.liteRaw))
        StubProtocol.reset("timeout")
        do {
            _ = try await CatalogLoader(session: session, timeout: 0.1, retryCount: 0).loadRanges(mode: .full, source: "https://example.test/broken.json")
            preconditionFailure("Timeout must fail")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("https://example.test/broken.json"))
            XCTAssertTrue(error.localizedDescription.lowercased().contains("время") || error.localizedDescription.lowercased().contains("тайм"))
        }
        StubProtocol.reset("invalid")
        do {
            _ = try await loader.loadRanges(mode: .full, source: "https://example.test/invalid.json")
            preconditionFailure("Invalid JSON must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("https://example.test/invalid.json")) }
        StubProtocol.reset("timeout")
        let checks = await CatalogLoader(session: session, timeout: 0.1, retryCount: 0).testSources(source: "https://example.test/domains", base: "https://example.test/categories", liteSource: "https://example.test/lite", fullSource: "https://example.test/full")
        XCTAssertEqual(checks.count, 4)
        XCTAssertTrue(checks.allSatisfy { !$0.success && $0.message.contains($0.url) })
    }
    func testLiveCatalog() async throws {
        guard ProcessInfo.processInfo.environment["IPLIST_LIVE_TEST"] == "1" else { return }
        let state = AppState()
        let services = try await CatalogLoader().load(source: state.sourceURL, base: state.categoryBaseURL)
        XCTAssertGreaterThan(services.count, 30)
        XCTAssertTrue(services.contains { $0.category == "Банки и финансы" && !$0.addresses.isEmpty })
        print("Live catalog: \(services.count) services, \(Set(services.flatMap(\.addresses)).count) IPs")
        for mode in [ExportMode.lite, .full] {
            let ranges = try await CatalogLoader().loadRanges(mode: mode)
            XCTAssertGreaterThan(ranges.count, 100)
            print("Live \(mode.rawValue): \(ranges.count) ranges")
        }
        let checks = await CatalogLoader().testSources(source: state.sourceURL, base: state.categoryBaseURL)
        XCTAssertEqual(checks.count, 7)
        for check in checks { print("Source \(check.id): \(check.success), HTTP \(check.statusCode ?? 0), \(check.duration)s") }
        XCTAssertTrue(checks.allSatisfy(\.success))
    }
}

final class StubProtocol: URLProtocol {
    static let lock = NSLock()
    static var behavior = ""
    static var seen: [String] = []
    static var requests: [String] { lock.lock(); defer { lock.unlock() }; return seen }
    static func reset(_ value: String) { lock.lock(); defer { lock.unlock() }; behavior = value; seen = [] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock()
        let behavior = Self.behavior
        Self.seen.append(request.url!.absoluteString)
        let count = Self.seen.count
        Self.lock.unlock()
        if behavior == "timeout" || (behavior == "retry" && count == 1) || (behavior == "fallback" && request.url!.host == "github.com") {
            client?.urlProtocol(self, didFailWithError: URLError(.timedOut)); return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = behavior == "invalid" ? "<html>error</html>" : "[{\"hostname\":\"192.0.2.7/24\",\"ip\":\"\",\"ips\":[]}]"
        client?.urlProtocol(self, didLoad: Data(body.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
