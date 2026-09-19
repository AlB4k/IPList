import Foundation

/// Indicates whether a catalog came from the network or from a validated copy.
enum CatalogFreshness: String, Codable, Sendable {
    case remote
    case cached
}

/// Metadata for one service from the licensed catalog.
struct CatalogService: Codable, Identifiable, Hashable, Sendable {
    static let defaultSource = "pincetgore/amnezia-app-ru-list"

    let id: String
    var name: String
    var category: String
    var domains: [String]
    var asn: [Int]
    var ipRanges: [String]

    // These are populated by the enrichment/matching stage. Keeping them on the
    // model lets a catalog move through the refresh pipeline without losing the
    // source metadata parsed here.
    var targetedAddresses: [String]
    var liteAddresses: [String]
    var fullAddresses: [String]

    var asns: [Int] { asn }

    var addresses: [String] {
        var result = ipRanges
        result.append(contentsOf: targetedAddresses)
        result.append(contentsOf: liteAddresses)
        result.append(contentsOf: fullAddresses)
        return Array(Set(result)).sorted()
    }

    init(
        id: String? = nil,
        name: String,
        category: String = "Без категории",
        domains: [String] = [],
        asn: [Int] = [],
        ipRanges: [String] = [],
        targetedAddresses: [String] = [],
        liteAddresses: [String] = [],
        fullAddresses: [String] = []
    ) {
        let cleanName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id ?? Self.stableID(source: Self.defaultSource, name: cleanName)
        self.name = cleanName
        self.category = category.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "Без категории" : category
        self.domains = domains
        self.asn = asn
        self.ipRanges = ipRanges
        self.targetedAddresses = targetedAddresses
        self.liteAddresses = liteAddresses
        self.fullAddresses = fullAddresses
    }

    static func stableID(source: String = Self.defaultSource, name: String) -> String {
        let sourcePart = source
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let namePart = normalizedName(name)
        return "\(sourcePart):\(namePart)"
    }

    static func stableID(for name: String, source: String = Self.defaultSource) -> String {
        stableID(source: source, name: name)
    }

    private static func normalizedName(_ value: String) -> String {
        let lower = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output = ""
        var previousWasSeparator = false
        for scalar in lower.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                output.unicodeScalars.append(scalar)
                previousWasSeparator = false
            } else if !previousWasSeparator {
                output.append("-")
                previousWasSeparator = true
            }
        }
        while output.hasPrefix("-") { output.removeFirst() }
        while output.hasSuffix("-") { output.removeLast() }
        return output.isEmpty ? "unnamed" : output
    }
}

/// A validated catalog and the provenance of the data currently in use.
struct ServiceCatalog: Codable, Hashable, Sendable {
    var services: [CatalogService]
    var freshness: CatalogFreshness
    var sourceURL: String?
    var loadedAt: Date?

    var count: Int { services.count }

    init(
        services: [CatalogService],
        freshness: CatalogFreshness = .remote,
        sourceURL: String? = nil,
        loadedAt: Date? = nil
    ) {
        self.services = services
        self.freshness = freshness
        self.sourceURL = sourceURL
        self.loadedAt = loadedAt
    }

    subscript(name name: String) -> CatalogService? {
        services.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
