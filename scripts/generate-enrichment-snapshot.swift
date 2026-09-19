import Foundation

@main
struct GenerateEnrichmentSnapshot {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        let catalogURL = root.appending(path: "Resources/ThirdParty/pincetgore-config.yaml")
        let outputURL = root.appending(path: "Resources/ThirdParty/enrichment-snapshot.json")
        let catalogData = try Data(contentsOf: catalogURL)
        let catalog = try ServiceCatalogParser.parse(catalogData)
        let observationTime = Date()
        let result = try await ServiceEnricher(
            dns: SystemDNSResolver(),
            asn: RIPEStatASNPrefixLoader(observationTime: observationTime),
            loadsBundledSnapshot: false,
            limits: EnrichmentLimits()
        ).enrich(catalog: catalog, cached: nil, now: observationTime)

        let dnsCount = result.snapshot.services.values.filter { !$0.dnsAddresses.isEmpty }.count
        let asnCount = result.snapshot.services.values.filter { !$0.asnPrefixes.isEmpty }.count
        let staleCount = result.snapshot.services.values.filter { $0.freshness == .stale }.count
        var snapshot = result.snapshot
        snapshot.provenance = [
            "catalog=https://github.com/pincetgore/amnezia-app-ru-list/blob/b8cb9566109232f07ceccfe98cce7388c84e773d/config.yaml",
            "catalog_sha256=d22b844be82ef80cbbb305adf5b9308245a97cfc6822c0c45a0d8897ea32b53e",
            "dns=macOS system DNS via DNSServiceGetAddrInfo",
            "asn=https://stat.ripe.net/data/announced-prefixes/data.json?resource=AS<asn>",
            "ripe_requested_end=\(observationTime.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .gmt)))",
            "ripe_observation=explicit one-hour query; accepted timelines cover RIPE query_endtime",
            "limits=8 concurrent requests; 12 seconds per request; 60 seconds overall; 4 MiB RIPE response; 100000 RIPE prefixes",
            "coverage=services:\(snapshot.services.count),dns_nonempty:\(dnsCount),asn_nonempty:\(asnCount),stale:\(staleCount),diagnostics:\(result.diagnostics.count)",
            "generator=scripts/generate-enrichment-snapshot.swift"
        ].joined(separator: "; ")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(snapshot).write(to: outputURL, options: .atomic)
        print("Enrichment snapshot: services=\(snapshot.services.count) dns_nonempty=\(dnsCount) asn_nonempty=\(asnCount) stale=\(staleCount) diagnostics=\(result.diagnostics.count)")
    }
}
