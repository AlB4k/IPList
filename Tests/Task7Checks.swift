import Foundation

func task7Check(_ value: Bool, _ message: String) {
    precondition(value, message)
}

@main struct Task7Checks {
    static func main() throws {
        try testCatalogSearch()
        testCatalogSelectionAndRowCopy()
        testConfigurationRecommendations()
        try testPeerChoiceAndCollision()
        testBatchOutputNames()
        print("Task 7 checks passed")
    }

    private static func testCatalogSearch() throws {
        let aeroflot = CatalogService(
            id: "aeroflot",
            name: "Аэрофлот",
            category: "Транспорт и путешествия",
            domains: ["aeroflot.ru", "api.aeroflot.ru"],
            asn: [34571],
            targetedAddresses: ["212.42.192.0/19"],
            liteAddresses: ["212.42.192.0/19"],
            fullAddresses: ["212.42.192.0/19"]
        )

        for query in ["Аэрофлот", "aeroflot.ru", "AS34571", "212.42.193.7", "212.42.192.0/20"] {
            task7Check(catalogMatches(service: aeroflot, query: query, mode: .targeted), "Catalog search must find Aeroflot for \(query)")
        }
        task7Check(!catalogMatches(service: aeroflot, query: "неизвестный сервис", mode: .targeted), "Catalog search must not invent matches")
    }

    private static func testConfigurationRecommendations() {
        task7Check(
            recommendedConfigurationOperation(existingRoutes: ["10.0.0.0/8"]) == .add,
            "A partial IPv4 configuration should recommend adding routes"
        )
        task7Check(
            recommendedConfigurationOperation(existingRoutes: ["0.0.0.0/0"]) == .bypassOrReplace,
            "A default IPv4 route should recommend bypass or replacement"
        )
    }

    private static func testCatalogSelectionAndRowCopy() {
        task7Check(
            catalogSelectionAllModesExplanation.contains("во всех трёх режимах"),
            "Settings must describe selection as applying in every export mode"
        )
        task7Check(
            catalogSelectionAllModesExplanation.contains("Lite") &&
                catalogSelectionAllModesExplanation.contains("Полный российский сегмент"),
            "Settings must name the affected non-targeted modes"
        )
        let service = CatalogService(
            id: "domains",
            name: "Сервис",
            domains: ["one.example", "two.example"],
            targetedAddresses: ["192.0.2.0/24"]
        )
        let details = catalogServiceRowDetails(service: service, mode: .targeted, freshness: "данные свежие")
        task7Check(details.contains("1 маршрут"), "Collapsed row must retain the current-mode route count")
        task7Check(details.contains("2 домена"), "Collapsed row must retain the domain count")
        task7Check(details.contains("данные свежие"), "Collapsed row must retain freshness")
    }

    private static func testPeerChoiceAndCollision() throws {
        let onePeer = try AmneziaWGDocument.parse("[Interface]\nPrivateKey = private\n\n[Peer]\nPublicKey = first\nAllowedIPs = 10.0.0.0/8\n")
        task7Check(!configurationNeedsPeerChoice(onePeer), "One peer must not require a choice")

        let twoPeers = try AmneziaWGDocument.parse("[Interface]\nPrivateKey = private\n\n[Peer]\nPublicKey = first\nAllowedIPs = 10.0.0.0/8\n\n[Peer]\nPublicKey = second\nAllowedIPs = 192.0.2.0/24\n")
        task7Check(configurationNeedsPeerChoice(twoPeers), "Several peers must require a choice")
        task7Check(
            !configurationCanBeSaved(document: twoPeers, peer: 0, operation: .add, routes: ["192.0.2.0/24"], preserveIPv6: true),
            "A newly introduced cross-peer overlap must block saving"
        )
    }

    private static func testBatchOutputNames() {
        let outputs = enrichedConfigurationOutputNames(for: ["home.conf", "home.conf", "work.conf"])
        task7Check(outputs == ["home-iplist.conf", "home-iplist-2.conf", "work-iplist.conf"], "Duplicate input basenames need stable unique outputs")
        task7Check(Set(outputs).count == 3, "Every selected configuration must retain an independent output")
    }
}
