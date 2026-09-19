import Foundation

enum IPv4NetworkError: Error, Equatable {
    case invalidFragmentLimit(Int)
    case fragmentLimitExceeded(limit: Int)
}

struct IPv4Network: Hashable, Comparable, CustomStringConvertible {
    static let maximumFragments = 250_000

    let network: UInt32
    let prefix: UInt8

    init?(_ raw: String) {
        let parts = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 1 || parts.count == 2,
              let address = Self.parseAddress(String(parts[0])) else {
            return nil
        }
        let parsedPrefix: UInt8
        if parts.count == 2 {
            guard let value = UInt8(parts[1]), value <= 32 else { return nil }
            parsedPrefix = value
        } else {
            parsedPrefix = 32
        }
        self.init(network: address, prefix: parsedPrefix)
    }

    init?(network: UInt32, prefix: UInt8) {
        guard prefix <= 32 else { return nil }
        self.prefix = prefix
        self.network = network & Self.mask(for: prefix)
    }

    static func < (lhs: IPv4Network, rhs: IPv4Network) -> Bool {
        lhs.network == rhs.network ? lhs.prefix < rhs.prefix : lhs.network < rhs.network
    }

    var description: String { "\(Self.renderAddress(network))/\(prefix)" }
    var lastAddress: UInt32 { network | ~Self.mask(for: prefix) }
    var addressCount: UInt64 { UInt64(1) << UInt64(32 - prefix) }

    func contains(_ other: IPv4Network) -> Bool {
        network <= other.network && lastAddress >= other.lastAddress
    }

    func intersects(_ other: IPv4Network) -> Bool {
        network <= other.lastAddress && other.network <= lastAddress
    }

    func intersection(_ other: IPv4Network) -> IPv4Network? {
        guard intersects(other) else { return nil }
        return contains(other) ? other : self
    }

    func subtracting(_ other: IPv4Network) -> [IPv4Network] {
        // A single CIDR minus another CIDR produces at most 32 fragments.
        // The bounded overload is used whenever callers combine partitions.
        try! subtracting(other, limit: Self.maximumFragments)
    }

    func subtracting(_ other: IPv4Network, limit: Int) throws -> [IPv4Network] {
        guard limit >= 0 else { throw IPv4NetworkError.invalidFragmentLimit(limit) }
        guard intersects(other) else { return [self] }
        guard !other.contains(self) else { return [] }

        var fragments: [IPv4Network] = []
        var remaining = self
        while remaining != other {
            let children = remaining.children()
            if children.0.contains(other) {
                try Self.append(children.1, to: &fragments, limit: limit)
                remaining = children.0
            } else {
                try Self.append(children.0, to: &fragments, limit: limit)
                remaining = children.1
            }
        }
        return fragments.sorted()
    }

    private func children() -> (IPv4Network, IPv4Network) {
        precondition(prefix < 32)
        let childPrefix = prefix + 1
        let half = UInt32(1) << UInt32(32 - childPrefix)
        return (
            IPv4Network(network: network, prefix: childPrefix)!,
            IPv4Network(network: network + half, prefix: childPrefix)!
        )
    }

    private static func append(_ network: IPv4Network, to fragments: inout [IPv4Network], limit: Int) throws {
        guard fragments.count < limit else {
            throw IPv4NetworkError.fragmentLimitExceeded(limit: limit)
        }
        fragments.append(network)
    }

    private static func mask(for prefix: UInt8) -> UInt32 {
        prefix == 0 ? 0 : UInt32.max << UInt32(32 - prefix)
    }

    private static func parseAddress(_ raw: String) -> UInt32? {
        let octets = raw.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return nil }
        var result: UInt32 = 0
        for octet in octets {
            guard !octet.isEmpty,
                  octet.allSatisfy({ $0.isNumber }),
                  let value = UInt8(octet) else { return nil }
            result = (result << 8) | UInt32(value)
        }
        return result
    }

    private static func renderAddress(_ value: UInt32) -> String {
        [24, 16, 8, 0].map { String((value >> UInt32($0)) & 255) }.joined(separator: ".")
    }
}

func collapseIPv4(_ addresses: [String]) -> [String] {
    collapseIPv4(addresses.compactMap(IPv4Network.init)).map(\.description)
}

func collapseIPv4(_ networks: [IPv4Network]) -> [IPv4Network] {
    let sorted = networks.sorted()
    var compacted: [IPv4Network] = []
    for network in sorted {
        if compacted.last?.contains(network) == true { continue }
        while let last = compacted.last, network.contains(last) {
            compacted.removeLast()
        }
        compacted.append(network)
        mergeFinalSiblings(in: &compacted)
    }
    return compacted
}

private func mergeFinalSiblings(in networks: inout [IPv4Network]) {
    while networks.count >= 2 {
        let right = networks[networks.count - 1]
        let left = networks[networks.count - 2]
        guard left.prefix == right.prefix, left.prefix > 0 else { return }
        let childSize = UInt32(1) << UInt32(32 - left.prefix)
        guard left.network < right.network,
              left.network ^ right.network == childSize,
              let parent = IPv4Network(network: left.network, prefix: left.prefix - 1) else {
            return
        }
        networks.removeLast(2)
        networks.append(parent)
    }
}
