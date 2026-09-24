import Foundation

enum ExportTarget: String, CaseIterable, Identifiable {
    case macOS = "macOS"
    case windows = "Windows"
    var id: String { rawValue }
    var maxRoutes: Int? { self == .windows ? 500 : nil }
    var fileSuffix: String { "-\(rawValue)" }
}

enum ExportValidationError: LocalizedError, Equatable {
    case invalidRoute(String)
    case tooManyRoutes(target: ExportTarget, count: Int, limit: Int)
    var errorDescription: String? {
        switch self {
        case let .invalidRoute(route): return "Выгрузка остановлена: некорректный маршрут \(route)."
        case let .tooManyRoutes(target, count, limit): return "Выгрузка для \(target.rawValue) остановлена: \(count) маршрутов, максимум \(limit). Выберите Lite или уменьшите выбор сервисов."
        }
    }
}

enum ExportSafetyLevel { case safe, elevated, warning, blocked }
struct ExportSafetySummary {
    let catalogCount: Int
    let remainderCount: Int
    let manualCount: Int
    let routeCount: Int
    let level: ExportSafetyLevel
    let message: String
}

func exportSafetySummary(routeCount: Int, target: ExportTarget) -> ExportSafetySummary {
    let level: ExportSafetyLevel
    switch target {
    case .windows:
        level = routeCount > 500 ? .blocked : routeCount > 400 ? .warning : routeCount > 300 ? .elevated : .safe
    case .macOS:
        level = routeCount > 5_000 ? .warning : routeCount > 2_000 ? .elevated : .safe
    }
    let message: String
    switch level {
    case .safe: message = target == .windows ? "Допустимый объём для Windows." : "Допустимый объём для macOS."
    case .elevated: message = "Объём повышенный: проверьте необходимость всех сервисов."
    case .warning: message = target == .windows ? "Почти достигнут лимит Windows." : "Большой список: AmneziaVPN может подключаться дольше."
    case .blocked: message = "Выгрузка заблокирована: Windows допускает максимум 500 маршрутов."
    }
    return ExportSafetySummary(catalogCount: 0, remainderCount: 0, manualCount: 0, routeCount: routeCount, level: level, message: message)
}

func validatedRoutes(_ addresses: Set<String>, for target: ExportTarget) throws -> [IPv4Network] {
    let parsed = addresses.compactMap(IPv4Network.init)
    guard parsed.count == addresses.count else {
        throw ExportValidationError.invalidRoute(addresses.first { IPv4Network($0) == nil } ?? "?")
    }
    let routes = collapseIPv4(parsed)
    if let limit = target.maxRoutes, routes.count > limit {
        throw ExportValidationError.tooManyRoutes(target: target, count: routes.count, limit: limit)
    }
    return routes
}

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
