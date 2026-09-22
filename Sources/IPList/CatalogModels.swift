import Foundation

/// Indicates whether a catalog came from the network or from a validated copy.
enum CatalogFreshness: String, Codable, Sendable {
    case remote
    case cached
}

/// How recently DNS/ASN evidence was obtained. This is deliberately separate
/// from `CatalogFreshness`: the YAML catalog and the address evidence refresh
/// on different schedules and can fail independently.
enum EnrichmentFreshness: String, Codable, Sendable {
    case fresh
    case cached
    case stale
    case bundled
}

enum EnrichmentSource: String, Codable, CaseIterable, Sendable {
    case dns
    case ripeStat
}

/// A source address from the targeted list. A hostname, when available from
/// the list, is evidence of its direct service ownership without a DNS lookup.
struct TargetedRoute: Codable, Hashable, Sendable {
    var domain: String?
    var address: String

    init(domain: String? = nil, address: String) {
        let cleanDomain = domain?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        self.domain = cleanDomain?.isEmpty == true ? nil : cleanDomain
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Last known good DNS and RIPEstat evidence for one catalog service.
struct ServiceEnrichment: Codable, Hashable, Sendable {
    var serviceID: String
    var dnsAddresses: [String]
    var asnPrefixes: [String]
    /// Canonical inputs that produced the cached DNS evidence.  Fresh data is
    /// reusable only when these exactly match the current catalog inputs.
    var dnsDomains: [String]
    /// Canonical inputs that produced the cached RIPEstat evidence.
    var asnNumbers: [Int]
    var dnsUpdatedAt: Date?
    var asnUpdatedAt: Date?
    var freshness: EnrichmentFreshness

    init(
        serviceID: String,
        dnsAddresses: [String] = [],
        asnPrefixes: [String] = [],
        dnsDomains: [String] = [],
        asnNumbers: [Int] = [],
        dnsUpdatedAt: Date? = nil,
        asnUpdatedAt: Date? = nil,
        freshness: EnrichmentFreshness = .fresh
    ) {
        self.serviceID = serviceID
        // Keep these models independent of the CIDR engine so catalog-only
        // decoding remains usable in the lightweight catalog check harness.
        self.dnsAddresses = Array(Set(dnsAddresses)).sorted()
        self.asnPrefixes = Array(Set(asnPrefixes)).sorted()
        self.dnsDomains = Array(Set(dnsDomains)).sorted()
        self.asnNumbers = Array(Set(asnNumbers)).sorted()
        self.dnsUpdatedAt = dnsUpdatedAt
        self.asnUpdatedAt = asnUpdatedAt
        self.freshness = freshness
    }

    private enum CodingKeys: String, CodingKey {
        case serviceID, dnsAddresses, asnPrefixes, dnsDomains, asnNumbers, dnsUpdatedAt, asnUpdatedAt, freshness
    }

    /// Snapshots from before cache identity was introduced decode safely but
    /// have empty input identities, which causes a refresh rather than reusing
    /// unknown evidence as if it matched the current catalog.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            serviceID: try container.decode(String.self, forKey: .serviceID),
            dnsAddresses: try container.decodeIfPresent([String].self, forKey: .dnsAddresses) ?? [],
            asnPrefixes: try container.decodeIfPresent([String].self, forKey: .asnPrefixes) ?? [],
            dnsDomains: try container.decodeIfPresent([String].self, forKey: .dnsDomains) ?? [],
            asnNumbers: try container.decodeIfPresent([Int].self, forKey: .asnNumbers) ?? [],
            dnsUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .dnsUpdatedAt),
            asnUpdatedAt: try container.decodeIfPresent(Date.self, forKey: .asnUpdatedAt),
            freshness: try container.decodeIfPresent(EnrichmentFreshness.self, forKey: .freshness) ?? .fresh
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(serviceID, forKey: .serviceID)
        try container.encode(dnsAddresses, forKey: .dnsAddresses)
        try container.encode(asnPrefixes, forKey: .asnPrefixes)
        try container.encode(dnsDomains, forKey: .dnsDomains)
        try container.encode(asnNumbers, forKey: .asnNumbers)
        try container.encodeIfPresent(dnsUpdatedAt, forKey: .dnsUpdatedAt)
        try container.encodeIfPresent(asnUpdatedAt, forKey: .asnUpdatedAt)
        try container.encode(freshness, forKey: .freshness)
    }
}

/// Persistable, provenance-bearing cache used both for bundled evidence and a
/// later last-successful refresh.
struct EnrichmentSnapshot: Codable, Hashable, Sendable {
    var generatedAt: Date
    var provenance: String
    var services: [String: ServiceEnrichment]

    init(generatedAt: Date, provenance: String, services: [String: ServiceEnrichment]) {
        self.generatedAt = generatedAt
        self.provenance = provenance
        self.services = services
    }

    init(generatedAt: Date, provenance: String, entries: [ServiceEnrichment]) {
        self.init(generatedAt: generatedAt, provenance: provenance,
                  services: Dictionary(uniqueKeysWithValues: entries.map { ($0.serviceID, $0) }))
    }

    subscript(serviceID: String) -> ServiceEnrichment? { services[serviceID] }

    static func decodeBundled(_ data: Data) throws -> EnrichmentSnapshot {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        var snapshot = try decoder.decode(EnrichmentSnapshot.self, from: data)
        snapshot.services = snapshot.services.mapValues { evidence in
            var evidence = evidence
            if evidence.freshness == .fresh { evidence.freshness = .bundled }
            return evidence
        }
        return snapshot
    }

    static func bundled() -> EnrichmentSnapshot? {
        let bundles = [Bundle.main, Bundle(for: EnrichmentBundleMarker.self)]
        for bundle in bundles {
            if let url = bundle.url(forResource: "enrichment-snapshot", withExtension: "json", subdirectory: "ThirdParty"),
               let data = try? Data(contentsOf: url),
               let snapshot = try? decodeBundled(data) {
                return snapshot
            }
        }
        return nil
    }
}

private final class EnrichmentBundleMarker: NSObject {}

struct EnrichmentDiagnostic: Codable, Hashable, Sendable {
    var serviceID: String
    var source: EnrichmentSource
    var freshness: EnrichmentFreshness
    var message: String
    var updatedAt: Date?
}

enum CatalogRouteMode: String, Codable, CaseIterable, Hashable, Sendable {
    case targeted
    case lite
    case full
}

/// Output of the lossless source-route partition. A fragment may be listed for
/// several service IDs; unassigned routes carry the complement of their union.
struct MatchedCatalog: Codable, Hashable, Sendable {
    var catalog: ServiceCatalog
    var routesByMode: [CatalogRouteMode: [String: [String]]]
    var unassignedRoutes: [CatalogRouteMode: [String]]
    var diagnostics: [EnrichmentDiagnostic]
    var freshness: EnrichmentFreshness

    func routes(for serviceID: String, mode: CatalogRouteMode) -> [String] {
        routesByMode[mode]?[serviceID] ?? []
    }
}

/// A user-visible explanation for a state migration decision.  Keeping this
/// separate from enrichment diagnostics makes it clear that no network source
/// failed when a legacy selection cannot safely be transferred.
struct StateMigrationDiagnostic: Codable, Hashable, Sendable, Identifiable {
    var id: UUID
    var legacyServiceID: String
    var candidateServiceIDs: [String]
    var message: String

    init(id: UUID = UUID(), legacyServiceID: String, candidateServiceIDs: [String], message: String) {
        self.id = id
        self.legacyServiceID = legacyServiceID
        self.candidateServiceIDs = candidateServiceIDs.sorted()
        self.message = message
    }
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

    private enum CodingKeys: String, CodingKey {
        case id, name, category, domains, asn, asns, ipRanges, ip_ranges
        case targetedAddresses, liteAddresses, fullAddresses
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let decodedName = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        let decodedID = try container.decodeIfPresent(String.self, forKey: .id)
        let decodedASN = try container.decodeIfPresent([Int].self, forKey: .asn)
            ?? (try container.decodeIfPresent([Int].self, forKey: .asns)) ?? []
        let decodedRanges = try container.decodeIfPresent([String].self, forKey: .ipRanges)
            ?? (try container.decodeIfPresent([String].self, forKey: .ip_ranges)) ?? []
        self.init(
            id: decodedID,
            name: decodedName,
            category: try container.decodeIfPresent(String.self, forKey: .category) ?? "Без категории",
            domains: try container.decodeIfPresent([String].self, forKey: .domains) ?? [],
            asn: decodedASN,
            ipRanges: decodedRanges,
            targetedAddresses: try container.decodeIfPresent([String].self, forKey: .targetedAddresses) ?? [],
            liteAddresses: try container.decodeIfPresent([String].self, forKey: .liteAddresses) ?? [],
            fullAddresses: try container.decodeIfPresent([String].self, forKey: .fullAddresses) ?? []
        )
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(category, forKey: .category)
        try container.encode(domains, forKey: .domains)
        try container.encode(asn, forKey: .asn)
        try container.encode(ipRanges, forKey: .ipRanges)
        try container.encode(targetedAddresses, forKey: .targetedAddresses)
        try container.encode(liteAddresses, forKey: .liteAddresses)
        try container.encode(fullAddresses, forKey: .fullAddresses)
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

/// Small, auditable corrections for upstream metadata gaps.  These are kept as
/// data so a source refresh cannot silently erase a verified service mapping.
struct CatalogOverride: Codable, Hashable, Sendable {
    var id: String
    var name: String
    var category: String
    var domains: [String]
    var asn: [Int]
    var ipRanges: [String]
    var detachDomains: [String]
}

func applyCatalogOverrides(_ catalog: ServiceCatalog, data: Data) throws -> ServiceCatalog {
    let overrides = try JSONDecoder().decode([CatalogOverride].self, from: data)
    var result = catalog
    for override in overrides {
        let detach = Set(override.detachDomains.map { $0.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) })
        for index in result.services.indices {
            result.services[index].domains.removeAll { detach.contains($0.lowercased()) }
        }
        result.services.removeAll { $0.domains.isEmpty && $0.ipRanges.isEmpty && $0.asn.isEmpty }
        let service = CatalogService(id: override.id, name: override.name, category: override.category,
                                     domains: override.domains, asn: override.asn, ipRanges: override.ipRanges)
        result.services.removeAll { $0.id == service.id }
        result.services.append(service)
    }
    return result
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

    private enum CodingKeys: String, CodingKey { case services, freshness, sourceURL, loadedAt }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            services: try container.decodeIfPresent([CatalogService].self, forKey: .services) ?? [],
            freshness: try container.decodeIfPresent(CatalogFreshness.self, forKey: .freshness) ?? .cached,
            sourceURL: try container.decodeIfPresent(String.self, forKey: .sourceURL),
            loadedAt: try container.decodeIfPresent(Date.self, forKey: .loadedAt)
        )
    }

    subscript(name name: String) -> CatalogService? {
        services.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}
