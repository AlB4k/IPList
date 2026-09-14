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
struct Service: Codable, Identifiable {
    var id: String
    var name: String
    var category: String
    var domains: [String]
    var addresses: [String]
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

struct SelectionProfile: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var selected: Set<String>
    var mode: ExportMode
    var manualEnabled: Bool
    var selectAllByDefault: Bool
}

struct AppState: Codable {
    var services: [Service] = []
    var selected: Set<String> = []
    var manual: [String] = []
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
        let automaticAddresses: Set<String>
        switch mode {
        case .targeted:
            automaticAddresses = Set(services.filter { selected.contains($0.id) }.flatMap(\.addresses))
        case .lite:
            automaticAddresses = liteAddresses
        case .full:
            automaticAddresses = fullAddresses
        }
        return automaticAddresses.union(manualEnabled ? manual : [])
    }
    var exportReady: Bool {
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
    }

    mutating func saveProfile(name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        if let index = profiles.firstIndex(where: { $0.name.localizedCaseInsensitiveCompare(clean) == .orderedSame }) {
            let id = profiles[index].id
            profiles[index] = SelectionProfile(id: id, name: clean, selected: selected, mode: mode, manualEnabled: manualEnabled, selectAllByDefault: selectAllByDefault)
        } else {
            profiles.append(SelectionProfile(name: clean, selected: selected, mode: mode, manualEnabled: manualEnabled, selectAllByDefault: selectAllByDefault))
        }
        profiles.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    @discardableResult mutating func applyProfile(id: UUID) -> Bool {
        guard let profile = profiles.first(where: { $0.id == id }) else { return false }
        selected = profile.selected.intersection(Set(services.map(\.id)))
        mode = profile.mode
        manualEnabled = profile.manualEnabled
        selectAllByDefault = profile.selectAllByDefault
        selectionInitialized = true
        return true
    }

    mutating func deleteProfile(id: UUID) { profiles.removeAll { $0.id == id } }
    func lastCheck(for mode: ExportMode) -> Date? { lastChecks[mode] ?? (mode == .targeted ? lastCheck : nil) }
    mutating func markChecked(_ mode: ExportMode, at date: Date = Date()) {
        lastChecks[mode] = date
        if mode == .targeted { lastCheck = date }
    }

    private enum CodingKeys: String, CodingKey {
        case services, selected, manual, manualEnabled, changes, lastCheck, intervalHours, automatic
        case sourceURL, categoryBaseURL, liteSourceURL, fullSourceURL, mode, liteAddresses, fullAddresses
        case profiles, selectionInitialized, selectAllByDefault, lastChecks
        case dockIconVisible, menuBarIconVisible, hasUnseenChanges
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        services = try c.decodeIfPresent([Service].self, forKey: .services) ?? []
        selected = try c.decodeIfPresent(Set<String>.self, forKey: .selected) ?? []
        manual = try c.decodeIfPresent([String].self, forKey: .manual) ?? []
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
            let knownIDs = Set(services.map(\.id))
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
    }
}

enum CatalogSources {
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
struct SourceCheck: Identifiable, Codable {
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

    init(session: URLSession = .shared, timeout: TimeInterval = 18, retryCount: Int = 1) {
        self.session = session
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
func exportData(_ addresses: Set<String>) throws -> Data {
    let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(addresses.sorted().map { AmneziaEntry(hostname: $0, ip: "", ips: []) })
}
