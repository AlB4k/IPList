import Foundation

struct ServiceCatalogLimits: Sendable {
    static let maxInputBytes = 4 * 1024 * 1024
    static let maxServices = 2_000
    static let maxDomains = 20_000
    static let maxRanges = 20_000
    static let maxASNs = 20_000
    static let maxFieldBytes = 512

    let maxInputBytes: Int
    let maxServices: Int
    let maxDomains: Int
    let maxRanges: Int
    let maxASNs: Int
    let maxFieldBytes: Int

    init(
        maxInputBytes: Int = ServiceCatalogLimits.maxInputBytes,
        maxServices: Int = ServiceCatalogLimits.maxServices,
        maxDomains: Int = ServiceCatalogLimits.maxDomains,
        maxRanges: Int = ServiceCatalogLimits.maxRanges,
        maxASNs: Int = ServiceCatalogLimits.maxASNs,
        maxFieldBytes: Int = ServiceCatalogLimits.maxFieldBytes
    ) {
        self.maxInputBytes = maxInputBytes
        self.maxServices = maxServices
        self.maxDomains = maxDomains
        self.maxRanges = maxRanges
        self.maxASNs = maxASNs
        self.maxFieldBytes = maxFieldBytes
    }
}

enum ServiceCatalogError: Error, LocalizedError, Equatable {
    case invalidUTF8
    case inputTooLarge(Int)
    case tooManyServices(Int)
    case tooManyDomains(Int)
    case tooManyRanges(Int)
    case tooManyASNs(Int)
    case fieldTooLong(String)
    case emptyCatalog
    case emptyServiceName(Int)
    case serviceWithoutMetadata(String)
    case invalidASN(Int)
    case invalidIPRange(String)
    case duplicateStableID(String)
    case malformed(line: Int, reason: String)
    case suspiciousShrink(previous: Int, candidate: Int)
    case remoteUnavailable(String)
    case noUsableCatalog

    var isInvalidIPRange: Bool {
        if case .invalidIPRange = self { return true }
        return false
    }

    var errorDescription: String? {
        switch self {
        case .invalidUTF8: return "Каталог не является корректным UTF-8 текстом"
        case .inputTooLarge(let bytes): return "Каталог превышает допустимый размер (\(bytes) байт)"
        case .tooManyServices(let count): return "Каталог содержит слишком много сервисов (\(count))"
        case .tooManyDomains(let count): return "Каталог содержит слишком много доменов (\(count))"
        case .tooManyRanges(let count): return "Каталог содержит слишком много диапазонов (\(count))"
        case .tooManyASNs(let count): return "Каталог содержит слишком много ASN (\(count))"
        case .fieldTooLong(let field): return "Поле каталога слишком длинное: \(field)"
        case .emptyCatalog: return "Каталог не содержит сервисов"
        case .emptyServiceName(let line): return "У сервиса отсутствует имя (строка \(line))"
        case .serviceWithoutMetadata(let name): return "У сервиса нет доменов, ASN или диапазонов: \(name)"
        case .invalidASN(let value): return "Некорректный ASN: \(value)"
        case .invalidIPRange(let value): return "Некорректный IPv4-диапазон: \(value)"
        case .duplicateStableID(let id): return "Коллизия стабильного идентификатора сервиса: \(id)"
        case .malformed(let line, let reason): return "Некорректный каталог в строке \(line): \(reason)"
        case .suspiciousShrink(let previous, let candidate):
            return "Каталог неожиданно уменьшился: было \(previous), стало \(candidate)"
        case .remoteUnavailable(let reason): return "Не удалось загрузить каталог: \(reason)"
        case .noUsableCatalog: return "Нет пригодного удалённого или резервного каталога"
        }
    }
}

enum ServiceCatalogParser {
    private struct Builder {
        var line: Int
        var category: String
        var name: String?
        var domains: [String] = []
        var asn: [Int] = []
        var ranges: [String] = []
    }

    private enum ListField { case domains, asn, ranges }

    static func parse(_ data: Data, limits: ServiceCatalogLimits = ServiceCatalogLimits()) throws -> ServiceCatalog {
        guard data.count <= limits.maxInputBytes else {
            throw ServiceCatalogError.inputTooLarge(data.count)
        }
        guard let text = String(data: data, encoding: .utf8) else {
            throw ServiceCatalogError.invalidUTF8
        }
        return try parse(text, limits: limits)
    }

    static func parse(_ text: String, limits: ServiceCatalogLimits = ServiceCatalogLimits()) throws -> ServiceCatalog {
        let byteCount = text.lengthOfBytes(using: .utf8)
        guard byteCount <= limits.maxInputBytes else {
            throw ServiceCatalogError.inputTooLarge(byteCount)
        }

        let lines = text.components(separatedBy: .newlines)
        var services: [CatalogService] = []
        var seenIDs = Set<String>()
        var current: Builder?
        var currentList: (field: ListField, indent: Int)?
        var servicesIndent: Int?
        var category = "Без категории"
        var dividerOpened = false
        var categoryCandidate: String?
        var closingDividerExpected = false
        var insideServices = false
        var totalDomains = 0
        var totalRanges = 0
        var totalASNs = 0

        func finish(_ value: Builder) throws {
            guard let name = value.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
                throw ServiceCatalogError.emptyServiceName(value.line)
            }
            guard name.lengthOfBytes(using: .utf8) <= limits.maxFieldBytes else {
                throw ServiceCatalogError.fieldTooLong("name")
            }
            let serviceCategory = value.category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Без категории" : value.category
            guard !value.domains.isEmpty || !value.asn.isEmpty || !value.ranges.isEmpty else {
                throw ServiceCatalogError.serviceWithoutMetadata(name)
            }
            guard serviceCategory.lengthOfBytes(using: .utf8) <= limits.maxFieldBytes else {
                throw ServiceCatalogError.fieldTooLong("category")
            }
            let id = CatalogService.stableID(source: CatalogService.defaultSource, name: name)
            guard seenIDs.insert(id).inserted else { throw ServiceCatalogError.duplicateStableID(id) }
            services.append(CatalogService(id: id, name: name, category: serviceCategory,
                                           domains: value.domains, asn: value.asn, ipRanges: value.ranges))
            guard services.count <= limits.maxServices else {
                throw ServiceCatalogError.tooManyServices(services.count)
            }
        }

        func closeOpenListIfNeeded(line: Int) throws {
            guard let list = currentList else { return }
            guard let builder = current else {
                currentList = nil
                return
            }
            let hasItems: Bool
            switch list.field {
            case .domains: hasItems = !builder.domains.isEmpty
            case .asn: hasItems = !builder.asn.isEmpty
            case .ranges: hasItems = !builder.ranges.isEmpty
            }
            guard hasItems else {
                throw ServiceCatalogError.malformed(line: line, reason: "пустой список \(list.field)")
            }
            currentList = nil
        }

        for (index, sourceLine) in lines.enumerated() {
            let lineNumber = index + 1
            let indent = sourceLine.prefix { $0 == " " || $0 == "\t" }.count
            let trimmed = sourceLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }

            if insideServices, trimmed.hasPrefix("#"), indent <= (servicesIndent ?? 2) {
                let comment = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if isDivider(comment) {
                    if closingDividerExpected, let candidate = categoryCandidate {
                        category = candidate
                        categoryCandidate = nil
                        closingDividerExpected = false
                        dividerOpened = false
                    } else {
                        category = "Без категории"
                        categoryCandidate = nil
                        closingDividerExpected = false
                        dividerOpened = true
                    }
                } else if dividerOpened, isSupportedCategoryHeading(comment) {
                    categoryCandidate = normalizeCategory(comment)
                    dividerOpened = false
                    closingDividerExpected = true
                } else {
                    category = "Без категории"
                    categoryCandidate = nil
                    dividerOpened = false
                    closingDividerExpected = false
                }
                try closeOpenListIfNeeded(line: lineNumber)
                currentList = nil
                continue
            }

            let uncommented = stripComment(from: sourceLine)
            let body = uncommented.trimmingCharacters(in: .whitespacesAndNewlines)
            if body.isEmpty { continue }

            if indent == 0 && keyAndValue(body)?.key == "services" {
                insideServices = true
                currentList = nil
                continue
            }
            guard insideServices else { continue }

            if body == "-" || body.hasPrefix("- ") {
                if let knownIndent = servicesIndent, indent != knownIndent {
                    // A nested list item belongs to the currently selected field.
                    if let list = currentList, indent > list.indent, var builder = current,
                       let scalar = scalarValue(String(body.dropFirst()).trimmingCharacters(in: .whitespaces)) {
                        try append(scalar: scalar, to: &builder, field: list.field, line: lineNumber, limits: limits,
                                   domains: &totalDomains, ranges: &totalRanges, asns: &totalASNs)
                        current = builder
                    }
                    continue
                }

                try closeOpenListIfNeeded(line: lineNumber)
                if let previous = current { try finish(previous) }
                servicesIndent = servicesIndent ?? indent
                current = Builder(line: lineNumber, category: category)
                currentList = nil
                let rest = body == "-" ? "" : String(body.dropFirst()).trimmingCharacters(in: .whitespaces)
                if let pair = keyAndValue(rest), pair.key == "name", let value = scalarValue(pair.value) {
                    current?.name = value
                }
                continue
            }

            guard current != nil, let pair = keyAndValue(body), let knownIndent = servicesIndent,
                  indent <= knownIndent + 2 else {
                try closeOpenListIfNeeded(line: lineNumber)
                currentList = nil
                continue
            }

            try closeOpenListIfNeeded(line: lineNumber)
            switch pair.key {
            case "name":
                current?.name = scalarValue(pair.value)
                currentList = nil
            case "domains", "asn", "ip_ranges":
                let field: ListField = pair.key == "domains" ? .domains : (pair.key == "asn" ? .asn : .ranges)
                if pair.value.isEmpty {
                    currentList = (field, indent)
                } else {
                    guard let values = try inlineValues(pair.value, line: lineNumber) else {
                        throw ServiceCatalogError.malformed(line: lineNumber, reason: "поле \(pair.key) должно быть массивом")
                    }
                    if var builder = current {
                        for value in values {
                            try append(scalar: value, to: &builder, field: field, line: lineNumber, limits: limits,
                                       domains: &totalDomains, ranges: &totalRanges, asns: &totalASNs)
                        }
                        current = builder
                    }
                    currentList = nil
                }
            default:
                // Unknown keys, including their nested lists, are intentionally
                // opaque so that an upstream schema addition cannot corrupt state.
                currentList = nil
            }
        }
        try closeOpenListIfNeeded(line: lines.count)
        if let previous = current { try finish(previous) }
        guard !services.isEmpty else { throw ServiceCatalogError.emptyCatalog }
        return ServiceCatalog(services: services)
    }

    private static func append(
        scalar: String,
        to builder: inout Builder,
        field: ListField,
        line: Int,
        limits: ServiceCatalogLimits,
        domains: inout Int,
        ranges: inout Int,
        asns: inout Int
    ) throws {
        guard scalar.lengthOfBytes(using: .utf8) <= limits.maxFieldBytes else {
            throw ServiceCatalogError.fieldTooLong("catalog item")
        }
        switch field {
        case .domains:
            let value = scalar.trimmingCharacters(in: .whitespacesAndNewlines).lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            guard !value.isEmpty else { return }
            if !builder.domains.contains(value) { builder.domains.append(value); domains += 1 }
            guard domains <= limits.maxDomains else { throw ServiceCatalogError.tooManyDomains(domains) }
        case .asn:
            guard let value = Int(scalar.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw ServiceCatalogError.malformed(line: line, reason: "ASN должен быть числом")
            }
            guard (1...4_294_967_295).contains(value) else { throw ServiceCatalogError.invalidASN(value) }
            if !builder.asn.contains(value) { builder.asn.append(value); asns += 1 }
            guard asns <= limits.maxASNs else { throw ServiceCatalogError.tooManyASNs(asns) }
        case .ranges:
            guard let value = normalizeCatalogIPRange(scalar) else { throw ServiceCatalogError.invalidIPRange(scalar) }
            if !builder.ranges.contains(value) { builder.ranges.append(value); ranges += 1 }
            guard ranges <= limits.maxRanges else { throw ServiceCatalogError.tooManyRanges(ranges) }
        }
    }

    private static func keyAndValue(_ line: String) -> (key: String, value: String)? {
        guard let colon = line.firstIndex(of: ":") else { return nil }
        let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return nil }
        let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        return (key, value)
    }

    private static func scalarValue(_ raw: String) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
            let inner = String(value.dropFirst().dropLast())
            return inner.replacingOccurrences(of: "\\\"", with: "\"")
                .replacingOccurrences(of: "\\n", with: "\n")
                .replacingOccurrences(of: "\\t", with: "\t")
                .replacingOccurrences(of: "\\\\", with: "\\")
        }
        if value.hasPrefix("'") && value.hasSuffix("'") && value.count >= 2 {
            return String(value.dropFirst().dropLast()).replacingOccurrences(of: "''", with: "'")
        }
        if value == "null" || value == "~" { return nil }
        return value
    }

    private static func inlineValues(_ raw: String, line: Int) throws -> [String]? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.hasPrefix("[") else { return nil }
        guard value.hasSuffix("]") else { throw ServiceCatalogError.malformed(line: line, reason: "незакрытый массив") }
        let inner = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
        if inner.isEmpty { return [] }
        return try splitArray(inner, line: line)
    }

    private static func splitArray(_ value: String, line: Int) throws -> [String] {
        var result: [String] = []
        var current = ""
        var quote: Character?
        var escaped = false
        for character in value {
            if escaped { current.append(character); escaped = false; continue }
            if character == "\\" && quote == "\"" { current.append(character); escaped = true; continue }
            if quote != nil {
                current.append(character)
                if character == quote! { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character; current.append(character)
            } else if character == "," {
                guard let scalar = scalarValue(current), !scalar.isEmpty else { throw ServiceCatalogError.malformed(line: line, reason: "пустой элемент массива") }
                result.append(scalar); current = ""
            } else {
                current.append(character)
            }
        }
        guard quote == nil else { throw ServiceCatalogError.malformed(line: line, reason: "незакрытая строка") }
        guard let scalar = scalarValue(current), !scalar.isEmpty else { throw ServiceCatalogError.malformed(line: line, reason: "пустой элемент массива") }
        result.append(scalar)
        return result
    }

    private static func stripComment(from line: String) -> String {
        var quote: Character?
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if escaped { escaped = false; continue }
            if character == "\\" && quote == "\"" { escaped = true; continue }
            if quote != nil {
                if character == quote! { quote = nil }
            } else if character == "\"" || character == "'" {
                quote = character
            } else if character == "#" {
                return String(line[..<index])
            }
        }
        return line
    }

    private static func normalizeCategory(_ value: String) -> String {
        let collapsed = value.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        let normalized = collapsed == collapsed.uppercased() ? collapsed.lowercased() : collapsed
        guard let first = normalized.first else { return "Без категории" }
        return String(first).uppercased() + String(normalized.dropFirst())
    }

    private static func isDivider(_ value: String) -> Bool {
        !value.isEmpty && value.allSatisfy { $0 == "=" || $0 == "-" || $0 == "_" }
    }

    private static func isSupportedCategoryHeading(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean == clean.uppercased(), !clean.contains(":") else { return false }
        return clean.unicodeScalars.contains { CharacterSet.letters.contains($0) }
    }
}

final class ServiceCatalogLoader: @unchecked Sendable {
    let session: URLSession
    let minimumServiceCount: Int
    let relativeMinimum: Double
    private var lastSuccessfulCatalog: ServiceCatalog?

    init(session: URLSession? = nil, minimumServiceCount: Int = 1, relativeMinimum: Double = 0.5) {
        self.session = session ?? URLSession(configuration: .ephemeral)
        self.minimumServiceCount = max(1, minimumServiceCount)
        self.relativeMinimum = min(max(relativeMinimum, 0), 1)
    }

    func load(
        remoteURL: URL,
        fallbackData: Data? = nil,
        previousCatalog: ServiceCatalog? = nil,
        fallbackCatalog: ServiceCatalog? = nil
    ) async throws -> ServiceCatalog {
        let previous = previousCatalog ?? lastSuccessfulCatalog
        do {
            let data = try await fetch(remoteURL)
            var candidate = try ServiceCatalogParser.parse(data)
            try validate(candidate, against: previous)
            candidate.freshness = .remote
            candidate.sourceURL = remoteURL.absoluteString
            candidate.loadedAt = Date()
            lastSuccessfulCatalog = candidate
            return candidate
        } catch {
            // A malformed, colliding, or suspiciously shrunken remote catalog
            // is a failed validation, not an outage. Falling back here would
            // mask an upstream regression and make an atomic refresh appear
            // successful with a mixture of generations.
            guard case ServiceCatalogError.remoteUnavailable = error else {
                throw error
            }
            if let lastSuccessfulCatalog {
                var cached = lastSuccessfulCatalog
                cached.freshness = .cached
                return cached
            }
            if var fallbackCatalog {
                try validate(fallbackCatalog, against: previous)
                fallbackCatalog.freshness = .cached
                fallbackCatalog.sourceURL = fallbackCatalog.sourceURL ?? "saved-state"
                return fallbackCatalog
            }
            if let fallbackData {
                do {
                    var candidate = try ServiceCatalogParser.parse(fallbackData)
                    try validate(candidate, against: previous)
                    candidate.freshness = .cached
                    candidate.sourceURL = "bundled-or-cached"
                    candidate.loadedAt = Date()
                    if previous == nil { lastSuccessfulCatalog = candidate }
                    return candidate
                } catch {
                    // The remote error is deliberately not discarded: if both
                    // candidates fail, callers get one stable, actionable error.
                }
            }
            if let bundled = bundledFallbackData() {
                do {
                    var candidate = try ServiceCatalogParser.parse(bundled)
                    try validate(candidate, against: previous)
                    candidate.freshness = .cached
                    candidate.sourceURL = "bundled-resource"
                    candidate.loadedAt = Date()
                    if previous == nil { lastSuccessfulCatalog = candidate }
                    return candidate
                } catch { }
            }
            if let serviceError = error as? ServiceCatalogError { throw serviceError }
            throw ServiceCatalogError.remoteUnavailable(error.localizedDescription)
        }
    }

    func load(
        remoteURL: String,
        fallbackData: Data? = nil,
        previousCatalog: ServiceCatalog? = nil,
        fallbackCatalog: ServiceCatalog? = nil
    ) async throws -> ServiceCatalog {
        guard let url = URL(string: remoteURL) else { throw ServiceCatalogError.remoteUnavailable("некорректный URL") }
        return try await load(
            remoteURL: url,
            fallbackData: fallbackData,
            previousCatalog: previousCatalog,
            fallbackCatalog: fallbackCatalog
        )
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw ServiceCatalogError.remoteUnavailable(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw ServiceCatalogError.remoteUnavailable("HTTP \(http.statusCode)")
        }
        guard data.count <= ServiceCatalogLimits.maxInputBytes else {
            throw ServiceCatalogError.inputTooLarge(data.count)
        }
        return data
    }

    private func validate(_ candidate: ServiceCatalog, against previous: ServiceCatalog?) throws {
        guard candidate.services.count >= minimumServiceCount else {
            throw ServiceCatalogError.suspiciousShrink(previous: previous?.services.count ?? minimumServiceCount, candidate: candidate.services.count)
        }
        if let previous {
            let threshold = max(minimumServiceCount, Int(ceil(Double(previous.services.count) * relativeMinimum)))
            guard candidate.services.count >= threshold else {
                throw ServiceCatalogError.suspiciousShrink(previous: previous.services.count, candidate: candidate.services.count)
            }
        }
    }

    private func bundledFallbackData() -> Data? {
        let bundles = [Bundle.main, Bundle(for: BundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "pincetgore-config", withExtension: "yaml", subdirectory: "ThirdParty"),
               let data = try? Data(contentsOf: url) { return data }
        }
        return nil
    }
}

private final class BundleMarker: NSObject {}

private func normalizeCatalogIPRange(_ value: String) -> String? {
    let parts = value.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "/", omittingEmptySubsequences: false)
    guard parts.count == 1 || parts.count == 2 else { return nil }
    let octets = parts[0].split(separator: ".", omittingEmptySubsequences: false)
    guard octets.count == 4, octets.allSatisfy({ $0.allSatisfy(\.isNumber) }),
          let numbers = Optional(octets.compactMap { Int($0) }), numbers.count == 4,
          numbers.allSatisfy({ (0...255).contains($0) }) else { return nil }
    let prefix: Int
    if parts.count == 2 {
        guard let value = Int(parts[1]), (0...32).contains(value) else { return nil }
        prefix = value
    } else { prefix = 32 }
    let raw = (UInt32(numbers[0]) << 24) | (UInt32(numbers[1]) << 16) | (UInt32(numbers[2]) << 8) | UInt32(numbers[3])
    let mask: UInt32 = prefix == 0 ? 0 : UInt32.max << (32 - prefix)
    let network = raw & mask
    let address = [24, 16, 8, 0].map { String((network >> $0) & 255) }.joined(separator: ".")
    return prefix == 32 ? address : "\(address)/\(prefix)"
}
