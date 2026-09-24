import Foundation

enum AppUpdateStatus: Equatable {
    case upToDate
    case updateAvailable(version: String, url: URL)
    case failed(message: String)
}

struct AppUpdateChecker {
    struct Release: Decodable {
        let tag_name: String
        let html_url: URL
        let draft: Bool
        let prerelease: Bool
    }

    static let endpoint = URL(string: "https://api.github.com/repos/AlB4k/IPList/releases")!

    static func check(currentVersion: String, endpoint: URL = Self.endpoint, session: URLSession = .shared) async -> AppUpdateStatus {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 10
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("IPList/1.0", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                return .failed(message: "GitHub вернул ошибку проверки обновлений.")
            }
            let releases = try JSONDecoder().decode([Release].self, from: data)
                .filter { !$0.draft && !$0.prerelease }
            guard let release = releases.first else { return .upToDate }
            let version = release.tag_name.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard !version.isEmpty else { return .failed(message: "GitHub вернул некорректную версию релиза.") }
            return compare(version, currentVersion) == .orderedDescending
                ? .updateAvailable(version: version, url: release.html_url)
                : .upToDate
        } catch {
            return .failed(message: "Не удалось проверить обновления: (error.localizedDescription)")
        }
    }

    private static func compare(_ lhs: String, _ rhs: String) -> ComparisonResult {
        let left = lhs.split(separator: ".").map { Int($0) ?? 0 }
        let right = rhs.split(separator: ".").map { Int($0) ?? 0 }
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a < b ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
}
