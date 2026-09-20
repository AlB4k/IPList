import Foundation
import Darwin

enum AllowedIPsOperation {
    case add
    case replace
    case bypass
}

enum AmneziaWGConfigError: Error, LocalizedError {
    case invalidStructure
    case missingInterface
    case missingPrivateKey
    case missingPeerKey
    case duplicateSingletonKey
    case invalidAllowedIP
    case invalidPeer
    case peerOverlap
    case routeLimit
    case emptyAllowedIPs

    var errorDescription: String? {
        switch self {
        case .invalidStructure: return "Некорректная структура конфигурации AmneziaWG."
        case .missingInterface: return "В конфигурации отсутствует секция Interface."
        case .missingPrivateKey: return "В секции Interface отсутствует PrivateKey."
        case .missingPeerKey: return "В секции Peer отсутствует PublicKey."
        case .duplicateSingletonKey: return "В секции повторяется одиночный параметр."
        case .invalidAllowedIP: return "В AllowedIPs указан некорректный IPv4 или IPv6 CIDR."
        case .invalidPeer: return "Выбранный peer отсутствует в конфигурации."
        case .peerOverlap: return "Новый маршрут пересекается с AllowedIPs другого peer."
        case .routeLimit: return "Слишком много фрагментов маршрутов после вычитания."
        case .emptyAllowedIPs: return "Вычитание удаляет все AllowedIPs выбранного peer; пустая конфигурация не будет сохранена."
        }
    }
}

struct AmneziaWGPeer: Equatable {
    let index: Int
    let displayName: String
}

struct AmneziaWGDocument {
    let peers: [AmneziaWGPeer]

    private let lines: [Line]
    private let sections: [Section]
    private let peerSectionIndexes: [Int]
    private let defaultLineEnding: String

    static func parse(_ source: String) throws -> AmneziaWGDocument {
        let lines = splitLines(source)
        let sections = try parseSections(lines)
        let interfaceSections = sections.indices.filter { sections[$0].kind == .interface }
        guard !interfaceSections.isEmpty else { throw AmneziaWGConfigError.missingInterface }
        guard interfaceSections.count == 1 else { throw AmneziaWGConfigError.invalidStructure }
        guard let interfaceIndex = interfaceSections.first else { throw AmneziaWGConfigError.missingInterface }
        let peerSectionIndexes = sections.indices.filter { sections[$0].kind == .peer }
        guard !peerSectionIndexes.isEmpty,
              interfaceIndex < peerSectionIndexes[0] else {
            throw AmneziaWGConfigError.invalidStructure
        }

        for section in sections {
            try validate(section: section, in: lines)
        }

        let peers = peerSectionIndexes.enumerated().map { offset, sectionIndex in
            let section = sections[sectionIndex]
            let endpoint = keyLines(in: section, named: "Endpoint", lines: lines).first?.line.value
            return AmneziaWGPeer(index: offset, displayName: endpoint?.isEmpty == false ? endpoint! : "Peer \(offset + 1)")
        }
        let defaultLineEnding = lines.first(where: { !$0.ending.isEmpty })?.ending ?? "\n"
        return AmneziaWGDocument(peers: peers, lines: lines, sections: sections,
                                 peerSectionIndexes: peerSectionIndexes, defaultLineEnding: defaultLineEnding)
    }

    func render(peer: Int, operation: AllowedIPsOperation, routes: [String], preserveIPv6: Bool) throws -> String {
        guard peers.indices.contains(peer) else { throw AmneziaWGConfigError.invalidPeer }
        let section = sections[peerSectionIndexes[peer]]
        let allowedLines = Self.keyLines(in: section, named: "AllowedIPs", lines: lines)
        let existing = try Self.parsedRoutes(from: allowedLines)
        let requested = try routes.map(Self.parseRoute)

        let existingIPv4 = collapseIPv4(existing.compactMap { if case let .ipv4(network) = $0 { return network }; return nil })
        let requestedIPv4 = collapseIPv4(requested.compactMap { if case let .ipv4(network) = $0 { return network }; return nil })
        let existingIPv6 = Self.unique(existing.compactMap { if case let .ipv6(network) = $0 { return network.description }; return nil })
        let requestedIPv6 = Self.unique(requested.compactMap { if case let .ipv6(network) = $0 { return network.description }; return nil })

        let finalIPv4: [IPv4Network]
        let finalIPv6: [String]
        switch operation {
        case .add:
            finalIPv4 = collapseIPv4(existingIPv4 + requestedIPv4)
            finalIPv6 = Self.unique(existingIPv6 + requestedIPv6)
        case .replace:
            finalIPv4 = requestedIPv4
            finalIPv6 = preserveIPv6 ? Self.unique(existingIPv6 + requestedIPv6) : requestedIPv6
        case .bypass:
            finalIPv4 = try Self.subtract(requestedIPv4, from: existingIPv4)
            finalIPv6 = existingIPv6
        }

        try validateNewOverlap(finalIPv4: finalIPv4, originalIPv4: existingIPv4,
                               finalIPv6: finalIPv6, originalIPv6: existingIPv6, selectedPeer: peer)
        let renderedRoutes = finalIPv4.map(\.description) + finalIPv6
        guard !renderedRoutes.isEmpty else { throw AmneziaWGConfigError.emptyAllowedIPs }
        return replaceAllowedIPs(in: section, existing: allowedLines, routes: renderedRoutes)
    }
}

private extension AmneziaWGDocument {
    enum SectionKind { case interface, peer, other }

    struct Line {
        let text: String
        let ending: String
        let key: String?
        let value: String?
        let prefix: String?
        let suffix: String?
    }

    struct Section {
        let kind: SectionKind
        let start: Int
        let end: Int
    }

    enum Route {
        case ipv4(IPv4Network)
        case ipv6(IPv6Route)
    }

    struct IPv6Route {
        let bytes: [UInt8]
        let prefix: Int
        let description: String

        init?(_ raw: String) {
            let pieces = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                .split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 1 || pieces.count == 2 else { return nil }
            let prefix: Int
            if pieces.count == 2 {
                guard let value = Int(pieces[1]), (0...128).contains(value) else { return nil }
                prefix = value
            } else {
                prefix = 128
            }
            var address = in6_addr()
            guard inet_pton(AF_INET6, String(pieces[0]), &address) == 1 else { return nil }
            let octets = withUnsafeBytes(of: &address) { Array($0.prefix(16)) }
            var printable = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
            guard inet_ntop(AF_INET6, &address, &printable, socklen_t(printable.count)) != nil else { return nil }
            self.bytes = octets
            self.prefix = prefix
            self.description = "\(String(cString: printable))/\(prefix)"
        }

        func intersects(_ other: IPv6Route) -> Bool {
            let bits = min(prefix, other.prefix)
            let fullBytes = bits / 8
            guard bytes.prefix(fullBytes) == other.bytes.prefix(fullBytes) else { return false }
            let remaining = bits % 8
            guard remaining > 0 else { return true }
            let mask = UInt8.max << UInt8(8 - remaining)
            return (bytes[fullBytes] & mask) == (other.bytes[fullBytes] & mask)
        }

        func contains(_ other: IPv6Route) -> Bool {
            prefix <= other.prefix && intersects(other)
        }
    }

    static func splitLines(_ source: String) -> [Line] {
        var result: [Line] = []
        var cursor = source.startIndex
        while cursor < source.endIndex {
            guard let lineBreak = source[cursor...].firstIndex(where: \.isNewline) else {
                result.append(makeLine(String(source[cursor...])))
                break
            }
            let text = String(source[cursor..<lineBreak])
            let afterBreak = source.index(after: lineBreak)
            let ending: String
            let next: String.Index
            if source[lineBreak] == "\r", afterBreak < source.endIndex, source[afterBreak] == "\n" {
                ending = "\r\n"; next = source.index(after: afterBreak)
            } else {
                ending = String(source[lineBreak]); next = afterBreak
            }
            result.append(makeLine(text, ending: ending))
            cursor = next
        }
        return result
    }

    static func makeLine(_ text: String, ending: String = "") -> Line {
        let effective = text.hasPrefix("\u{FEFF}") ? String(text.dropFirst()) : text
        let trimmed = effective.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("#") || trimmed.hasPrefix(";") {
            return Line(text: text, ending: ending, key: nil, value: nil, prefix: nil, suffix: nil)
        }
        guard let equals = effective.firstIndex(of: "=") else {
            return Line(text: text, ending: ending, key: nil, value: nil, prefix: nil, suffix: nil)
        }
        let key = effective[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else {
            return Line(text: text, ending: ending, key: nil, value: nil, prefix: nil, suffix: nil)
        }
        let afterEquals = effective.index(after: equals)
        var valueStart = afterEquals
        while valueStart < effective.endIndex, effective[valueStart].isWhitespace { valueStart = effective.index(after: valueStart) }
        let prefix = String(effective[..<valueStart])
        let remainder = effective[valueStart...]
        let comment = remainder.indices.first { index in
            guard remainder[index] == "#" || remainder[index] == ";" else { return false }
            return index == remainder.startIndex || remainder[remainder.index(before: index)].isWhitespace
        }
        let valueRegion = comment.map { remainder[..<$0] } ?? remainder
        let valueEnd = valueRegion.lastIndex(where: { !$0.isWhitespace })
            .map { valueRegion.index(after: $0) } ?? valueRegion.startIndex
        let value = String(valueRegion[..<valueEnd])
        let suffix = String(remainder[valueEnd...])
        return Line(text: text, ending: ending, key: key, value: value,
                    prefix: prefix, suffix: suffix)
    }

    static func parseSections(_ lines: [Line]) throws -> [Section] {
        var starts: [(kind: SectionKind, line: Int)] = []
        for (index, line) in lines.enumerated() {
            let effective = line.text.hasPrefix("\u{FEFF}") ? String(line.text.dropFirst()) : line.text
            let trimmed = effective.trimmingCharacters(in: .whitespacesAndNewlines)
            let kind: SectionKind?
            switch trimmed {
            case "[Interface]": kind = .interface
            case "[Peer]": kind = .peer
            default: kind = nil
            }
            if let kind {
                starts.append((kind, index))
            } else if line.key != nil, starts.isEmpty {
                throw AmneziaWGConfigError.invalidStructure
            }
        }
        return starts.enumerated().map { offset, item in
            Section(kind: item.kind, start: item.line, end: offset + 1 < starts.count ? starts[offset + 1].line : lines.count)
        }
    }

    static func validate(section: Section, in lines: [Line]) throws {
        let singletonKeys: Set<String> = ["privatekey", "publickey", "presharedkey", "endpoint", "persistentkeepalive", "address", "listenport", "mtu", "dns", "jc", "jmin", "jmax", "s1", "s2", "h1", "h2", "h3", "h4", "headerprotectionkey"]
        var seen: Set<String> = []
        for line in lines[(section.start + 1)..<section.end] {
            guard let key = line.key else { continue }
            let normalized = key.lowercased()
            if singletonKeys.contains(normalized), !seen.insert(normalized).inserted {
                throw AmneziaWGConfigError.duplicateSingletonKey
            }
        }
        let privateKeys = keyLines(in: section, named: "PrivateKey", lines: lines)
        if section.kind == .interface, privateKeys.count != 1 || privateKeys[0].line.value?.isEmpty != false {
            throw AmneziaWGConfigError.missingPrivateKey
        }
        let publicKeys = keyLines(in: section, named: "PublicKey", lines: lines)
        if section.kind == .peer, publicKeys.count != 1 || publicKeys[0].line.value?.isEmpty != false {
            throw AmneziaWGConfigError.missingPeerKey
        }
        _ = try parsedRoutes(from: keyLines(in: section, named: "AllowedIPs", lines: lines))
    }

    static func keyLines(in section: Section, named key: String, lines: [Line]) -> [(index: Int, line: Line)] {
        lines.indices[(section.start + 1)..<section.end].compactMap { index in
            guard lines[index].key?.caseInsensitiveCompare(key) == .orderedSame else { return nil }
            return (index, lines[index])
        }
    }

    static func parsedRoutes(from allowedLines: [(index: Int, line: Line)]) throws -> [Route] {
        try allowedLines.flatMap { item -> [Route] in
            guard let value = item.line.value else { return [] }
            return try value.split(separator: ",", omittingEmptySubsequences: false).map { value in
                try parseRoute(String(value))
            }
        }
    }

    static func parseRoute(_ raw: String) throws -> Route {
        if let route = IPv4Network(raw) { return .ipv4(route) }
        if let route = IPv6Route(raw) { return .ipv6(route) }
        throw AmneziaWGConfigError.invalidAllowedIP
    }

    static func unique(_ routes: [String]) -> [String] {
        var seen: Set<String> = []
        return routes.filter { seen.insert($0).inserted }
    }

    static func subtract(_ removals: [IPv4Network], from existing: [IPv4Network]) throws -> [IPv4Network] {
        var result = existing
        do {
            for removal in removals {
                var next: [IPv4Network] = []
                for route in result {
                    next += try route.subtracting(removal, limit: IPv4Network.maximumFragments - next.count)
                }
                result = collapseIPv4(next)
            }
            return result
        } catch {
            throw AmneziaWGConfigError.routeLimit
        }
    }

    func validateNewOverlap(finalIPv4: [IPv4Network], originalIPv4: [IPv4Network], finalIPv6: [String], originalIPv6: [String], selectedPeer: Int) throws {
        var newIPv4 = finalIPv4
        for original in originalIPv4 { newIPv4 = try Self.subtract([original], from: newIPv4) }
        let originalIPv6Networks = originalIPv6.compactMap(IPv6Route.init)
        let newIPv6 = finalIPv6.compactMap(IPv6Route.init).filter { candidate in
            !originalIPv6Networks.contains { $0.contains(candidate) }
        }
        for (otherPeer, sectionIndex) in peerSectionIndexes.enumerated() where otherPeer != selectedPeer {
            let otherRoutes = try Self.parsedRoutes(from: Self.keyLines(in: sections[sectionIndex], named: "AllowedIPs", lines: lines))
            for other in otherRoutes {
                switch other {
                case let .ipv4(route):
                    if newIPv4.contains(where: { $0.intersects(route) }) { throw AmneziaWGConfigError.peerOverlap }
                case let .ipv6(route):
                    if newIPv6.contains(where: { $0.intersects(route) }) { throw AmneziaWGConfigError.peerOverlap }
                }
            }
        }
    }

    func replaceAllowedIPs(in section: Section, existing: [(index: Int, line: Line)], routes: [String]) -> String {
        let rendered = routes.joined(separator: ", ")
        var output: [String] = []
        let removed = Set(existing.map(\.index))
        if let first = existing.first {
            for index in lines.indices {
                if index == first.index {
                    output.append((first.line.prefix ?? "AllowedIPs = ") + rendered + (first.line.suffix ?? "") + first.line.ending)
                } else if !removed.contains(index) {
                    output.append(lines[index].text + lines[index].ending)
                }
            }
            return output.joined()
        }

        guard let publicKey = Self.keyLines(in: section, named: "PublicKey", lines: lines).first else {
            return lines.map { $0.text + $0.ending }.joined()
        }
        for index in lines.indices {
            let line = lines[index]
            if index == publicKey.index, line.ending.isEmpty {
                output.append(line.text + defaultLineEnding)
                output.append("AllowedIPs = \(rendered)")
            } else {
                output.append(line.text + line.ending)
                if index == publicKey.index {
                    output.append("AllowedIPs = \(rendered)\(line.ending)")
                }
            }
        }
        return output.joined()
    }
}
