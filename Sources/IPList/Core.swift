import Foundation
import Darwin

struct AmneziaEntry: Codable {
    var hostname: String
    var ip: String?
    var ips: [String]?
    var addresses: [String] { ([hostname, ip ?? ""] + (ips ?? [])).compactMap(normalizeIP) }
}
func normalizeIP(_ raw: String) -> String? {
    let pieces = raw.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
    guard pieces.count == 1 || pieces.count == 2 else { return nil }
    var addr = in_addr()
    guard inet_pton(AF_INET, String(pieces[0]), &addr) == 1 else { return nil }
    let prefix: Int
    if pieces.count == 2 { guard let n = Int(pieces[1]), (0...32).contains(n) else { return nil }; prefix = n } else { prefix = 32 }
    let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    let value = UInt32(bigEndian: addr.s_addr) & mask
    let ip = [24,16,8,0].map { String((value >> $0) & 255) }.joined(separator: ".")
    return prefix == 32 ? ip : "\(ip)/\(prefix)"
}
struct Service: Codable, Identifiable, Equatable {
    var id: String
    var name: String
    var category: String
    var domains: [String]
    var asn: [Int] = []
    var addresses: [String]

    init(id: String, name: String, category: String, domains: [String], asn: [Int] = [], addresses: [String]) {
        self.id = id
        self.name = name
        self.category = category
        self.domains = domains
        self.asn = asn
        self.addresses = addresses
    }

    private enum CodingKeys: String, CodingKey { case id, name, category, domains, asn, asns, addresses }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decode(String.self, forKey: .id),
            name: try c.decode(String.self, forKey: .name),
            category: try c.decodeIfPresent(String.self, forKey: .category) ?? "Без категории",
            domains: try c.decodeIfPresent([String].self, forKey: .domains) ?? [],
            asn: try c.decodeIfPresent([Int].self, forKey: .asn) ?? (try c.decodeIfPresent([Int].self, forKey: .asns)) ?? [],
            addresses: try c.decodeIfPresent([String].self, forKey: .addresses) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(category, forKey: .category)
        try c.encode(domains, forKey: .domains)
        try c.encode(asn, forKey: .asn)
        try c.encode(addresses, forKey: .addresses)
    }
}
struct Change: Codable, Identifiable {
    var id = UUID()
    var date = Date()
    var added: [String]
    var removed: [String]
    var reason: String
}

enum ExportMode: String, Codable, CaseIterable, Identifiable {
    case targeted
    case lite
    case full

    var id: String { rawValue }
    var title: String {
        switch self {
        case .targeted: return "Точечный обход"
        case .lite: return "Компактный IP-список"
        case .full: return "Полный российский сегмент"
        }
    }
    var detail: String {
        switch self {
        case .targeted: return "Только выбранные сервисы. Подходит, когда нужен точный контроль."
        case .lite: return "Компактный список сетей сервисов. Рекомендуется для Android и iOS."
        case .full: return "Максимальное покрытие российских IPv4-сетей. Рекомендуется для компьютера."
        }
    }
    var sourceURL: String {
        switch self {
        case .targeted: return CatalogSources.targetedRelease
        case .lite: return CatalogSources.liteRelease
        case .full: return CatalogSources.fullRelease
        }
    }
}

struct IPGroup: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
}

struct ManualEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var address: String
    var groupID: UUID?
    var note: String = ""

    private enum CodingKeys: String, CodingKey { case id, address, groupID, note }

    init(id: UUID = UUID(), address: String, groupID: UUID? = nil, note: String = "") {
        self.id = id
        self.address = address
        self.groupID = groupID
        self.note = note
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            address: try c.decode(String.self, forKey: .address),
            groupID: try c.decodeIfPresent(UUID.self, forKey: .groupID),
            note: try c.decodeIfPresent(String.self, forKey: .note) ?? ""
        )
    }
}

struct SelectionProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var selected: Set<String>
    var selectedUnassignedModes: Set<CatalogRouteMode> = Set(CatalogRouteMode.allCases)
    var mode: ExportMode
    var manualEnabled: Bool
    var selectAllByDefault: Bool

    var selectedCatalogIDs: Set<String> {
        get { selected }
        set { selected = newValue }
    }

    init(id: UUID = UUID(), name: String, selected: Set<String>, selectedUnassignedModes: Set<CatalogRouteMode> = Set(CatalogRouteMode.allCases), mode: ExportMode, manualEnabled: Bool, selectAllByDefault: Bool) {
        self.id = id
        self.name = name
        self.selected = selected
        self.selectedUnassignedModes = selectedUnassignedModes
        self.mode = mode
        self.manualEnabled = manualEnabled
        self.selectAllByDefault = selectAllByDefault
    }

    private enum CodingKeys: String, CodingKey { case id, name, selected, selectedCatalogIDs, selectedUnassignedModes, mode, manualEnabled, selectAllByDefault }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID(),
            name: try c.decodeIfPresent(String.self, forKey: .name) ?? "",
            selected: try c.decodeIfPresent(Set<String>.self, forKey: .selectedCatalogIDs) ?? (try c.decodeIfPresent(Set<String>.self, forKey: .selected)) ?? [],
            selectedUnassignedModes: try c.decodeIfPresent(Set<CatalogRouteMode>.self, forKey: .selectedUnassignedModes) ?? Set(CatalogRouteMode.allCases),
            mode: try c.decodeIfPresent(ExportMode.self, forKey: .mode) ?? .targeted,
            manualEnabled: try c.decodeIfPresent(Bool.self, forKey: .manualEnabled) ?? true,
            selectAllByDefault: try c.decodeIfPresent(Bool.self, forKey: .selectAllByDefault) ?? true
        )
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(selected, forKey: .selected)
        try c.encode(selected, forKey: .selectedCatalogIDs)
        try c.encode(selectedUnassignedModes, forKey: .selectedUnassignedModes)
        try c.encode(mode, forKey: .mode)
        try c.encode(manualEnabled, forKey: .manualEnabled)
        try c.encode(selectAllByDefault, forKey: .selectAllByDefault)
    }
}

struct AppState: Codable {
    /// 13 denotes a decoded legacy state.  The state moves to 14 only after a
    /// complete matched catalog has been accepted.
    var stateVersion = 14
    var services: [Service] = []
    var selected: Set<String> = []
    var catalog: ServiceCatalog?
    var selectedCatalogIDs: Set<String> = []
    var selectedUnassignedModes: Set<CatalogRouteMode> = Set(CatalogRouteMode.allCases)
    var unassignedRoutes: [CatalogRouteMode: [String]] = [:]
    var cachedEnrichment: EnrichmentSnapshot?
    var migrationDiagnostics: [StateMigrationDiagnostic] = []
    var manual: [ManualEntry] = []
    var manualGroups: [IPGroup] = []
    var manualEnabled = true
    var changes: [Change] = []
    var lastCheck: Date?
    var intervalHours = 24
    var automatic = false
    var sourceURL = "https://raw.githubusercontent.com/lib4u/amnezia-tunneling-ru/main/amnezia.json"
    var categoryBaseURL = "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/"
    var liteSourceURL = CatalogSources.liteRelease
    var fullSourceURL = CatalogSources.fullRelease
    var mode: ExportMode = .targeted
    var liteAddresses: Set<String> = []
    var fullAddresses: Set<String> = []
    var profiles: [SelectionProfile] = []
    var selectionInitialized = false
    var selectAllByDefault = true
    var lastChecks: [ExportMode: Date] = [:]
    var dockIconVisible = true
    var menuBarIconVisible = true
    var hasUnseenChanges = false

    var export: Set<String> {
        exportRoutes(for: mode)
    }

    func exportRoutes(for mode: ExportMode) -> Set<String> {
        let catalogMode = CatalogRouteMode(rawValue: mode.rawValue)!
        let automaticAddresses: Set<String>
        if let catalog {
            automaticAddresses = Set(catalog.services
                .filter { selectedCatalogIDs.contains($0.id) }
                .flatMap { service in
                    switch catalogMode {
                    case .targeted: return service.targetedAddresses
                    case .lite: return service.liteAddresses
                    case .full: return service.fullAddresses
                    }
                })
                .union(selectedUnassignedModes.contains(catalogMode) ? Set(unassignedRoutes[catalogMode] ?? []) : [])
        } else {
            switch mode {
            case .targeted:
                automaticAddresses = Set(services.filter { selected.contains($0.id) }.flatMap(\.addresses))
            case .lite:
                automaticAddresses = liteAddresses
            case .full:
                automaticAddresses = fullAddresses
            }
        }
        return automaticAddresses.union(manualEnabled ? Set(manual.map(\.address)) : [])
    }
    var exportReady: Bool {
        if let catalog {
            let catalogMode = CatalogRouteMode(rawValue: mode.rawValue)!
            let routes = catalog.services.flatMap { service -> [String] in
                switch catalogMode {
                case .targeted: return service.targetedAddresses
                case .lite: return service.liteAddresses
                case .full: return service.fullAddresses
                }
            } + (unassignedRoutes[catalogMode] ?? [])
            return !routes.isEmpty
        }
        switch mode {
        case .targeted: return !services.isEmpty
        case .lite: return !liteAddresses.isEmpty
        case .full: return !fullAddresses.isEmpty
        }
    }

    mutating func applyCatalog(_ catalog: [Service]) {
        let previousIDs = Set(services.map(\.id))
        let incomingIDs = Set(catalog.map(\.id))
        if !selectionInitialized {
            // Empty selection in states written by earlier versions meant “not set up”.
            // The new product default is that every service is selected.
            selected = incomingIDs
            selectionInitialized = true
        } else {
            selected.formIntersection(incomingIDs)
            if selectAllByDefault {
                selected.formUnion(incomingIDs.subtracting(previousIDs))
            }
        }
        services = catalog
        selectedCatalogIDs = selected
    }

    /// Accepts a complete matcher result in one assignment.  The method does
    /// not mutate legacy state when the candidate cannot be represented safely.
    @discardableResult mutating func applyMatchedCatalog(_ matched: MatchedCatalog, cachedEnrichment: EnrichmentSnapshot? = nil) -> Bool {
        let incomingIDs = matched.catalog.services.map(\.id)
        guard Set(incomingIDs).count == incomingIDs.count,
              matched.routesByMode.values.allSatisfy({ Set($0.keys).isSubset(of: Set(incomingIDs)) }) else {
            return false
        }

        var incoming = matched.catalog.services
        for index in incoming.indices {
            let id = incoming[index].id
            if let routes = matched.routesByMode[.targeted]?[id] { incoming[index].targetedAddresses = routes }
            if let routes = matched.routesByMode[.lite]?[id] { incoming[index].liteAddresses = routes }
            if let routes = matched.routesByMode[.full]?[id] { incoming[index].fullAddresses = routes }
        }
        let previous = catalog?.services ?? services.map { legacy in
            CatalogService(id: legacy.id, name: legacy.name, category: legacy.category, domains: legacy.domains, asn: legacy.asn, targetedAddresses: legacy.addresses)
        }
        let resolution = Self.resolveLegacyServices(previous, against: incoming)
        let finalServices = incoming + resolution.unmatched
        let currentSelection = catalog == nil ? selected : selectedCatalogIDs
        let newSelection = Self.migratedSelection(
            selected: currentSelection,
            incomingIDs: Set(incomingIDs),
            resolution: resolution,
            selectAllByDefault: selectAllByDefault
        )
        let newProfiles = profiles.map { profile -> SelectionProfile in
            var migrated = profile
            migrated.selectedCatalogIDs = Self.migratedSelection(
                selected: profile.selectedCatalogIDs,
                incomingIDs: Set(incomingIDs),
                resolution: resolution,
                selectAllByDefault: profile.selectAllByDefault
            )
            return migrated
        }
        let finalCatalog = ServiceCatalog(services: finalServices, freshness: matched.catalog.freshness, sourceURL: matched.catalog.sourceURL, loadedAt: matched.catalog.loadedAt)
        let compatibilityServices = finalServices.map { service in
            Service(id: service.id, name: service.name, category: service.category, domains: service.domains, asn: service.asn, addresses: service.targetedAddresses)
        }
        let newLiteAddresses = Set(finalServices.flatMap(\.liteAddresses)).union(matched.unassignedRoutes[.lite] ?? [])
        let newFullAddresses = Set(finalServices.flatMap(\.fullAddresses)).union(matched.unassignedRoutes[.full] ?? [])

        stateVersion = 14
        catalog = finalCatalog
        services = compatibilityServices
        selectedCatalogIDs = newSelection
        selected = newSelection // Retained for 1.3 UI/state compatibility.
        unassignedRoutes = matched.unassignedRoutes
        self.cachedEnrichment = cachedEnrichment ?? self.cachedEnrichment
        migrationDiagnostics = resolution.diagnostics
        profiles = newProfiles
        liteAddresses = newLiteAddresses
        fullAddresses = newFullAddresses
        selectionInitialized = true
        return true
    }

    mutating func setCatalogSelection(_ ids: some Sequence<String>, enabled: Bool) {
        for id in ids {
            if enabled { selectedCatalogIDs.insert(id) } else { selectedCatalogIDs.remove(id) }
        }
        selected = selectedCatalogIDs
        selectionInitialized = true
        selectAllByDefault = catalog.map { Set($0.services.map(\.id)).isSubset(of: selectedCatalogIDs) } ?? false
    }

    mutating func setCategorySelection(_ category: String, enabled: Bool) {
        setCatalogSelection((catalog?.services ?? []).filter { $0.category == category }.map(\.id), enabled: enabled)
    }

    mutating func setUnassignedSelection(_ mode: ExportMode, enabled: Bool) {
        let catalogMode = CatalogRouteMode(rawValue: mode.rawValue)!
        if enabled { selectedUnassignedModes.insert(catalogMode) } else { selectedUnassignedModes.remove(catalogMode) }
    }

    mutating func saveProfile(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let index = profiles.firstIndex(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            let id = profiles[index].id
            profiles[index] = SelectionProfile(id: id, name: clean, selected: selectedCatalogIDs, selectedUnassignedModes: selectedUnassignedModes, mode: mode, manualEnabled: manualEnabled, selectAllByDefault: selectAllByDefault)
        } else {
            profiles.append(SelectionProfile(name: clean, selected: selectedCatalogIDs, selectedUnassignedModes: selectedUnassignedModes, mode: mode, manualEnabled: manualEnabled, selectAllByDefault: selectAllByDefault))
        }
        profiles.sort { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult mutating func applyProfile(id: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }) else { return false }
        let knownIDs = Set((catalog?.services.map(\.id) ?? services.map(\.id)))
        selectedCatalogIDs = profile.selectedCatalogIDs.intersection(knownIDs)
        selected = selectedCatalogIDs
        selectedUnassignedModes = profile.selectedUnassignedModes
        mode = profile.mode
        manualEnabled = profile.manualEnabled
        selectAllByDefault = profile.selectAllByDefault
        selectionInitialized = true
        return true
    }

    mutating func deleteProfile(id: UUID) { profiles.removeAll { $0.id == id } }

    @discardableResult mutating func addGroup(name: String) -> Bool {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, !manualGroups.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) else { return false }
        manualGroups.append(IPGroup(name: clean))
        manualGroups.sort { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
        return true
    }
    mutating func renameGroup(id: UUID, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, let index = manualGroups.firstIndex(where: { $0.id == id }) else { return }
        manualGroups[index].name = clean
        manualGroups.sort { $0.name.caseInsensitiveCompare($1.name) == .orderedAscending }
    }
    mutating func deleteGroup(id: UUID) {
        manualGroups.removeAll { $0.id == id }
        for index in manual.indices where manual[index].groupID == id { manual[index].groupID = nil }
    }
    func lastCheck(for mode: ExportMode) -> Date? { lastChecks[mode] ?? (mode == .targeted ? lastCheck : nil) }
    mutating func markChecked(_ mode: ExportMode, at date: Date = Date()) {
        lastChecks[mode] = date
        if mode == .targeted { lastCheck = date }
    }

    private enum CodingKeys: String, CodingKey {
        case stateVersion, services, selected, catalog, selectedCatalogIDs, selectedUnassignedModes, unassignedRoutes, cachedEnrichment, migrationDiagnostics
        case manual, manualEnabled, changes, lastCheck, intervalHours, automatic
        case sourceURL, categoryBaseURL, liteSourceURL, fullSourceURL, mode, liteAddresses, fullAddresses
        case profiles, selectionInitialized, selectAllByDefault, lastChecks
        case dockIconVisible, menuBarIconVisible, hasUnseenChanges
        case manualGroups
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        stateVersion = try c.decodeIfPresent(Int.self, forKey: .stateVersion) ?? 13
        services = try c.decodeIfPresent([Service].self, forKey: .services) ?? []
        selected = try c.decodeIfPresent(Set<String>.self, forKey: .selected) ?? []
        catalog = try c.decodeIfPresent(ServiceCatalog.self, forKey: .catalog)
        selectedCatalogIDs = try c.decodeIfPresent(Set<String>.self, forKey: .selectedCatalogIDs) ?? selected
        selectedUnassignedModes = try c.decodeIfPresent(Set<CatalogRouteMode>.self, forKey: .selectedUnassignedModes) ?? Set(CatalogRouteMode.allCases)
        unassignedRoutes = try c.decodeIfPresent([CatalogRouteMode: [String]].self, forKey: .unassignedRoutes) ?? [:]
        cachedEnrichment = try c.decodeIfPresent(EnrichmentSnapshot.self, forKey: .cachedEnrichment)
        migrationDiagnostics = try c.decodeIfPresent([StateMigrationDiagnostic].self, forKey: .migrationDiagnostics) ?? []
        if let entries = try? c.decodeIfPresent([ManualEntry].self, forKey: .manual) {
            manual = entries
        } else {
            // Pre-grouping releases stored manual addresses as plain strings.
            let old = try c.decodeIfPresent([String].self, forKey: .manual) ?? []
            manual = old.map { ManualEntry(address: $0) }
        }
        manualGroups = try c.decodeIfPresent([IPGroup].self, forKey: .manualGroups) ?? []
        manualEnabled = try c.decodeIfPresent(Bool.self, forKey: .manualEnabled) ?? true
        changes = try c.decodeIfPresent([Change].self, forKey: .changes) ?? []
        lastCheck = try c.decodeIfPresent(Date.self, forKey: .lastCheck)
        intervalHours = try c.decodeIfPresent(Int.self, forKey: .intervalHours) ?? 24
        automatic = try c.decodeIfPresent(Bool.self, forKey: .automatic) ?? false
        sourceURL = try c.decodeIfPresent(String.self, forKey: .sourceURL) ?? CatalogSources.targetedRaw
        categoryBaseURL = try c.decodeIfPresent(String.self, forKey: .categoryBaseURL) ?? CatalogSources.categoryRawBase
        liteSourceURL = try c.decodeIfPresent(String.self, forKey: .liteSourceURL) ?? CatalogSources.liteRelease
        fullSourceURL = try c.decodeIfPresent(String.self, forKey: .fullSourceURL) ?? CatalogSources.fullRelease
        mode = try c.decodeIfPresent(ExportMode.self, forKey: .mode) ?? .targeted
        liteAddresses = try c.decodeIfPresent(Set<String>.self, forKey: .liteAddresses) ?? []
        fullAddresses = try c.decodeIfPresent(Set<String>.self, forKey: .fullAddresses) ?? []
        profiles = try c.decodeIfPresent([SelectionProfile].self, forKey: .profiles) ?? []
        let hadSelectionPolicy = c.contains(.selectAllByDefault)
        selectAllByDefault = try c.decodeIfPresent(Bool.self, forKey: .selectAllByDefault) ?? true
        lastChecks = try c.decodeIfPresent([ExportMode: Date].self, forKey: .lastChecks) ?? [:]
        dockIconVisible = try c.decodeIfPresent(Bool.self, forKey: .dockIconVisible) ?? true
        menuBarIconVisible = try c.decodeIfPresent(Bool.self, forKey: .menuBarIconVisible) ?? true
        hasUnseenChanges = try c.decodeIfPresent(Bool.self, forKey: .hasUnseenChanges) ?? false
        if c.contains(.selectionInitialized) {
            selectionInitialized = try c.decode(Bool.self, forKey: .selectionInitialized)
        } else {
            let knownIDs = Set((catalog?.services ?? services.map { CatalogService(id: $0.id, name: $0.name) }).map(\.id))
            if selected.isEmpty && !knownIDs.isEmpty {
                // Earlier releases started with an empty set. Migrate it immediately
                // so a temporarily unavailable network does not leave the catalog off.
                selected = knownIDs
                selectionInitialized = true
            } else {
                selectionInitialized = !selected.isEmpty
            }
            if !hadSelectionPolicy {
                // A partial old selection was deliberate; only an all-selected old
                // state should automatically include services discovered in future.
                selectAllByDefault = selected.isEmpty || knownIDs.isSubset(of: selected)
            }
        }
        if catalog == nil { selectedCatalogIDs = selected }
    }

    private struct LegacyResolution {
        var mappings: [String: String]
        var unmatched: [CatalogService]
        var diagnostics: [StateMigrationDiagnostic]
    }

    private static func resolveLegacyServices(_ old: [CatalogService], against incoming: [CatalogService]) -> LegacyResolution {
        let incomingByID = Dictionary(uniqueKeysWithValues: incoming.map { ($0.id, $0) })
        var mappings: [String: String] = [:]
        let unresolved = old.filter { oldService in
            guard incomingByID[oldService.id] != nil else { return true }
            mappings[oldService.id] = oldService.id
            return false
        }
        var potential: [String: [String]] = [:]
        for oldService in unresolved {
            potential[oldService.id] = incoming.filter { hasHighConfidenceOverlap(oldService, $0) }.map(\.id)
        }
        var originsByCandidate: [String: [String]] = [:]
        for (oldID, candidates) in potential where candidates.count == 1 {
            originsByCandidate[candidates[0], default: []].append(oldID)
        }
        var diagnostics: [StateMigrationDiagnostic] = []
        var mappedOldIDs: Set<String> = Set(mappings.keys)
        for oldService in unresolved {
            let candidates = potential[oldService.id] ?? []
            if candidates.count == 1, originsByCandidate[candidates[0]]?.count == 1 {
                mappings[oldService.id] = candidates[0]
                mappedOldIDs.insert(oldService.id)
            } else if candidates.count > 1 || (candidates.count == 1 && (originsByCandidate[candidates[0]]?.count ?? 0) > 1) {
                diagnostics.append(StateMigrationDiagnostic(
                    legacyServiceID: oldService.id,
                    candidateServiceIDs: candidates,
                    message: "Выбор не перенесён: соответствие старого сервиса неоднозначно."
                ))
            }
        }
        let unmatched = unresolved.filter { !mappedOldIDs.contains($0.id) }.map { oldService in
            CatalogService(id: oldService.id, name: oldService.name, category: "Дополнительные ресурсы lib4u", domains: oldService.domains, asn: oldService.asn, ipRanges: oldService.ipRanges, targetedAddresses: oldService.targetedAddresses, liteAddresses: oldService.liteAddresses, fullAddresses: oldService.fullAddresses)
        }
        return LegacyResolution(mappings: mappings, unmatched: unmatched, diagnostics: diagnostics)
    }

    private static func hasHighConfidenceOverlap(_ old: CatalogService, _ incoming: CatalogService) -> Bool {
        let oldDomains = Set(old.domains.map { $0.lowercased() })
        let incomingDomains = Set(incoming.domains.map { $0.lowercased() })
        return !oldDomains.intersection(incomingDomains).isEmpty || !Set(old.asn).intersection(incoming.asn).isEmpty
    }

    private static func migratedSelection(selected: Set<String>, incomingIDs: Set<String>, resolution: LegacyResolution, selectAllByDefault: Bool) -> Set<String> {
        var result = Set(resolution.mappings.compactMap { selected.contains($0.key) ? $0.value : nil })
        result.formUnion(resolution.unmatched.map(\.id).filter(selected.contains))
        if selectAllByDefault { result.formUnion(incomingIDs.subtracting(Set(resolution.mappings.values))) }
        return result
    }

    /// Commits an already validated refresh candidate as one state replacement.
    /// A rejected candidate never leaks its catalog, cached evidence, or check
    /// timestamps into the persisted state.
    @discardableResult mutating func applyRefreshTransaction(_ transaction: RefreshTransaction) -> Bool {
        var candidate = self
        guard candidate.applyMatchedCatalog(transaction.matchedCatalog, cachedEnrichment: transaction.enrichment.snapshot) else {
            return false
        }
        for mode in ExportMode.allCases {
            candidate.markChecked(mode, at: transaction.completedAt)
        }
        self = candidate
        return true
    }
}

struct RefreshSourceURLs: Equatable, Sendable {
    var metadata: String
    var targeted: String
    var lite: String
    var full: String

    init(
        metadata: String = CatalogSources.metadataRaw,
        targeted: String = CatalogSources.targetedRelease,
        lite: String = CatalogSources.liteRelease,
        full: String = CatalogSources.fullRelease
    ) {
        self.metadata = metadata
        self.targeted = targeted
        self.lite = lite
        self.full = full
    }
}

struct RefreshRequest: Sendable {
    var previousCatalog: ServiceCatalog?
    var cachedEnrichment: EnrichmentSnapshot?
    var urls: RefreshSourceURLs

    init(state: AppState, urls: RefreshSourceURLs? = nil) {
        if let existing = state.catalog {
            let metadataServices = existing.services.filter { $0.category != "Дополнительные ресурсы lib4u" }
            previousCatalog = ServiceCatalog(
                services: metadataServices,
                freshness: existing.freshness,
                sourceURL: existing.sourceURL,
                loadedAt: existing.loadedAt
            )
        } else {
            previousCatalog = nil
        }
        cachedEnrichment = state.cachedEnrichment
        self.urls = urls ?? RefreshSourceURLs(
            targeted: state.sourceURL,
            lite: state.liteSourceURL,
            full: state.fullSourceURL
        )
    }
}

struct RefreshTransaction: Sendable {
    var matchedCatalog: MatchedCatalog
    var enrichment: EnrichmentRefreshResult
    var sourceChecks: [SourceCheck]
    var sourceRoutes: [ExportMode: Set<String>]
    var completedAt: Date
}

struct RefreshPipelineDependencies: Sendable {
    var loadCatalog: @Sendable (RefreshRequest) async throws -> ServiceCatalog
    var loadTargeted: @Sendable (RefreshRequest) async throws -> [TargetedRoute]
    var loadLite: @Sendable (RefreshRequest) async throws -> [String]
    var loadFull: @Sendable (RefreshRequest) async throws -> [String]
    var enrich: @Sendable (ServiceCatalog, EnrichmentSnapshot?) async throws -> EnrichmentRefreshResult
    var match: @Sendable (ServiceCatalog, [TargetedRoute], [String], [String], EnrichmentSnapshot?) throws -> MatchedCatalog
}

enum RefreshPipelineError: LocalizedError {
    case sourceFailure([SourceCheck])
    case deadlineExceeded([SourceCheck])
    case validationFailure([SourceCheck], String)

    var sourceChecks: [SourceCheck] {
        switch self {
        case .sourceFailure(let checks), .deadlineExceeded(let checks), .validationFailure(let checks, _): return checks
        }
    }

    var isDeadlineExceeded: Bool {
        if case .deadlineExceeded = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .sourceFailure(let checks):
            return checks.first(where: { !$0.success })?.message ?? "Один из источников не обновился"
        case .deadlineExceeded:
            return "Превышено общее время обновления. Предыдущие данные сохранены."
        case .validationFailure(_, let message):
            return message
        }
    }
}

struct RefreshPipeline: Sendable {
    private let dependencies: RefreshPipelineDependencies
    private let overallTimeout: TimeInterval

    init(dependencies: RefreshPipelineDependencies, overallTimeout: TimeInterval = EnrichmentLimits.overallTimeout) {
        self.dependencies = dependencies
        self.overallTimeout = max(0.01, overallTimeout)
    }

    static func live() -> RefreshPipeline {
        let routeLoader = CatalogLoader()
        let metadataLoader = ServiceCatalogLoader()
        let enricher = ServiceEnricher(dns: SystemDNSResolver(), asn: RIPEStatASNPrefixLoader())
        return RefreshPipeline(
            dependencies: RefreshPipelineDependencies(
                loadCatalog: { request in
                    try await metadataLoader.load(
                        remoteURL: request.urls.metadata,
                        previousCatalog: request.previousCatalog,
                        fallbackCatalog: request.previousCatalog
                    )
                },
                loadTargeted: { request in
                    try await routeLoader.loadTargetedRoutes(source: request.urls.targeted)
                },
                loadLite: { request in
                    Array(try await routeLoader.loadRanges(mode: .lite, source: request.urls.lite)).sorted()
                },
                loadFull: { request in
                    Array(try await routeLoader.loadRanges(mode: .full, source: request.urls.full)).sorted()
                },
                enrich: { catalog, cached in
                    try await enricher.enrich(catalog: catalog, cached: cached)
                },
                match: { catalog, targeted, lite, full, cache in
                    try CatalogMatcher().match(catalog: catalog, targeted: targeted, lite: lite, full: full, cached: cache)
                }
            )
        )
    }

    func run(_ request: RefreshRequest) async throws -> RefreshTransaction {
        try await withOverallDeadline {
            let loaded = try await loadSources(request)
            guard let catalog = loaded.catalog, let targeted = loaded.targeted,
                  let lite = loaded.lite, let full = loaded.full else {
                throw RefreshPipelineError.sourceFailure(loaded.checks)
            }
            try Task.checkCancellation()

            let enrichmentStarted = Date()
            let enrichment: EnrichmentRefreshResult
            do {
                enrichment = try await dependencies.enrich(catalog, request.cachedEnrichment)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = sourceCheck(
                    id: "dns-ripeStat", name: "DNS и RIPEstat", url: "system DNS; RIPEstat",
                    success: false, duration: Date().timeIntervalSince(enrichmentStarted), count: nil,
                    message: error.localizedDescription
                )
                throw RefreshPipelineError.sourceFailure(ordered(loaded.checks + [failure]))
            }
            try Task.checkCancellation()

            let checks = ordered(loaded.checks + enrichmentChecks(enrichment, duration: Date().timeIntervalSince(enrichmentStarted)))
            do {
                let matched = try dependencies.match(catalog, targeted, lite, full, enrichment.snapshot)
                try Task.checkCancellation()
                return RefreshTransaction(
                    matchedCatalog: matched,
                    enrichment: enrichment,
                    sourceChecks: checks,
                    sourceRoutes: [
                        .targeted: Set(targeted.map(\.address)),
                        .lite: Set(lite),
                        .full: Set(full)
                    ],
                    completedAt: Date()
                )
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                let failure = sourceCheck(
                    id: "matching", name: "Сопоставление маршрутов", url: "локальная проверка",
                    success: false, duration: 0, count: nil, message: error.localizedDescription
                )
                throw RefreshPipelineError.validationFailure(ordered(checks + [failure]), error.localizedDescription)
            }
        }
    }

    private func loadSources(_ request: RefreshRequest) async throws -> LoadedSources {
        try await withThrowingTaskGroup(of: SourceOutcome.self) { group in
            group.addTask { try await loadSource(id: "metadata", name: "Каталог сервисов", url: request.urls.metadata) { .catalog(try await dependencies.loadCatalog(request)) } }
            group.addTask { try await loadSource(id: "targeted", name: "Точечный список", url: request.urls.targeted) { .targeted(try await dependencies.loadTargeted(request)) } }
            group.addTask { try await loadSource(id: "lite", name: "Компактный IP-список", url: request.urls.lite) { .lite(try await dependencies.loadLite(request)) } }
            group.addTask { try await loadSource(id: "full", name: "Полный IP-список", url: request.urls.full) { .full(try await dependencies.loadFull(request)) } }

            var loaded = LoadedSources()
            defer { group.cancelAll() }
            while let outcome = try await group.next() {
                loaded.absorb(outcome)
            }
            if loaded.checks.contains(where: { !$0.success }) {
                throw RefreshPipelineError.sourceFailure(ordered(loaded.checks))
            }
            return loaded
        }
    }

    private func withOverallDeadline<Output: Sendable>(
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(overallTimeout * 1_000_000_000))
                try Task.checkCancellation()
                throw RefreshPipelineError.deadlineExceeded([])
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else {
                throw RefreshPipelineError.deadlineExceeded([])
            }
            return result
        }
    }

    private enum SourcePayload: Sendable {
        case catalog(ServiceCatalog)
        case targeted([TargetedRoute])
        case lite([String])
        case full([String])

        var count: Int {
            switch self {
            case .catalog(let catalog): return catalog.services.count
            case .targeted(let routes): return routes.count
            case .lite(let routes), .full(let routes): return routes.count
            }
        }

        var message: String {
            if case .catalog(let catalog) = self, catalog.freshness == .cached {
                return "Использована сохранённая копия"
            }
            return "Обновлено"
        }
    }

    private struct SourceOutcome: Sendable {
        var payload: SourcePayload?
        var check: SourceCheck
    }

    private struct LoadedSources: Sendable {
        var catalog: ServiceCatalog?
        var targeted: [TargetedRoute]?
        var lite: [String]?
        var full: [String]?
        var checks: [SourceCheck] = []

        mutating func absorb(_ outcome: SourceOutcome) {
            checks.append(outcome.check)
            guard let payload = outcome.payload else { return }
            switch payload {
            case .catalog(let value): catalog = value
            case .targeted(let value): targeted = value
            case .lite(let value): lite = value
            case .full(let value): full = value
            }
        }
    }

    private func loadSource(
        id: String,
        name: String,
        url: String,
        operation: @escaping @Sendable () async throws -> SourcePayload
    ) async throws -> SourceOutcome {
        let started = Date()
        do {
            let payload = try await operation()
            try Task.checkCancellation()
            return SourceOutcome(payload: payload, check: sourceCheck(
                id: id, name: name, url: url, success: true,
                duration: Date().timeIntervalSince(started), count: payload.count, message: payload.message
            ))
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return SourceOutcome(payload: nil, check: sourceCheck(
                id: id, name: name, url: url, success: false,
                duration: Date().timeIntervalSince(started), count: nil, message: error.localizedDescription
            ))
        }
    }

    private func enrichmentChecks(_ enrichment: EnrichmentRefreshResult, duration: TimeInterval) -> [SourceCheck] {
        EnrichmentSource.allCases.map { source in
            let diagnostics = enrichment.diagnostics.filter { $0.source == source }
            let evidence = enrichment.snapshot.services.values
            let stale = evidence.contains { $0.freshness == .stale }
            let bundled = evidence.contains { $0.freshness == .bundled }
            let cached = evidence.contains { $0.freshness == .cached }
            let message: String
            if stale { message = diagnostics.first(where: { $0.freshness == .stale })?.message ?? "Использован просроченный кэш" }
            else if bundled { message = "Использован включённый снимок" }
            else if cached { message = "Использован кэш" }
            else { message = diagnostics.first?.message ?? "Обновлено" }
            let count = source == .dns
                ? evidence.reduce(0) { $0 + $1.dnsAddresses.count }
                : evidence.reduce(0) { $0 + $1.asnPrefixes.count }
            return sourceCheck(
                id: source.rawValue,
                name: source == .dns ? "DNS" : "RIPEstat",
                url: source == .dns ? "Системный DNS macOS" : "https://stat.ripe.net",
                success: true, duration: duration, count: count, message: message
            )
        }
    }

    private func sourceCheck(id: String, name: String, url: String, success: Bool, duration: TimeInterval, count: Int?, message: String) -> SourceCheck {
        SourceCheck(id: id, name: name, url: url, success: success, statusCode: nil, duration: duration, addressCount: count, message: message)
    }

    private func ordered(_ checks: [SourceCheck]) -> [SourceCheck] {
        let order = ["metadata", "targeted", "lite", "full", "dns", "ripeStat", "matching", "dns-ripeStat"]
        return checks.sorted { (order.firstIndex(of: $0.id) ?? 99) < (order.firstIndex(of: $1.id) ?? 99) }
    }
}

enum StatePersistence {
    static func write(_ state: AppState, to folder: URL, rawPreMigrationState: Data?) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let backup = folder.appendingPathComponent("state-before-v1.4.json")
        if state.stateVersion >= 14, let rawPreMigrationState,
           !FileManager.default.fileExists(atPath: backup.path) {
            try rawPreMigrationState.write(to: backup, options: .atomic)
        }
        try JSONEncoder().encode(state).write(to: folder.appendingPathComponent("state.json"), options: .atomic)
    }
}

enum CatalogSources {
    static let metadataRaw = "https://raw.githubusercontent.com/pincetgore/amnezia-app-ru-list/main/config.yaml"
    static let targetedRelease = "https://github.com/lib4u/amnezia-tunneling-ru/releases/download/latest/amnezia.json"
    static let targetedRaw = "https://raw.githubusercontent.com/lib4u/amnezia-tunneling-ru/main/amnezia.json"
    static let liteRelease = "https://github.com/lib4u/amnezia-tunneling-ru/releases/download/latest/amnezia-ip-lite.json"
    static let liteRaw = "https://raw.githubusercontent.com/lib4u/amnezia-tunneling-ru/main/amnezia-ip-lite.json"
    static let fullRelease = "https://github.com/lib4u/amnezia-tunneling-ru/releases/download/latest/amnezia-ip.json"
    static let fullRaw = "https://raw.githubusercontent.com/lib4u/amnezia-tunneling-ru/main/amnezia-ip.json"
    static let categoryRawBase = "https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/"
}
let categoryRoots: [(String,String)] = [
    ("category-bank-ru", "Банки и финансы"), ("category-gov-ru", "Государство"),
    ("category-ecommerce-ru", "Маркетплейсы"), ("category-retail-ru", "Магазины"),
    ("category-travel-ru", "Транспорт и путешествия"), ("category-medicine-ru", "Медицина"),
    ("category-media-ru", "СМИ"), ("category-entertainment-ru", "Развлечения"),
    ("yandex", "Поиск и технологии"), ("vk", "Социальные сети"), ("mailru", "Почта"),
    ("2gis", "Карты"), ("kaspersky", "Безопасность"), ("drweb", "Безопасность")
]
struct Rules {
    var domains: Set<String> = []
    var includes: [String] = []
    var groups: [String: Set<String>] = [:]
}
func parseRules(_ text: String) -> Rules {
    var result = Rules(); var group = "Основные домены"
    for raw in text.components(separatedBy: .newlines) {
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("# ") {
            let comment = String(trimmed.dropFirst(2))
            if !comment.contains(":") && !comment.lowercased().hasPrefix("todo") { group = comment }
            continue
        }
        guard let token = raw.components(separatedBy: "#")[0].split(whereSeparator: \.isWhitespace).first.map(String.init) else { continue }
        if token.hasPrefix("include:") { result.includes.append(String(token.dropFirst(8))); continue }
        if token.hasPrefix("regexp:") || token.hasPrefix("keyword:") { continue }
        let domain = token.replacingOccurrences(of: "full:", with: "").replacingOccurrences(of: "domain:", with: "").lowercased()
        guard domain.contains("."), !domain.contains(":") else { continue }
        result.domains.insert(domain); result.groups[group, default: []].insert(domain)
    }
    return result
}
struct SourceCheck: Identifiable, Codable, Sendable {
    var id: String
    var name: String
    var url: String
    var success: Bool
    var statusCode: Int?
    var duration: TimeInterval
    var addressCount: Int?
    var message: String
}

enum CatalogError: LocalizedError {
    case invalidURL(String)
    case timeout(String)
    case network(String, String)
    case http(String, Int)
    case tooLarge(String)
    case empty(String)
    case invalidJSON(String, String)
    case invalidCategory(String)
    case allCandidatesFailed([(String, String)])

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Некорректный HTTPS-адрес источника: \(url)"
        case .timeout(let url): return "Источник не ответил вовремя: \(url)"
        case .network(let url, let reason): return "Не удалось загрузить источник \(url): \(reason)"
        case .http(let url, let status): return "Источник вернул HTTP \(status): \(url)"
        case .tooLarge(let url): return "Источник превышает допустимый размер 30 МБ: \(url)"
        case .empty(let url): return "Источник не содержит пригодных IPv4-адресов: \(url)"
        case .invalidJSON(let url, let reason): return "Некорректные данные источника \(url): \(reason)"
        case .invalidCategory(let url): return "Источник категорий не содержит доменов: \(url)"
        case .allCandidatesFailed(let failures):
            let base = "Не удалось обновить данные. " + failures.map { "\($0.0): \($0.1)" }.joined(separator: "\n")
            let allTimedOut = !failures.isEmpty && failures.allSatisfy { $0.1.localizedCaseInsensitiveContains("не ответил вовремя") }
            guard allTimedOut else { return base }
            return base + "\n\nВсе источники (включая резервный) зависли одинаково — это похоже на блокировку или троттлинг сети провайдером, а не на медленный сервер. Попробуйте включить VPN или другую сеть и повторить проверку."
        }
    }
}

private struct ServiceDefinition: Sendable {
    var id: String
    var name: String
    var category: String
    var domains: Set<String>
}

actor CatalogLoader {
    private var cache: [String: Rules] = [:]
    private let session: URLSession
    private let timeout: TimeInterval
    private let retryCount: Int

    init(session: URLSession? = nil, timeout: TimeInterval = 18, retryCount: Int = 1) {
        if let session {
            self.session = session
        } else {
            // .shared has no hard ceiling on total transfer time (timeoutIntervalForResource
            // defaults to 7 days), so a connection that trickles a few bytes now and then
            // never trips request.timeoutInterval and can hang far longer than `timeout`.
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = timeout
            config.timeoutIntervalForResource = timeout
            self.session = URLSession(configuration: config)
        }
        self.timeout = timeout
        self.retryCount = max(0, retryCount)
    }

    private func fetchOnce(_ url: String) async throws -> (Data, Int) {
        guard let u = URL(string: url), u.scheme?.lowercased() == "https" else { throw CatalogError.invalidURL(url) }
        var request = URLRequest(url: u)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200...299).contains(status) else { throw CatalogError.http(url, status) }
            guard data.count <= 30_000_000 else { throw CatalogError.tooLarge(url) }
            guard !data.isEmpty else { throw CatalogError.empty(url) }
            return (data, status)
        } catch let error as CatalogError {
            throw error
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError where error.code == .timedOut {
            throw CatalogError.timeout(url)
        } catch {
            throw CatalogError.network(url, error.localizedDescription)
        }
    }

    func fetch(_ url: String) async throws -> Data {
        var finalError: Error = CatalogError.network(url, "неизвестная ошибка")
        for attempt in 0...retryCount {
            try Task.checkCancellation()
            do { return try await fetchOnce(url).0 }
            catch is CancellationError { throw CancellationError() }
            catch {
                finalError = error
                guard attempt < retryCount else { break }
                try await Task.sleep(nanoseconds: UInt64(300_000_000 * (attempt + 1)))
            }
        }
        throw finalError
    }

    private func alternate(for url: String) -> String? {
        let pairs = [
            (CatalogSources.targetedRelease, CatalogSources.targetedRaw),
            (CatalogSources.liteRelease, CatalogSources.liteRaw),
            (CatalogSources.fullRelease, CatalogSources.fullRaw)
        ]
        for pair in pairs {
            if url == pair.0 { return pair.1 }
            if url == pair.1 { return pair.0 }
        }
        return nil
    }

    private func fetchWithOfficialFallback(_ url: String) async throws -> (Data, String) {
        let urls = [url, alternate(for: url)].compactMap { $0 }
        var failures: [(String, String)] = []
        for candidate in urls {
            do { return (try await fetch(candidate), candidate) }
            catch { failures.append((candidate, error.localizedDescription)) }
        }
        throw CatalogError.allCandidatesFailed(failures)
    }

    func rules(_ name: String, base: String) async throws -> Rules {
        guard name.range(of: "^[a-zA-Z0-9._-]+$", options: .regularExpression) != nil else {
            throw CatalogError.invalidURL(base + name)
        }
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        let key = normalizedBase + name
        if let r = cache[key] { return r }
        let data = try await fetch(key)
        guard let text = String(data: data, encoding: .utf8) else {
            throw CatalogError.invalidJSON(key, "текст не является UTF-8")
        }
        let r = parseRules(text)
        guard !r.domains.isEmpty || !r.includes.isEmpty else { throw CatalogError.invalidCategory(key) }
        cache[key] = r
        return r
    }

    func domains(_ name: String, base: String, visited: Set<String> = []) async throws -> Set<String> {
        if visited.contains(name) { return [] }
        let r = try await rules(name, base: base)
        var all = r.domains
        for child in r.includes {
            all.formUnion(try await domains(child, base: base, visited: visited.union([name])))
        }
        return all
    }

    private func definitions(root: String, category: String, base: String) async throws -> [ServiceDefinition] {
        let r = try await rules(root, base: base)
        if !root.hasPrefix("category-") {
            return [ServiceDefinition(id: root, name: root, category: category, domains: try await domains(root, base: base))]
        }
        var definitions: [ServiceDefinition] = []
        for name in r.groups.keys.sorted() {
            let groupDomains = r.groups[name] ?? []
            if name == "Other" || name == "Основные домены" {
                definitions += groupDomains.sorted().map {
                    ServiceDefinition(id: root + ":" + $0, name: $0, category: category, domains: [$0])
                }
            } else {
                definitions.append(ServiceDefinition(id: root + ":" + name, name: name, category: category, domains: groupDomains))
            }
        }
        for child in r.includes {
            definitions.append(ServiceDefinition(id: root + ":" + child, name: child, category: category, domains: try await domains(child, base: base)))
        }
        return definitions
    }

    func load(source: String, base: String, progress: (@Sendable (String) -> Void)? = nil) async throws -> [Service] {
        cache = [:]
        progress?("Загрузка точечного списка…")
        let (sourceData, actualURL) = try await fetchWithOfficialFallback(source)
        let entries: [AmneziaEntry]
        do { entries = try JSONDecoder().decode([AmneziaEntry].self, from: sourceData) }
        catch { throw CatalogError.invalidJSON(actualURL, error.localizedDescription) }
        guard !entries.isEmpty else { throw CatalogError.empty(actualURL) }

        progress?("Загрузка категорий…")
        var allDefinitions: [ServiceDefinition] = []
        try await withThrowingTaskGroup(of: [ServiceDefinition].self) { group in
            for (root, category) in categoryRoots {
                group.addTask { try await self.definitions(root: root, category: category, base: base) }
            }
            for try await definitions in group { allDefinitions += definitions }
        }

        progress?("Сопоставление сервисов и адресов…")
        var result: [Service] = []
        var matched = Set<String>()
        for definition in allDefinitions {
            let rows = entries.filter { definition.domains.contains($0.hostname.lowercased()) }
            guard !rows.isEmpty else { continue }
            matched.formUnion(rows.map(\.hostname))
            result.append(Service(
                id: definition.id,
                name: definition.name,
                category: definition.category,
                domains: rows.map(\.hostname).sorted(),
                addresses: Array(Set(rows.flatMap(\.addresses))).sorted()
            ))
        }
        for row in entries where !matched.contains(row.hostname) && !row.addresses.isEmpty {
            result.append(Service(id: "domain:" + row.hostname, name: row.hostname, category: "Прочие ресурсы", domains: [row.hostname], addresses: Array(Set(row.addresses)).sorted()))
        }
        guard result.contains(where: { !$0.addresses.isEmpty }) else { throw CatalogError.empty(actualURL) }
        return result.sorted { ($0.category, $0.name) < ($1.category, $1.name) }
    }

    func loadRanges(mode: ExportMode) async throws -> Set<String> {
        try await loadRanges(mode: mode, source: mode.sourceURL)
    }

    func loadRanges(mode: ExportMode, source: String) async throws -> Set<String> {
        guard mode != .targeted else { return [] }
        let (data, actualURL) = try await fetchWithOfficialFallback(source)
        return try decodeAddresses(data, url: actualURL)
    }

    func loadTargetedRoutes(source: String) async throws -> [TargetedRoute] {
        let (data, actualURL) = try await fetchWithOfficialFallback(source)
        let entries: [AmneziaEntry]
        do { entries = try JSONDecoder().decode([AmneziaEntry].self, from: data) }
        catch { throw CatalogError.invalidJSON(actualURL, error.localizedDescription) }
        let routes = Set(entries.flatMap { entry in
            entry.addresses.map { TargetedRoute(domain: entry.hostname, address: $0) }
        })
        guard !routes.isEmpty else { throw CatalogError.empty(actualURL) }
        return routes.sorted { ($0.address, $0.domain ?? "") < ($1.address, $1.domain ?? "") }
    }

    private func decodeAddresses(_ data: Data, url: String) throws -> Set<String> {
        let entries: [AmneziaEntry]
        do { entries = try JSONDecoder().decode([AmneziaEntry].self, from: data) }
        catch { throw CatalogError.invalidJSON(url, error.localizedDescription) }
        let addresses = Set(entries.flatMap(\.addresses))
        guard !addresses.isEmpty else { throw CatalogError.empty(url) }
        return addresses
    }

    func testSources(
        source: String,
        base: String,
        liteSource: String = CatalogSources.liteRelease,
        fullSource: String = CatalogSources.fullRelease
    ) async -> [SourceCheck] {
        let categoryURL = (base.hasSuffix("/") ? base : base + "/") + "category-bank-ru"
        var descriptors: [(String, String, String, Bool)] = [
            ("targeted", "Точечный список", source, true),
            ("lite", "Компактный IP-список", liteSource, true),
            ("full", "Полный IP-список", fullSource, true),
            ("categories", "Категории сервисов (проверка category-bank-ru)", categoryURL, false)
        ]
        if let reserve = alternate(for: source) { descriptors.insert(("targeted-reserve", "Точечный список — резерв", reserve, true), at: 1) }
        if let reserve = alternate(for: liteSource) {
            let index = (descriptors.firstIndex { $0.0 == "lite" } ?? 0) + 1
            descriptors.insert(("lite-reserve", "Компактный IP-список — резерв", reserve, true), at: index)
        }
        if let reserve = alternate(for: fullSource) {
            let index = (descriptors.firstIndex { $0.0 == "full" } ?? 0) + 1
            descriptors.insert(("full-reserve", "Полный IP-список — резерв", reserve, true), at: index)
        }
        return await withTaskGroup(of: SourceCheck.self) { group in
            for descriptor in descriptors {
                group.addTask { await self.checkSource(id: descriptor.0, name: descriptor.1, url: descriptor.2, json: descriptor.3) }
            }
            var checks: [SourceCheck] = []
            for await check in group { checks.append(check) }
            return checks.sorted { lhs, rhs in
                (descriptors.firstIndex { $0.0 == lhs.id } ?? 99) < (descriptors.firstIndex { $0.0 == rhs.id } ?? 99)
            }
        }
    }

    private func checkSource(id: String, name: String, url: String, json: Bool) async -> SourceCheck {
        let started = Date()
        var receivedStatus: Int?
        do {
            let (data, status) = try await fetchOnce(url)
            receivedStatus = status
            let count: Int?
            if json {
                count = try decodeAddresses(data, url: url).count
            } else {
                guard let text = String(data: data, encoding: .utf8) else { throw CatalogError.invalidJSON(url, "текст не является UTF-8") }
                let parsed = parseRules(text)
                guard !parsed.domains.isEmpty || !parsed.includes.isEmpty else { throw CatalogError.invalidCategory(url) }
                count = parsed.domains.count
            }
            return SourceCheck(id: id, name: name, url: url, success: true, statusCode: status, duration: Date().timeIntervalSince(started), addressCount: count, message: "Доступен")
        } catch {
            let status: Int?
            if case CatalogError.http(_, let code) = error { status = code } else { status = receivedStatus }
            return SourceCheck(id: id, name: name, url: url, success: false, statusCode: status, duration: Date().timeIntervalSince(started), addressCount: nil, message: error.localizedDescription)
        }
    }
}
