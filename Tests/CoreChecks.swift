import Foundation
func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T) { precondition(a == b, "Expected \(b), got \(a)") }
func XCTAssertTrue(_ value: Bool) { precondition(value) }
func XCTAssertNil<T>(_ value: T?) { precondition(value == nil) }
func XCTAssertGreaterThan(_ a: Int, _ b: Int) { precondition(a > b) }
func XCTAssertThrows<T>(_ expression: @autoclosure () throws -> T, matching predicate: (Error) -> Bool) {
    do {
        _ = try expression()
        preconditionFailure("Expected error")
    } catch {
        precondition(predicate(error), "Unexpected error: \(error)")
    }
}
func addresses(in routes: [String]) -> Set<UInt32> {
    var result: Set<UInt32> = []
    for route in routes {
        guard let network = IPv4Network(route) else { continue }
        let count = UInt32(network.addressCount)
        for offset in 0..<count { result.insert(network.network + offset) }
    }
    return result
}
func allowedIPv4Routes(in config: String) -> [IPv4Network] {
    config.split(whereSeparator: \.isNewline).flatMap { line -> [IPv4Network] in
        guard let equals = line.firstIndex(of: "="),
              line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("AllowedIPs") == .orderedSame else {
            return []
        }
        return line[line.index(after: equals)...].split(separator: ",").compactMap { IPv4Network(String($0)) }
    }
}
@main struct CoreTests {
    static func main() async throws {
        let tests = CoreTests()
        tests.testIPv4AndCIDR(); tests.testIPv4NetworkSetOperations(); tests.testIPv4NetworkReferenceOracle(); tests.testAllowedIPsFormattingDeduplicatesExistingCoverage(); try tests.testAmneziaWGParsePreservesUnchangedBytes(); try tests.testAmneziaWGPreservesAllowedIPSuffixesAndOpaqueValues(); try tests.testAmneziaWGOperationsNormalizeRoutes(); try tests.testAmneziaWGRejectsUnsafeConfigurationsWithoutLeakingKeys(); try tests.testAmneziaWGRejectsEmptyBypass(); try tests.testPrivateConfigurationPermissions(); try tests.testAmneziaWGLargeRouteRegression(); try tests.testImportAndExport(); tests.testSelectionAndDeduplication(); tests.testRules(); try tests.testMigration(); try tests.testModesAndProfiles(); tests.testProfileSaveReturnsCreatedOrUpdatedID(); tests.testCatalogDefaults(); tests.testManualGroups(); try await tests.testNetworkFailures(); try await tests.testLiveCatalog()
        print("All checks passed")
    }
    func testIPv4AndCIDR() {
        XCTAssertEqual(normalizeIP("192.0.2.129/24"), "192.0.2.0/24")
        XCTAssertEqual(normalizeIP("1.2.3.4/0"), "0.0.0.0/0")
        XCTAssertEqual(normalizeIP("1.2.3.4/32"), "1.2.3.4")
        for bad in ["", "1.2.3.999", "example.com", "::1", "1.2.3.4/33", "1.2.3.4/", "1.2.3.4/8/9"] { XCTAssertNil(normalizeIP(bad)) }
    }
    func testIPv4NetworkSetOperations() {
        let source = IPv4Network("10.0.0.0/24")!
        let child = IPv4Network("10.0.0.7/32")!
        let disjoint = IPv4Network("10.0.1.0/24")!
        XCTAssertTrue(source.contains(child))
        XCTAssertTrue(source.intersects(child))
        XCTAssertTrue(!source.intersects(disjoint))
        XCTAssertEqual(source.subtracting(IPv4Network("10.0.0.64/26")!).map(\.description),
                       ["10.0.0.0/26", "10.0.0.128/25"])
        XCTAssertEqual(collapseIPv4(["10.0.0.0/25", "10.0.0.128/25", "10.0.0.4/32"]),
                       ["10.0.0.0/24"])
        XCTAssertEqual(collapseIPv4(["10.0.0.0/24"]),
                       collapseIPv4(["10.0.0.0/25", "10.0.0.128/25"]))
        XCTAssertEqual(collapseIPv4(["10.0.0.7/32", "10.0.0.7", "10.0.0.0/24"]),
                       ["10.0.0.0/24"])
    }
    func testIPv4NetworkReferenceOracle() {
        for invalid in ["", "1.2.3.4/33", "1.2.3.4/", "1.2.3.4/-1", "1.2.3/24", "::1/128"] {
            XCTAssertNil(IPv4Network(invalid))
        }
        XCTAssertEqual(IPv4Network("203.0.113.3/31")?.description, "203.0.113.2/31")
        XCTAssertEqual(IPv4Network("203.0.113.3/32")?.description, "203.0.113.3/32")
        XCTAssertEqual(IPv4Network("203.0.113.3/0")?.description, "0.0.0.0/0")

        var state: UInt64 = 0xA11CE5EED
        func next() -> UInt32 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return UInt32(truncatingIfNeeded: state >> 32)
        }
        for _ in 0..<128 {
            let left = IPv4Network(network: next() & 0xFF, prefix: UInt8(next() % 9 + 24))!
            let right = IPv4Network(network: next() & 0xFF, prefix: UInt8(next() % 9 + 24))!
            let collapsed = collapseIPv4([left.description, right.description])
            XCTAssertEqual(addresses(in: collapsed), addresses(in: [left.description, right.description]))
            XCTAssertEqual(addresses(in: left.subtracting(right).map(\.description)),
                           addresses(in: [left.description]).subtracting(addresses(in: [right.description])))
            XCTAssertEqual(left.intersection(right).map { addresses(in: [$0.description]) } ?? [],
                           addresses(in: [left.description]).intersection(addresses(in: [right.description])))
        }
        XCTAssertThrows(try IPv4Network("0.0.0.0/0")!.subtracting(IPv4Network("0.0.0.0/32")!, limit: 1)) {
            ($0 as? IPv4NetworkError) == .fragmentLimitExceeded(limit: 1)
        }
    }
    func testAllowedIPsFormattingDeduplicatesExistingCoverage() {
        XCTAssertEqual(
            allowedIPsLine(["1.1.1.1", "1.1.1.1/32", "192.0.2.1/24", "192.0.2.9/32"]),
            "AllowedIPs = 1.1.1.1/32, 192.0.2.0/24"
        )
    }
    func testAmneziaWGParsePreservesUnchangedBytes() throws {
        let config = "\u{FEFF}# retained header = exact\r\n[Interface]\r\nPrivateKey = PRIVATE-SECRET-DO-NOT-LOG\r\nJc = 4\r\nHeaderProtectionKey = unchanged\r\n\r\n[Peer]\r\nPublicKey = FIRST-PEER\r\nAllowedIPs = 10.0.0.0/8\r\n\r\n[Peer]\r\n# selected peer\r\nPublicKey = SECOND-PEER\r\nPresharedKey = PRESHARED-SECRET-DO-NOT-LOG\r\nAllowedIPs = 10.0.0.0/8\r\nAllowedIPs = 192.0.2.1/32\r\nEndpoint = vpn.example.test:51820\r\n"
        let document = try AmneziaWGDocument.parse(config)
        XCTAssertEqual(document.peers.count, 2)
        XCTAssertEqual(document.peers.map(\.displayName), ["Peer 1", "vpn.example.test:51820"])

        let edited = try document.render(peer: 1, operation: .add,
                                         routes: ["192.0.2.1/32", "192.0.2.0/24"],
                                         preserveIPv6: true)
        XCTAssertTrue(edited.contains("AllowedIPs = 10.0.0.0/8, 192.0.2.0/24\r\n"))
        XCTAssertTrue(edited.contains("HeaderProtectionKey = unchanged\r\n"))
        XCTAssertTrue(edited.hasPrefix("\u{FEFF}# retained header = exact\r\n"))
        XCTAssertTrue(edited.hasSuffix("Endpoint = vpn.example.test:51820\r\n"))
        XCTAssertTrue(edited.contains("PresharedKey = PRESHARED-SECRET-DO-NOT-LOG\r\n"))
        XCTAssertEqual(edited, "\u{FEFF}# retained header = exact\r\n[Interface]\r\nPrivateKey = PRIVATE-SECRET-DO-NOT-LOG\r\nJc = 4\r\nHeaderProtectionKey = unchanged\r\n\r\n[Peer]\r\nPublicKey = FIRST-PEER\r\nAllowedIPs = 10.0.0.0/8\r\n\r\n[Peer]\r\n# selected peer\r\nPublicKey = SECOND-PEER\r\nPresharedKey = PRESHARED-SECRET-DO-NOT-LOG\r\nAllowedIPs = 10.0.0.0/8, 192.0.2.0/24\r\nEndpoint = vpn.example.test:51820\r\n")
    }
    func testAmneziaWGPreservesAllowedIPSuffixesAndOpaqueValues() throws {
        let hashComment = "[Interface]\nPrivateKey = private\nOpaqueSetting = must-stay]\n[Peer]\nPublicKey = peer\nAllowedIPs = 10.0.0.0/8\t  # keep these spaces\n"
        let hashEdited = try AmneziaWGDocument.parse(hashComment)
            .render(peer: 0, operation: .add, routes: ["192.0.2.0/24"], preserveIPv6: true)
        XCTAssertEqual(hashEdited, "[Interface]\nPrivateKey = private\nOpaqueSetting = must-stay]\n[Peer]\nPublicKey = peer\nAllowedIPs = 10.0.0.0/8, 192.0.2.0/24\t  # keep these spaces\n")

        let semicolonComment = "[Interface]\r\nPrivateKey = private\r\n[Peer]\r\nPublicKey = peer\r\nAllowedIPs = 10.0.0.0/8   ; preserve this suffix\r\n"
        let semicolonEdited = try AmneziaWGDocument.parse(semicolonComment)
            .render(peer: 0, operation: .add, routes: ["192.0.2.0/24"], preserveIPv6: true)
        XCTAssertEqual(semicolonEdited, "[Interface]\r\nPrivateKey = private\r\n[Peer]\r\nPublicKey = peer\r\nAllowedIPs = 10.0.0.0/8, 192.0.2.0/24   ; preserve this suffix\r\n")
    }
    func testAmneziaWGOperationsNormalizeRoutes() throws {
        let config = "[Interface]\nPrivateKey = interface-key\n\n[Peer]\nPublicKey = peer-key\nAllowedIPs = 0.0.0.0/0, 2001:db8::/32\n"
        let document = try AmneziaWGDocument.parse(config)

        let added = try document.render(peer: 0, operation: .add,
                                        routes: ["10.0.0.0/8", "10.1.2.3", "10.1.2.3/32"], preserveIPv6: true)
        XCTAssertTrue(added.contains("AllowedIPs = 0.0.0.0/0, 2001:db8::/32\n"))

        let replaced = try document.render(peer: 0, operation: .replace,
                                           routes: ["192.0.2.1", "2001:db8:1::/48"], preserveIPv6: true)
        XCTAssertTrue(replaced.contains("AllowedIPs = 192.0.2.1/32, 2001:db8::/32, 2001:db8:1::/48\n"))

        let bypassed = try document.render(peer: 0, operation: .bypass,
                                           routes: ["10.0.0.0/8"], preserveIPv6: true)
        XCTAssertTrue(!bypassed.contains("AllowedIPs = 0.0.0.0/0"))
        XCTAssertTrue(bypassed.contains("2001:db8::/32"))
        XCTAssertTrue(!allowedIPv4Routes(in: bypassed).contains { $0.contains(IPv4Network("10.1.2.3")!) })

        let first = try AmneziaWGDocument.parse(config).render(peer: 0, operation: .replace,
                                                                routes: ["192.0.2.0/24"], preserveIPv6: false)
        let second = try AmneziaWGDocument.parse(config.replacingOccurrences(of: "peer-key", with: "other-peer-key"))
            .render(peer: 0, operation: .replace, routes: ["198.51.100.0/24"], preserveIPv6: false)
        XCTAssertEqual([first, second].count, 2)
        XCTAssertTrue(first.contains("192.0.2.0/24"))
        XCTAssertTrue(second.contains("198.51.100.0/24"))
    }

    func testAmneziaWGRejectsEmptyBypass() throws {
        let document = try AmneziaWGDocument.parse("[Interface]\nPrivateKey = private\n\n[Peer]\nPublicKey = peer\nAllowedIPs = 192.0.2.1/32\n")
        XCTAssertThrows(try document.render(peer: 0, operation: .bypass, routes: ["192.0.2.1/32"], preserveIPv6: true)) {
            ($0 as? AmneziaWGConfigError)?.localizedDescription.contains("пустая конфигурация") == true
        }
    }

    func testPrivateConfigurationPermissions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let output = folder.appendingPathComponent("profile.conf")
        try writePrivateFile(Data("PrivateKey = secret".utf8), temporary: folder.appendingPathComponent(".tmp"), output: output)
        let attributes = try FileManager.default.attributesOfItem(atPath: output.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }
    func testAmneziaWGRejectsUnsafeConfigurationsWithoutLeakingKeys() throws {
        let privateSecret = "PRIVATE-SECRET-DO-NOT-LOG"
        let presharedSecret = "PRESHARED-SECRET-DO-NOT-LOG"
        let invalidDocuments = [
            "[Peer]\nPublicKey = peer\nPresharedKey = \(presharedSecret)\n",
            "[Interface]\nPrivateKey = \(privateSecret)\n\n[Peer]\nAllowedIPs = 192.0.2.0/24\n",
            "[Interface]\nPrivateKey = \(privateSecret)\n\n[Peer]\nPublicKey = peer\nAllowedIPs = 999.0.2.0/24\n",
            "[Interface]\nPrivateKey = \(privateSecret)\n\n[Peer]\nPublicKey = peer\nAllowedIPs = 2001:db8::/129\n",
            "[Interface]\nPrivateKey = \(privateSecret)\nPrivateKey = duplicate\n\n[Peer]\nPublicKey = peer\n"
        ]
        for config in invalidDocuments {
            XCTAssertThrows(try AmneziaWGDocument.parse(config)) { error in
                let message = error.localizedDescription
                return !message.contains(privateSecret) && !message.contains(presharedSecret)
            }
        }

        let overlap = "[Interface]\nPrivateKey = \(privateSecret)\n\n[Peer]\nPublicKey = first\nAllowedIPs = 10.0.0.0/24\n\n[Peer]\nPublicKey = second\nAllowedIPs = 192.0.2.0/24\n"
        let document = try AmneziaWGDocument.parse(overlap)
        XCTAssertThrows(try document.render(peer: 0, operation: .add, routes: ["192.0.2.0/24"], preserveIPv6: true)) { error in
            !error.localizedDescription.contains(privateSecret) && !error.localizedDescription.contains(presharedSecret)
        }

        let withoutAllowedIPs = try AmneziaWGDocument.parse("[Interface]\nPrivateKey = \(privateSecret)\n\n[Peer]\nPublicKey = peer")
            .render(peer: 0, operation: .add, routes: ["192.0.2.1"], preserveIPv6: true)
        XCTAssertEqual(withoutAllowedIPs, "[Interface]\nPrivateKey = \(privateSecret)\n\n[Peer]\nPublicKey = peer\nAllowedIPs = 192.0.2.1/32")
    }
    func testAmneziaWGLargeRouteRegression() throws {
        var existing = ["203.0.113.0/24"]
        for index in 0..<1_535 {
            let value = index * 2
            existing.append("198.\((value >> 16) & 255).\((value >> 8) & 255).\(value & 255)/32")
        }
        XCTAssertEqual(existing.count, 1_536)
        let allowedLines = stride(from: 0, to: existing.count, by: 256).map { start in
            "AllowedIPs = \(existing[start..<min(start + 256, existing.count)].joined(separator: ", "))\n"
        }.joined()
        let config = "# header stays byte-for-byte\n[Interface]\nPrivateKey = private\nHeaderProtectionKey = unchanged\n\n[Peer]\nPublicKey = peer\n\(allowedLines)Endpoint = vpn.example.test:51820\n"
        let document = try AmneziaWGDocument.parse(config)
        let edited = try document.render(peer: 0, operation: .add,
                                         routes: ["198.0.0.0", "198.0.0.0/32", "203.0.113.7/32", "198.0.0.1/32", "198.0.12.1/32"],
                                         preserveIPv6: true)
        let finalRoutes = allowedIPv4Routes(in: edited)
        XCTAssertTrue(finalRoutes.contains(IPv4Network("203.0.113.0/24")!))
        XCTAssertTrue(!finalRoutes.contains(IPv4Network("203.0.113.7/32")!))
        XCTAssertTrue(finalRoutes.contains { $0.contains(IPv4Network("198.0.12.1/32")!) })
        XCTAssertEqual(addresses(in: finalRoutes.map(\.description)).subtracting(addresses(in: existing)),
                       Set([IPv4Network("198.0.0.1/32")!.network, IPv4Network("198.0.12.1/32")!.network]))
        XCTAssertTrue(edited.contains("# header stays byte-for-byte\n[Interface]\nPrivateKey = private\nHeaderProtectionKey = unchanged\n"))
        XCTAssertTrue(edited.hasSuffix("Endpoint = vpn.example.test:51820\n"))
    }
    func testImportAndExport() throws {
        let data = Data("[{\"hostname\":\"example.com\",\"ip\":\"1.2.3.4\",\"ips\":[\"1.2.3.5\"]},{\"hostname\":\"192.0.2.123/24\",\"ip\":\"\",\"ips\":[]}]".utf8)
        let entries = try JSONDecoder().decode([AmneziaEntry].self, from: data)
        let ips = Set(entries.flatMap(\.addresses))
        XCTAssertEqual(ips, ["1.2.3.4", "1.2.3.5", "192.0.2.0/24"])
        let exported = try JSONDecoder().decode([AmneziaEntry].self, from: exportData(ips))
        XCTAssertEqual(Set(exported.map(\.hostname)), ["1.2.3.4/31", "192.0.2.0/24"])
        XCTAssertTrue(exported.allSatisfy { $0.ip == "" && $0.ips == [] })
    }
    func testSelectionAndDeduplication() {
        var state = AppState()
        state.services = [Service(id: "a", name: "A", category: "C", domains: [], addresses: ["1.2.3.4"]), Service(id: "b", name: "B", category: "C", domains: [], addresses: ["1.2.3.4", "2.3.4.5"])]
        XCTAssertTrue(state.export.isEmpty)
        state.selected = ["a"]; state.manual = [ManualEntry(address: "1.2.3.4"), ManualEntry(address: "3.4.5.6")]
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
        // Pre-grouping releases stored "manual" as a plain array of address strings.
        XCTAssertEqual(migrated.manual.map(\.address), ["3.4.5.6"])
        XCTAssertTrue(migrated.manual.allSatisfy { $0.groupID == nil && $0.note.isEmpty })
        XCTAssertTrue(migrated.manualGroups.isEmpty)
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
        state.manual = [ManualEntry(address: "203.0.113.9")]
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
    func testProfileSaveReturnsCreatedOrUpdatedID() {
        var state = AppState()
        state.saveProfile(name: "Z")
        let existingID = state.profiles[0].id
        let createdID = state.saveProfile(name: "A")
        XCTAssertEqual(createdID, state.profiles.first { $0.name == "A" }?.id)
        XCTAssertEqual(state.profiles.last?.id, existingID)
        let updatedID = state.saveProfile(name: "A")
        XCTAssertEqual(updatedID, createdID)
    }
    func testManualGroups() {
        var state = AppState()
        XCTAssertTrue(state.addGroup(name: "VPS-сервера"))
        XCTAssertTrue(state.addGroup(name: "Сайты"))
        XCTAssertTrue(!state.addGroup(name: "  Сайты  ")) // duplicate name (case/whitespace-insensitive) is rejected
        XCTAssertTrue(!state.addGroup(name: "   ")) // empty name is rejected
        // Sorted with a non-localized comparator so order is deterministic across locales (this
        // caught a real CI failure: localizedCaseInsensitiveCompare ordered Cyrillic differently
        // depending on the system locale).
        XCTAssertEqual(state.manualGroups.map(\.name), ["VPS-сервера", "Сайты"])
        let vpsID = state.manualGroups.first { $0.name == "VPS-сервера" }!.id
        state.manual = [ManualEntry(address: "1.2.3.4", groupID: vpsID), ManualEntry(address: "5.6.7.8")]

        state.renameGroup(id: vpsID, name: "VPS")
        XCTAssertEqual(state.manualGroups.first { $0.id == vpsID }?.name, "VPS")

        state.deleteGroup(id: vpsID)
        XCTAssertTrue(!state.manualGroups.contains { $0.id == vpsID })
        // Deleting a group must not delete its addresses — they become ungrouped.
        XCTAssertEqual(state.manual.count, 2)
        XCTAssertNil(state.manual.first { $0.address == "1.2.3.4" }?.groupID)

        let roundtrip = try! JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(roundtrip.manual, state.manual)
        XCTAssertEqual(roundtrip.manualGroups, state.manualGroups)
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
