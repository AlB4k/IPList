import Foundation
import Darwin
import Dispatch

protocol DomainResolving: Sendable {
    func ipv4Addresses(for domain: String, timeout: TimeInterval) async throws -> [String]
}

protocol ASNPrefixLoading: Sendable {
    func announcedPrefixes(for asn: Int, timeout: TimeInterval) async throws -> [String]
}

private func canonicalDomains(_ values: [String]) -> [String] {
    Array(Set(values.compactMap { value -> String? in
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return normalized.isEmpty ? nil : normalized
    })).sorted()
}

private func canonicalASNs(_ values: [Int]) -> [Int] {
    Array(Set(values.filter { $0 > 0 })).sorted()
}

private func retainsOnlyStillApplicableInputs<Value: Hashable>(_ previous: [Value], current: [Value]) -> Bool {
    // Legacy snapshots have no input identity, so their values cannot be
    // proven applicable. A nonempty prior identity that is a subset of the
    // current inputs represents an addition-only update and remains safe.
    !previous.isEmpty && Set(previous).isSubset(of: Set(current))
}

/// Official RIPEstat announced-prefixes client. It receives ASN identifiers
/// only; manually entered addresses are never sent to this endpoint.
struct RIPEStatASNPrefixLoader: ASNPrefixLoading, Sendable {
    static let maximumResponseBytes = 4 * 1_024 * 1_024
    static let maximumPrefixes = 100_000
    static let observationPolicy = "explicit one-hour RIPEstat interval; only timelines covering query_endtime"

    private let session: URLSession
    private let endpoint: URL
    private let fixedObservationTime: Date?
    private let observationClock: @Sendable () -> Date
    private let observationWindow: TimeInterval
    private let maximumResponseBytes: Int
    private let maximumPrefixCount: Int

    init(
        session: URLSession = .shared,
        endpoint: URL = URL(string: "https://stat.ripe.net/data/announced-prefixes/data.json")!,
        observationTime: Date? = nil,
        observationClock: @escaping @Sendable () -> Date = { Date() },
        observationWindow: TimeInterval = 60 * 60,
        maximumResponseBytes: Int = RIPEStatASNPrefixLoader.maximumResponseBytes,
        maximumPrefixCount: Int = RIPEStatASNPrefixLoader.maximumPrefixes
    ) {
        self.session = session
        self.endpoint = endpoint
        self.fixedObservationTime = observationTime
        self.observationClock = observationClock
        self.observationWindow = max(1, observationWindow)
        self.maximumResponseBytes = max(1, maximumResponseBytes)
        self.maximumPrefixCount = max(1, maximumPrefixCount)
    }

    func announcedPrefixes(for asn: Int, timeout: TimeInterval) async throws -> [String] {
        guard asn > 0 else { throw EnrichmentError.invalidRIPEStatResponse }
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)!
        let observationTime = fixedObservationTime ?? observationClock()
        let observationEnd = Self.renderRIPETime(observationTime)
        let observationStart = Self.renderRIPETime(observationTime.addingTimeInterval(-observationWindow))
        components.queryItems = [
            URLQueryItem(name: "resource", value: "AS\(asn)"),
            URLQueryItem(name: "starttime", value: observationStart),
            URLQueryItem(name: "endtime", value: observationEnd)
        ]
        guard let url = components.url else { throw EnrichmentError.invalidRIPEStatResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        request.cachePolicy = .reloadIgnoringLocalCacheData
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            throw EnrichmentError.invalidRIPEStatResponse
        }
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode) else {
            throw EnrichmentError.invalidRIPEStatResponse
        }
        guard http.expectedContentLength < 0 || http.expectedContentLength <= Int64(maximumResponseBytes) else {
            throw EnrichmentError.ripeResponseTooLarge
        }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < maximumResponseBytes else {
                    throw EnrichmentError.ripeResponseTooLarge
                }
                data.append(byte)
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as EnrichmentError {
            throw error
        } catch {
            throw EnrichmentError.invalidRIPEStatResponse
        }
        let decoded: RIPEStatResponse
        do {
            decoded = try JSONDecoder().decode(RIPEStatResponse.self, from: data)
        } catch {
            throw EnrichmentError.invalidRIPEStatResponse
        }
        guard decoded.data.prefixes.count <= maximumPrefixCount else {
            throw EnrichmentError.tooManyRIPEPrefixes(decoded.data.prefixes.count)
        }
        guard let queryEnd = Self.parseRIPETime(decoded.data.queryEndtime) else {
            throw EnrichmentError.invalidRIPEStatResponse
        }
        return collapseIPv4(decoded.data.prefixes.compactMap { prefix in
            guard prefix.timelines.contains(where: { timeline in
                guard let start = Self.parseRIPETime(timeline.starttime) else { return false }
                guard start <= queryEnd else { return false }
                guard let endtime = timeline.endtime else { return true }
                guard let end = Self.parseRIPETime(endtime) else { return false }
                return end >= queryEnd
            }) else { return nil }
            return IPv4Network(prefix.prefix)?.description
        })
    }

    private struct RIPEStatResponse: Decodable {
        var data: Payload

        struct Payload: Decodable {
            var queryEndtime: String
            var prefixes: [Prefix]

            private enum CodingKeys: String, CodingKey {
                case queryEndtime = "query_endtime"
                case prefixes
            }
        }

        struct Prefix: Decodable {
            var prefix: String
            var timelines: [Timeline]
        }

        struct Timeline: Decodable {
            var starttime: String
            var endtime: String?
        }
    }

    private static func renderRIPETime(_ date: Date) -> String {
        date.formatted(Date.ISO8601FormatStyle(includingFractionalSeconds: false, timeZone: .gmt))
    }

    private static func parseRIPETime(_ value: String) -> Date? {
        if let date = try? Date(value, strategy: .iso8601) { return date }
        return try? Date(value + "Z", strategy: .iso8601)
    }
}

/// Resolves through macOS's configured DNS service. This intentionally uses
/// DNS-SD instead of a public DoH endpoint so the application never bulk-sends
/// catalog domains to an unrelated resolver. Deallocating the DNSServiceRef on
/// task cancellation terminates the underlying system lookup.
struct SystemDNSResolver: DomainResolving, Sendable {
    func ipv4Addresses(for domain: String, timeout: TimeInterval) async throws -> [String] {
        let query = DNSAddressQuery(domain: domain)
        return try await withTaskCancellationHandler(operation: {
            try await query.resolve(timeout: timeout)
        }, onCancel: {
            query.cancel()
        })
    }
}

private typealias DNSServiceGetAddrInfoReply = @convention(c) (
    OpaquePointer?, UInt32, UInt32, Int32, UnsafePointer<CChar>?, UnsafePointer<sockaddr>?, UInt32, UnsafeMutableRawPointer?
) -> Void

@_silgen_name("DNSServiceGetAddrInfo")
private func DNSServiceGetAddrInfo(
    _ reference: UnsafeMutablePointer<OpaquePointer?>,
    _ flags: UInt32,
    _ interfaceIndex: UInt32,
    _ protocolMask: UInt32,
    _ hostname: UnsafePointer<CChar>,
    _ callback: DNSServiceGetAddrInfoReply?,
    _ context: UnsafeMutableRawPointer?
) -> Int32

@_silgen_name("DNSServiceRefSockFD")
private func DNSServiceRefSockFD(_ reference: OpaquePointer?) -> Int32

@_silgen_name("DNSServiceProcessResult")
private func DNSServiceProcessResult(_ reference: OpaquePointer?) -> Int32

@_silgen_name("DNSServiceRefDeallocate")
private func DNSServiceRefDeallocate(_ reference: OpaquePointer?)

private let dnsServiceGetAddrInfoCallback: DNSServiceGetAddrInfoReply = { _, flags, _, errorCode, _, address, _, context in
    guard let context else { return }
    Unmanaged<DNSAddressQuery>.fromOpaque(context).takeUnretainedValue()
        .receive(flags: flags, errorCode: errorCode, address: systemDNSIPv4Address(address))
}

func systemDNSIPv4Address(_ address: UnsafePointer<sockaddr>?) -> String? {
    guard let address, address.pointee.sa_family == sa_family_t(AF_INET) else { return nil }
    return address.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { pointer in
        let value = UInt32(bigEndian: pointer.pointee.sin_addr.s_addr)
        return IPv4Network(network: value, prefix: 32)?.description
    }
}

private final class DNSAddressQuery: @unchecked Sendable {
    private let domain: String
    private let queue = DispatchQueue(label: "IPList.SystemDNSResolver")
    private var reference: OpaquePointer?
    private var source: DispatchSourceRead?
    private var continuation: CheckedContinuation<[String], Error>?
    private var addresses: Set<String> = []
    private var completed = false
    private var cancelled = false

    init(domain: String) {
        self.domain = domain
    }

    func resolve(timeout: TimeInterval) async throws -> [String] {
        try await withThrowingTaskGroup(of: [String].self) { group in
            group.addTask { try await self.start() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(max(0.01, timeout) * 1_000_000_000))
                try Task.checkCancellation()
                throw EnrichmentError.deadlineExceeded
            }
            defer {
                group.cancelAll()
                cancel()
            }
            guard let first = try await group.next() else { throw EnrichmentError.deadlineExceeded }
            return first
        }
    }

    func cancel() {
        queue.async { [weak self] in
            guard let self else { return }
            self.cancelled = true
            self.finish(.failure(CancellationError()))
        }
    }

    private func start() async throws -> [String] {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [weak self] in
                guard let self else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard !self.cancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                self.continuation = continuation
                var reference: OpaquePointer?
                let status = self.domain.withCString { hostname in
                    DNSServiceGetAddrInfo(
                        &reference,
                        0,
                        0,
                        1, // kDNSServiceProtocol_IPv4
                        hostname,
                        dnsServiceGetAddrInfoCallback,
                        Unmanaged.passUnretained(self).toOpaque()
                    )
                }
                guard status == 0, let reference else {
                    self.finish(.failure(EnrichmentError.invalidRIPEStatResponse))
                    return
                }
                self.reference = reference
                let fileDescriptor = DNSServiceRefSockFD(reference)
                guard fileDescriptor >= 0 else {
                    self.finish(.failure(EnrichmentError.invalidRIPEStatResponse))
                    return
                }
                let source = DispatchSource.makeReadSource(fileDescriptor: fileDescriptor, queue: self.queue)
                source.setEventHandler { [weak self] in
                    self?.processResult()
                }
                self.source = source
                source.resume()
            }
        }
    }

    private func processResult() {
        guard !completed else { return }
        guard DNSServiceProcessResult(reference) == 0 else {
            finish(.failure(EnrichmentError.invalidRIPEStatResponse))
            return
        }
    }

    func receive(flags: UInt32, errorCode: Int32, address: String?) {
        queue.async { [weak self] in
            guard let self, !self.completed else { return }
            guard errorCode == 0 else {
                self.finish(.failure(EnrichmentError.invalidRIPEStatResponse))
                return
            }
            if let address { self.addresses.insert(address) }
            // kDNSServiceFlagsMoreComing is bit 0. When it is clear, DNS-SD
            // has delivered the complete current answer set for this request.
            if flags & 1 == 0 {
                self.finish(.success(self.addresses.sorted()))
            }
        }
    }

    private func finish(_ result: Result<[String], Error>) {
        guard !completed else { return }
        completed = true
        source?.cancel()
        source = nil
        if let reference {
            DNSServiceRefDeallocate(reference)
            self.reference = nil
        }
        let continuation = self.continuation
        self.continuation = nil
        continuation?.resume(with: result)
    }
}

enum EnrichmentError: Error, LocalizedError, Equatable {
    case invalidSourceRoute(String)
    case rejectedDefaultRoute
    case forbiddenSourceRoute(String)
    case fragmentLimitExceeded(Int)
    case deadlineExceeded
    case invalidRIPEStatResponse
    case ripeResponseTooLarge
    case tooManyRIPEPrefixes(Int)

    var errorDescription: String? {
        switch self {
        case .invalidSourceRoute(let value): return "Некорректный IPv4-маршрут источника: \(value)"
        case .rejectedDefaultRoute: return "Источник не должен содержать 0.0.0.0/0"
        case .forbiddenSourceRoute(let value): return "Источник содержит запрещённую сеть: \(value)"
        case .fragmentLimitExceeded(let limit): return "Превышен предел фрагментов маршрутов: \(limit)"
        case .deadlineExceeded: return "Превышено общее время обогащения"
        case .invalidRIPEStatResponse: return "RIPEstat вернул ответ без объявленных IPv4-префиксов"
        case .ripeResponseTooLarge: return "Ответ RIPEstat превышает 4 МиБ"
        case .tooManyRIPEPrefixes(let count): return "RIPEstat вернул слишком много префиксов: \(count)"
        }
    }
}

struct CatalogMatchOptions: Sendable {
    var maximumFragments: Int
    var rejectDefaultRoute: Bool
    var forbiddenSourceRoutes: [String]

    init(
        maximumFragments: Int = IPv4Network.maximumFragments,
        rejectDefaultRoute: Bool = true,
        forbiddenSourceRoutes: [String] = []
    ) {
        self.maximumFragments = maximumFragments
        self.rejectDefaultRoute = rejectDefaultRoute
        self.forbiddenSourceRoutes = forbiddenSourceRoutes
    }
}

struct EnrichmentLimits: Sendable {
    static let maximumConcurrentRequests = 8
    static let perRequestTimeout: TimeInterval = 12
    static let overallTimeout: TimeInterval = 60
    static let cacheTTL: TimeInterval = 24 * 60 * 60

    var maximumConcurrentRequests: Int
    var perRequestTimeout: TimeInterval
    var overallTimeout: TimeInterval
    var cacheTTL: TimeInterval

    init(
        maximumConcurrentRequests: Int = EnrichmentLimits.maximumConcurrentRequests,
        perRequestTimeout: TimeInterval = EnrichmentLimits.perRequestTimeout,
        overallTimeout: TimeInterval = EnrichmentLimits.overallTimeout,
        cacheTTL: TimeInterval = EnrichmentLimits.cacheTTL
    ) {
        self.maximumConcurrentRequests = max(1, maximumConcurrentRequests)
        self.perRequestTimeout = max(0.01, perRequestTimeout)
        self.overallTimeout = max(0.01, overallTimeout)
        self.cacheTTL = max(0, cacheTTL)
    }
}

struct EnrichmentRefreshResult: Sendable {
    var snapshot: EnrichmentSnapshot
    var diagnostics: [EnrichmentDiagnostic]
}

struct ServiceEnricher: Sendable {
    private let dns: any DomainResolving
    private let asn: any ASNPrefixLoading
    private let bundled: EnrichmentSnapshot?
    private let limits: EnrichmentLimits

    init(
        dns: any DomainResolving,
        asn: any ASNPrefixLoading,
        bundled: EnrichmentSnapshot? = nil,
        loadsBundledSnapshot: Bool = true,
        limits: EnrichmentLimits = EnrichmentLimits()
    ) {
        self.dns = dns
        self.asn = asn
        self.bundled = bundled ?? (loadsBundledSnapshot ? EnrichmentSnapshot.bundled() : nil)
        self.limits = limits
    }

    func enrich(
        catalog: ServiceCatalog,
        cached: EnrichmentSnapshot?,
        now: Date = Date()
    ) async throws -> EnrichmentRefreshResult {
        try Task.checkCancellation()
        let base = cached ?? bundled
        let deadline = Date().addingTimeInterval(limits.overallTimeout)
        var dnsResults: [String: SourceRefresh] = [:]
        var asnResults: [String: SourceRefresh] = [:]
        var dnsWork: [DNSWork] = []
        var asnWork: [ASNWork] = []

        for service in catalog.services {
            let previous = base?[service.id]
            let dnsInputs = canonicalDomains(service.domains)
            let asnInputs = canonicalASNs(service.asn)
            if dnsInputs.isEmpty {
                dnsResults[service.id] = retired(
                    serviceID: service.id,
                    source: .dns,
                    previous: previous?.dnsAddresses,
                    previousInputs: previous?.dnsDomains,
                    now: now
                )
            } else if let previous,
                      previous.dnsDomains == dnsInputs,
                      isFresh(previous.dnsUpdatedAt, now: now) {
                dnsResults[service.id] = cachedResult(service.id, .dns, previous.dnsAddresses, updatedAt: previous.dnsUpdatedAt,
                                                       freshness: previous.freshness)
            } else {
                dnsWork.append(contentsOf: dnsInputs.map { DNSWork(serviceID: service.id, domain: $0) })
            }

            if asnInputs.isEmpty {
                asnResults[service.id] = retired(
                    serviceID: service.id,
                    source: .ripeStat,
                    previous: previous?.asnPrefixes,
                    previousInputs: previous?.asnNumbers.map(String.init),
                    now: now
                )
            } else if let previous,
                      previous.asnNumbers == asnInputs,
                      isFresh(previous.asnUpdatedAt, now: now) {
                asnResults[service.id] = cachedResult(service.id, .ripeStat, previous.asnPrefixes, updatedAt: previous.asnUpdatedAt,
                                                       freshness: previous.freshness)
            } else {
                asnWork.append(contentsOf: asnInputs.map { ASNWork(serviceID: service.id, number: $0) })
            }
        }

        let dnsAttempts = try await boundedMap(dnsWork, deadline: deadline) { work, timeout in
            try await dns.ipv4Addresses(for: work.domain, timeout: timeout)
        }
        let asnAttempts = try await boundedMap(asnWork, deadline: deadline) { work, timeout in
            try await asn.announcedPrefixes(for: work.number, timeout: timeout)
        }

        for service in catalog.services where dnsResults[service.id] == nil {
            dnsResults[service.id] = refreshResult(
                serviceID: service.id,
                source: .dns,
                values: dnsAttempts.filter { $0.0.serviceID == service.id },
                previous: retainsOnlyStillApplicableInputs(base?[service.id]?.dnsDomains ?? [], current: canonicalDomains(service.domains))
                    ? base?[service.id]?.dnsAddresses : nil,
                previousUpdatedAt: retainsOnlyStillApplicableInputs(base?[service.id]?.dnsDomains ?? [], current: canonicalDomains(service.domains))
                    ? base?[service.id]?.dnsUpdatedAt : nil,
                now: now
            )
        }
        for service in catalog.services where asnResults[service.id] == nil {
            asnResults[service.id] = refreshResult(
                serviceID: service.id,
                source: .ripeStat,
                values: asnAttempts.filter { $0.0.serviceID == service.id },
                previous: retainsOnlyStillApplicableInputs(base?[service.id]?.asnNumbers ?? [], current: canonicalASNs(service.asn))
                    ? base?[service.id]?.asnPrefixes : nil,
                previousUpdatedAt: retainsOnlyStillApplicableInputs(base?[service.id]?.asnNumbers ?? [], current: canonicalASNs(service.asn))
                    ? base?[service.id]?.asnUpdatedAt : nil,
                now: now
            )
        }

        var entries: [ServiceEnrichment] = []
        var diagnostics: [EnrichmentDiagnostic] = []
        for service in catalog.services {
            try Task.checkCancellation()
            let dnsResult = dnsResults[service.id]!
            let asnResult = asnResults[service.id]!
            entries.append(ServiceEnrichment(
                serviceID: service.id,
                dnsAddresses: dnsResult.values,
                asnPrefixes: asnResult.values,
                dnsDomains: canonicalDomains(service.domains),
                asnNumbers: canonicalASNs(service.asn),
                dnsUpdatedAt: dnsResult.updatedAt,
                asnUpdatedAt: asnResult.updatedAt,
                freshness: combinedFreshness(dns: dnsResult.freshness, asn: asnResult.freshness)
            ))
            diagnostics.append(contentsOf: dnsResult.diagnostics)
            diagnostics.append(contentsOf: asnResult.diagnostics)
        }
        let snapshotFreshness: String
        if entries.contains(where: { $0.freshness == .stale }) {
            snapshotFreshness = "stale-cache"
        } else if dnsWork.isEmpty && asnWork.isEmpty {
            snapshotFreshness = "cache-only"
        } else {
            snapshotFreshness = "refresh"
        }
        let provenance = [snapshotFreshness, base.map { "base=\($0.provenance)" }].compactMap { $0 }.joined(separator: "; ")
        return EnrichmentRefreshResult(
            snapshot: EnrichmentSnapshot(generatedAt: now, provenance: provenance, entries: entries),
            diagnostics: diagnostics
        )
    }

    private func refreshResult<Work>(
        serviceID: String,
        source: EnrichmentSource,
        values: [(Work, Result<[String], Error>)],
        previous: [String]?,
        previousUpdatedAt: Date?,
        now: Date
    ) -> SourceRefresh {
        let successful = values.compactMap { attempt -> [String]? in
            if case .success(let result) = attempt.1 { return result }
            return nil
        }.flatMap { $0 }
        let hadFailure = values.contains { attempt in
            if case .failure = attempt.1 { return true }
            return false
        }
        if hadFailure, let previous, !previous.isEmpty {
            return SourceRefresh(values: previous, updatedAt: previousUpdatedAt, freshness: .stale,
                                 diagnostics: [diagnostic(serviceID, source, .stale, "Источник недоступен; использован кэш", previousUpdatedAt)])
        }
        let normalized = collapseIPv4(successful)
        if normalized.isEmpty, let previous, !previous.isEmpty {
            return SourceRefresh(values: previous, updatedAt: previousUpdatedAt, freshness: .stale,
                                 diagnostics: [diagnostic(serviceID, source, .stale, "Пустой ответ не заменил последний успешный результат", previousUpdatedAt)])
        }
        let freshness: EnrichmentFreshness = hadFailure ? .stale : .fresh
        let message = hadFailure ? "Источник недоступен; подтверждённых данных нет" : "Источник обновлён"
        return SourceRefresh(values: normalized, updatedAt: hadFailure ? previousUpdatedAt : now, freshness: freshness,
                             diagnostics: [diagnostic(serviceID, source, freshness, message, hadFailure ? previousUpdatedAt : now)])
    }

    private func retired(
        serviceID: String,
        source: EnrichmentSource,
        previous: [String]?,
        previousInputs: [String]?,
        now: Date
    ) -> SourceRefresh {
        let hadEvidence = !(previous ?? []).isEmpty || !(previousInputs ?? []).isEmpty
        let diagnostics = hadEvidence
            ? [diagnostic(serviceID, source, .fresh, "Источник удалён из каталога; сохранённые данные удалены", now)]
            : []
        return SourceRefresh(values: [], updatedAt: now, freshness: .fresh, diagnostics: diagnostics)
    }

    private func cachedResult(_ serviceID: String, _ source: EnrichmentSource, _ values: [String], updatedAt: Date?, freshness: EnrichmentFreshness) -> SourceRefresh {
        let state: EnrichmentFreshness = freshness == .bundled ? .bundled : .cached
        return SourceRefresh(values: values, updatedAt: updatedAt, freshness: state,
                             diagnostics: [diagnostic(serviceID, source, state, "Использован действующий кэш", updatedAt)])
    }

    private func boundedMap<Input: Sendable, Output: Sendable>(
        _ inputs: [Input],
        deadline: Date,
        operation: @escaping @Sendable (Input, TimeInterval) async throws -> Output
    ) async throws -> [(Input, Result<Output, Error>)] {
        guard !inputs.isEmpty else { return [] }
        var results = Array<Result<Output, Error>?>(repeating: nil, count: inputs.count)
        try await withThrowingTaskGroup(of: (Int, Result<Output, Error>).self) { group in
            var next = 0
            let initial = min(limits.maximumConcurrentRequests, inputs.count)
            for index in 0..<initial {
                let input = inputs[index]
                group.addTask {
                    (index, try await timedResult(input: input, deadline: deadline, operation: operation))
                }
                next += 1
            }
            while let (index, result) = try await group.next() {
                results[index] = result
                if next < inputs.count {
                    let nextIndex = next
                    let input = inputs[nextIndex]
                    group.addTask {
                        (nextIndex, try await timedResult(input: input, deadline: deadline, operation: operation))
                    }
                    next += 1
                }
            }
        }
        return zip(inputs, results).compactMap { input, result in result.map { (input, $0) } }
    }

    private func timedResult<Input: Sendable, Output: Sendable>(
        input: Input,
        deadline: Date,
        operation: @escaping @Sendable (Input, TimeInterval) async throws -> Output
    ) async throws -> Result<Output, Error> {
        do {
            try Task.checkCancellation()
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { throw EnrichmentError.deadlineExceeded }
            return .success(try await withTimeout(min(limits.perRequestTimeout, remaining)) {
                try await operation(input, min(limits.perRequestTimeout, remaining))
            })
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return .failure(error)
        }
    }

    private func withTimeout<Output: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> Output
    ) async throws -> Output {
        try await withThrowingTaskGroup(of: Output.self) { group in
            group.addTask { try await operation() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                try Task.checkCancellation()
                throw EnrichmentError.deadlineExceeded
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw EnrichmentError.deadlineExceeded }
            return first
        }
    }

    private func isFresh(_ date: Date?, now: Date) -> Bool {
        guard let date else { return false }
        return now.timeIntervalSince(date) >= 0 && now.timeIntervalSince(date) <= limits.cacheTTL
    }

    private func diagnostic(_ serviceID: String, _ source: EnrichmentSource, _ freshness: EnrichmentFreshness, _ message: String, _ updatedAt: Date?) -> EnrichmentDiagnostic {
        EnrichmentDiagnostic(serviceID: serviceID, source: source, freshness: freshness, message: message, updatedAt: updatedAt)
    }

    private func combinedFreshness(dns: EnrichmentFreshness, asn: EnrichmentFreshness) -> EnrichmentFreshness {
        if dns == .stale || asn == .stale { return .stale }
        if dns == .bundled || asn == .bundled { return .bundled }
        if dns == .cached || asn == .cached { return .cached }
        return .fresh
    }

    private struct SourceRefresh {
        var values: [String]
        var updatedAt: Date?
        var freshness: EnrichmentFreshness
        var diagnostics: [EnrichmentDiagnostic]
    }

    private struct DNSWork: Sendable {
        var serviceID: String
        var domain: String
    }

    private struct ASNWork: Sendable {
        var serviceID: String
        var number: Int
    }
}

struct CatalogMatcher: Sendable {
    private let options: CatalogMatchOptions

    init(options: CatalogMatchOptions = CatalogMatchOptions()) {
        self.options = options
    }

    func match(
        catalog: ServiceCatalog,
        targeted: [TargetedRoute],
        lite: [String],
        full: [String],
        cached: EnrichmentSnapshot?
    ) throws -> MatchedCatalog {
        var routesByMode: [CatalogRouteMode: [String: [String]]] = [:]
        var unassigned: [CatalogRouteMode: [String]] = [:]
        var services = catalog.services
        let targetedMatched = try matchTargetedMode(services: services, targeted: targeted, cached: cached)
        routesByMode[.targeted] = targetedMatched.routes
        unassigned[.targeted] = targetedMatched.unassigned
        for index in services.indices {
            services[index].targetedAddresses = targetedMatched.routes[services[index].id] ?? []
        }

        for (mode, input) in [(CatalogRouteMode.lite, lite), (.full, full)] {
            let matched = try matchSourceBoundMode(services: services, source: input, targetedEvidence: targeted, cached: cached)
            routesByMode[mode] = matched.routes
            unassigned[mode] = matched.unassigned
            for index in services.indices {
                let routes = matched.routes[services[index].id] ?? []
                switch mode {
                case .lite: services[index].liteAddresses = routes
                case .full: services[index].fullAddresses = routes
                case .targeted: break
                }
            }
        }
        let freshness: EnrichmentFreshness
        if cached?.services.values.contains(where: { $0.freshness == .stale }) == true { freshness = .stale }
        else if cached?.services.values.contains(where: { $0.freshness == .bundled }) == true { freshness = .bundled }
        else if cached != nil { freshness = .cached }
        else { freshness = .fresh }
        return MatchedCatalog(
            catalog: ServiceCatalog(services: services, freshness: catalog.freshness, sourceURL: catalog.sourceURL, loadedAt: catalog.loadedAt),
            routesByMode: routesByMode,
            unassignedRoutes: unassigned,
            diagnostics: [],
            freshness: freshness
        )
    }

    func match(
        catalog: ServiceCatalog,
        targeted: [String],
        lite: [String],
        full: [String],
        cached: EnrichmentSnapshot?
    ) throws -> MatchedCatalog {
        try match(catalog: catalog, targeted: targeted.map { TargetedRoute(address: $0) }, lite: lite, full: full, cached: cached)
    }

    /// Targeted retains its original domain binding and can add confirmed DNS
    /// and explicit catalog CIDRs outside the legacy targeted source universe.
    /// Its unassigned partition is limited to the legacy source routes; unlike
    /// Lite/Full, the emitted service union intentionally contains additions.
    private func matchTargetedMode(
        services: [CatalogService],
        targeted: [TargetedRoute],
        cached: EnrichmentSnapshot?
    ) throws -> (routes: [String: [String]], unassigned: [String]) {
        let sourceNetworks = try validatedSource(targeted.map(\.address))
        let sourceIndex = IPv4RouteIndex(routes: sourceNetworks)
        var owned: [String: [IPv4Network]] = Dictionary(uniqueKeysWithValues: services.map { ($0.id, []) })
        var representationCount = 0

        for service in services {
            var evidence = service.ipRanges.compactMap(IPv4Network.init)
            evidence.append(contentsOf: cached?[service.id]?.dnsAddresses.compactMap(IPv4Network.init) ?? [])
            evidence.append(contentsOf: targeted.compactMap { route in
                route.domain.map({ canonicalDomains(service.domains).contains($0) }) == true
                    ? IPv4Network(route.address) : nil
            })
            let fragments = try validatedNetworks(evidence)
            try appendOwned(fragments, serviceID: service.id, owned: &owned, representationCount: &representationCount)
        }

        // Individual service validation catches direct and split defaults in a
        // single catalog row; validating the emitted union also catches a
        // semantic default assembled across several targeted additions.
        _ = try validatedNetworks(owned.values.flatMap { $0 })
        let assignedInsideSource = collapseIPv4(owned.values.flatMap { $0 }.flatMap { sourceIndex.intersections(with: $0) })
        let remaining = try subtractAssigned(
            assignedInsideSource,
            from: sourceNetworks,
            representationCount: &representationCount
        )
        let reconstructed = collapseIPv4(assignedInsideSource + remaining)
        guard ipv4SetsEqual(reconstructed, sourceNetworks) else {
            throw EnrichmentError.fragmentLimitExceeded(options.maximumFragments)
        }
        return (
            Dictionary(uniqueKeysWithValues: services.map { service in
                (service.id, collapseIPv4(owned[service.id] ?? []).map(\.description))
            }),
            collapseIPv4(remaining).map(\.description)
        )
    }

    /// Lite and Full can only emit exact evidence intersections with their own
    /// source universe, preserving source-set equality and no-widening.
    private func matchSourceBoundMode(
        services: [CatalogService],
        source: [String],
        targetedEvidence: [TargetedRoute],
        cached: EnrichmentSnapshot?
    ) throws -> (routes: [String: [String]], unassigned: [String]) {
        let sourceNetworks = try validatedSource(source)
        let index = IPv4RouteIndex(routes: sourceNetworks)
        var owned: [String: [IPv4Network]] = Dictionary(uniqueKeysWithValues: services.map { ($0.id, []) })
        var representationCount = 0

        for service in services {
            var evidence = service.ipRanges.compactMap(IPv4Network.init)
            if let cachedEvidence = cached?[service.id] {
                evidence.append(contentsOf: cachedEvidence.dnsAddresses.compactMap(IPv4Network.init))
                evidence.append(contentsOf: cachedEvidence.asnPrefixes.compactMap(IPv4Network.init))
            }
            let domains = canonicalDomains(service.domains)
            for route in targetedEvidence where route.domain.map({ domains.contains($0) }) == true {
                if let network = IPv4Network(route.address) { evidence.append(network) }
            }
            for proof in collapseIPv4(evidence) {
                try appendOwned(index.intersections(with: proof), serviceID: service.id, owned: &owned,
                                representationCount: &representationCount)
            }
        }

        var result: [String: [String]] = [:]
        for service in services {
            result[service.id] = collapseIPv4(owned[service.id] ?? []).map(\.description)
        }
        let assigned = collapseIPv4(owned.values.flatMap { $0 })
        let remaining = try subtractAssigned(assigned, from: sourceNetworks, representationCount: &representationCount)
        let reconstructed = collapseIPv4(owned.values.flatMap { $0 } + remaining)
        guard ipv4SetsEqual(reconstructed, sourceNetworks) else {
            throw EnrichmentError.fragmentLimitExceeded(options.maximumFragments)
        }
        return (result, collapseIPv4(remaining).map(\.description))
    }

    /// The cap counts every service-owned emitted fragment. A shared fragment
    /// therefore consumes one slot per owner, plus one if it is unassigned.
    private func appendOwned(
        _ fragments: [IPv4Network],
        serviceID: String,
        owned: inout [String: [IPv4Network]],
        representationCount: inout Int
    ) throws {
        guard representationCount <= options.maximumFragments - fragments.count else {
            throw EnrichmentError.fragmentLimitExceeded(options.maximumFragments)
        }
        owned[serviceID, default: []].append(contentsOf: fragments)
        representationCount += fragments.count
    }

    private func subtractAssigned(
        _ assigned: [IPv4Network],
        from sourceNetworks: [IPv4Network],
        representationCount: inout Int
    ) throws -> [IPv4Network] {
        var remaining: [IPv4Network] = []
        for route in sourceNetworks {
            do {
                let budget = options.maximumFragments - representationCount
                guard budget >= 0 else { throw EnrichmentError.fragmentLimitExceeded(options.maximumFragments) }
                let fragments = try route.subtracting(assigned.filter(route.intersects), limit: budget)
                guard representationCount <= options.maximumFragments - fragments.count else {
                    throw EnrichmentError.fragmentLimitExceeded(options.maximumFragments)
                }
                remaining.append(contentsOf: fragments)
                representationCount += fragments.count
            } catch let error as IPv4NetworkError {
                if case .fragmentLimitExceeded = error { throw EnrichmentError.fragmentLimitExceeded(options.maximumFragments) }
                throw error
            }
        }
        return remaining
    }

    private func validatedSource(_ values: [String]) throws -> [IPv4Network] {
        var result: [IPv4Network] = []
        for value in values {
            guard let network = IPv4Network(value) else { throw EnrichmentError.invalidSourceRoute(value) }
            result.append(network)
        }
        return try validatedNetworks(result)
    }

    private func validatedNetworks(_ values: [IPv4Network]) throws -> [IPv4Network] {
        let normalized = collapseIPv4(values)
        if options.rejectDefaultRoute, normalized.contains(where: { $0.prefix == 0 }) {
            throw EnrichmentError.rejectedDefaultRoute
        }
        let forbidden = options.forbiddenSourceRoutes.compactMap(IPv4Network.init)
        if let rejected = normalized.first(where: { network in
            forbidden.contains(where: { $0.intersects(network) })
        }) {
            throw EnrichmentError.forbiddenSourceRoute(rejected.description)
        }
        return normalized
    }
}
