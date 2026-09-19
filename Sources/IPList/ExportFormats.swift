import Foundation

func allowedIPsLine(_ addresses: [String]) -> String {
    let routes = collapseIPv4(addresses.compactMap(IPv4Network.init))
        .map(\.description)
    return "AllowedIPs = \(routes.joined(separator: ", "))"
}

func exportData(_ addresses: Set<String>) throws -> Data {
    let entries = collapseIPv4(addresses.compactMap(IPv4Network.init)).map { network in
        AmneziaEntry(
            hostname: network.prefix == 32 ? network.description.replacingOccurrences(of: "/32", with: "") : network.description,
            ip: "",
            ips: []
        )
    }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    return try encoder.encode(entries)
}
