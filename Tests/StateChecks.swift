import Foundation

private func check(_ value: @autoclosure () -> Bool, _ message: String) {
    precondition(value(), message)
}

@main
struct StateChecks {
    static func main() throws {
        try testLegacyStateSurvivesAtomicCatalogMigration()
        try testCatalogSelectionControlsEveryExportMode()
        print("State checks passed")
    }

    // This catches a migration that replaces the old state before it has a complete,
    // validated catalog candidate, or that drops data which 1.3.x already persisted.
    static func testLegacyStateSurvivesAtomicCatalogMigration() throws {
        let legacyJSON = #"""
        {
          "services": [
            {"id":"stable","name":"Stable","category":"Legacy","domains":["stable.example"],"asn":[64501],"addresses":["192.0.2.10"]},
            {"id":"renamed","name":"Old name","category":"Legacy","domains":["rename.example"],"asn":[64502],"addresses":["192.0.2.20"]},
            {"id":"ambiguous","name":"Ambiguous","category":"Legacy","domains":["shared.example"],"addresses":["192.0.2.30"]},
            {"id":"legacy-only","name":"Legacy only","category":"Legacy","domains":["legacy.example"],"addresses":["192.0.2.40"]}
          ],
          "selected": ["stable", "renamed"],
          "manual": [{"address":"203.0.113.7","note":"keep me"}],
          "manualGroups": [{"id":"00000000-0000-0000-0000-000000000001","name":"VPS"}],
          "changes": [{"id":"00000000-0000-0000-0000-000000000002","date":0,"added":["192.0.2.10"],"removed":[],"reason":"old history"}],
          "lastCheck": 100,
          "lastChecks": ["lite", 200],
          "intervalHours": 12,
          "automatic": true,
          "sourceURL": "https://example.test/targeted",
          "categoryBaseURL": "https://example.test/categories/",
          "liteSourceURL": "https://example.test/lite",
          "fullSourceURL": "https://example.test/full",
          "mode": "full",
          "dockIconVisible": false,
          "menuBarIconVisible": true,
          "hasUnseenChanges": true,
          "profiles": [{"id":"00000000-0000-0000-0000-000000000003","name":"Phone","selected":["renamed"],"mode":"lite","manualEnabled":false,"selectAllByDefault":false}]
        }
        """#
        var state = try JSONDecoder().decode(AppState.self, from: Data(legacyJSON.utf8))
        check(state.stateVersion == 13 && state.catalog == nil, "legacy state remains in its 1.3 representation before a validated transaction")
        check(state.sourceRouteSnapshots.isEmpty, "legacy state defaults to no raw source snapshots")
        let original = state
        let invalid = matchedCatalog(services: [CatalogService(id: "duplicate", name: "one"), CatalogService(id: "duplicate", name: "two")])
        check(!state.applyMatchedCatalog(invalid), "invalid candidate must be rejected")
        check(state.services == original.services && state.manual == original.manual && state.profiles == original.profiles
                && state.liteAddresses == original.liteAddresses && state.fullAddresses == original.fullAddresses
                && state.sourceRouteSnapshots == original.sourceRouteSnapshots
                && state.mode == original.mode && state.sourceURL == original.sourceURL && state.lastChecks == original.lastChecks,
              "failed migration must leave state untouched")

        let incoming = [
            CatalogService(id: "stable", name: "Stable", domains: ["stable.example"], asn: [64501], targetedAddresses: ["192.0.2.10"]),
            CatalogService(id: "new-name", name: "New name", domains: ["rename.example"], asn: [64502], targetedAddresses: ["192.0.2.20"]),
            CatalogService(id: "ambiguous-a", name: "Ambiguous A", domains: ["shared.example"], targetedAddresses: ["198.51.100.1"]),
            CatalogService(id: "ambiguous-b", name: "Ambiguous B", domains: ["shared.example"], targetedAddresses: ["198.51.100.2"]),
            CatalogService(id: "brand-new", name: "Brand new", domains: ["new.example"], targetedAddresses: ["198.51.100.3"])
        ]
        check(state.applyMatchedCatalog(matchedCatalog(services: incoming)), "valid catalog applies")
        check(state.stateVersion == 14 && state.catalog != nil, "catalog is persisted after migration")
        check(state.selectedCatalogIDs.contains("stable"), "stable identifier keeps selection")
        check(state.selectedCatalogIDs.contains("new-name"), "unique high-confidence overlap keeps selection")
        check(!state.selectedCatalogIDs.contains("ambiguous-a") && !state.selectedCatalogIDs.contains("ambiguous-b"),
              "ambiguous selection must not silently transfer")
        check(state.catalog!.services.contains { $0.id == "legacy-only" && $0.category == "Дополнительные ресурсы lib4u" },
              "unmatched legacy service remains visible")
        check(state.catalog!.services.contains { $0.id == "ambiguous" && $0.category == "Дополнительные ресурсы lib4u" },
              "ambiguous legacy service remains visible")
        check(state.migrationDiagnostics.contains { $0.legacyServiceID == "ambiguous" }, "ambiguous migration is diagnosed")
        check(state.manual.map(\.address) == ["203.0.113.7"] && state.manual.first?.note == "keep me", "manual entries survive")
        check(state.manualGroups.map(\.name) == ["VPS"], "manual groups survive")
        check(state.changes.first?.reason == "old history" && state.lastCheck == Date(timeIntervalSinceReferenceDate: 100), "history survives")
        check(state.lastCheck(for: .lite) == Date(timeIntervalSinceReferenceDate: 200), "per-mode history survives")
        check(state.intervalHours == 12 && state.automatic, "schedule survives")
        check(state.sourceURL == "https://example.test/targeted" && state.categoryBaseURL == "https://example.test/categories/"
                && state.liteSourceURL == "https://example.test/lite" && state.fullSourceURL == "https://example.test/full",
              "source settings survive")
        check(state.mode == .full && !state.dockIconVisible && state.menuBarIconVisible && state.hasUnseenChanges,
              "existing app preferences survive")
        check(state.profiles.count == 1 && state.profiles[0].selectedCatalogIDs.contains("new-name"), "profile selection migrates")
        check(state.profiles[0].mode == .lite && !state.profiles[0].manualEnabled && !state.profiles[0].selectAllByDefault,
              "profile mode and policies survive")
        check(state.profiles[0].selectedUnassignedModes == Set(CatalogRouteMode.allCases), "legacy profile defaults select source remainders")
        let persisted = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        check(persisted.sourceRouteSnapshots.isEmpty, "empty snapshot default survives the first 1.4 state write")
    }

    // This catches exports that accidentally fall back to the old whole-source
    // Lite/Full sets, lose a shared fragment, or treat the remainder as implicit.
    static func testCatalogSelectionControlsEveryExportMode() throws {
        let alpha = CatalogService(id: "alpha", name: "Alpha", category: "A", targetedAddresses: ["192.0.2.1"], liteAddresses: ["198.51.100.0/31"], fullAddresses: ["203.0.113.0/31"])
        let beta = CatalogService(id: "beta", name: "Beta", category: "A", targetedAddresses: ["192.0.2.2"], liteAddresses: ["198.51.100.0/31"], fullAddresses: ["203.0.113.2/31"])
        let gamma = CatalogService(id: "gamma", name: "Gamma", category: "B", targetedAddresses: ["192.0.2.3"], liteAddresses: ["198.51.100.2/31"], fullAddresses: ["203.0.113.4/31"])
        var state = AppState()
        check(state.applyMatchedCatalog(MatchedCatalog(
            catalog: ServiceCatalog(services: [alpha, beta, gamma]),
            routesByMode: [:],
            unassignedRoutes: [.targeted: ["192.0.2.254"], .lite: ["198.51.100.4/31"], .full: ["203.0.113.6/31"]],
            diagnostics: [], freshness: .fresh
        )), "initial catalog applies")
        check(state.selectedCatalogIDs == ["alpha", "beta", "gamma"], "all services are selected by default")
        check(state.selectedUnassignedModes == Set(CatalogRouteMode.allCases), "all source remainders are selected by default")
        check(state.manualEnabled, "My IP is selected by default")
        state.manual = [ManualEntry(address: "203.0.113.250")]

        state.setCategorySelection("A", enabled: false)
        check(!state.selectedCatalogIDs.contains("alpha") && !state.selectedCatalogIDs.contains("beta"), "category selection changes every child")
        for (mode, expected) in [
            (ExportMode.targeted, Set(["192.0.2.3", "192.0.2.254", "203.0.113.250"])),
            (ExportMode.lite, Set(["198.51.100.2/31", "198.51.100.4/31", "203.0.113.250"])),
            (ExportMode.full, Set(["203.0.113.4/31", "203.0.113.6/31", "203.0.113.250"]))
        ] {
            check(state.exportRoutes(for: mode) == expected, "unchecked services are excluded in \(mode.rawValue)")
        }

        state.setCatalogSelection(["alpha"], enabled: true)
        check(state.exportRoutes(for: .lite).contains("198.51.100.0/31"), "shared route remains for selected owner")
        state.setCatalogSelection(["beta"], enabled: true)
        state.setCatalogSelection(["alpha"], enabled: false)
        check(state.exportRoutes(for: .lite).contains("198.51.100.0/31"), "shared route remains for another selected owner")
        state.setUnassignedSelection(.full, enabled: false)
        check(!state.exportRoutes(for: .full).contains("203.0.113.6/31"), "unassigned route has its own selection")
        state.manualEnabled = false
        check(!state.exportRoutes(for: .targeted).contains("203.0.113.250"), "manual setting still controls My IP")
        let rows = try JSONDecoder().decode([AmneziaEntry].self, from: exportData(state.exportRoutes(for: .lite)))
        check(rows.allSatisfy { $0.ip == "" && $0.ips == [] }, "catalog exports retain AmneziaVPN JSON shape")
    }

    private static func matchedCatalog(services: [CatalogService]) -> MatchedCatalog {
        MatchedCatalog(catalog: ServiceCatalog(services: services), routesByMode: [:], unassignedRoutes: [:], diagnostics: [], freshness: .fresh)
    }
}
