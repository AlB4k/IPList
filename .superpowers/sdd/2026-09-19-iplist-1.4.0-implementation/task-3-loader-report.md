# Task 3 loader implementation report

Implementation commits: `4eba7852fcd046f3c468c4f50141f1514631c4a4` (`feat: load licensed service metadata catalog`), `26ad6a0a0888e1f02b3b635b3fd38b9621f791b9` (`fix: preserve legacy catalog decoding`), `3f274e63472685fc3be855f67483fb243bffc853` (`fix: harden service catalog loading`), and `c2254f9ee9b22586c40c6b5ccdf6fdc32a25586b` (`fix: preserve catalog cache provenance`).

## Interfaces

- `CatalogService` contains the stable ID, name, category, normalized domains, ASN values, explicit IPv4 ranges, and separate targeted/Lite/Full address slots for later enrichment.
- `ServiceCatalog` contains validated services plus `freshness`, source URL, and load date metadata.
- `ServiceCatalogParser.parse(_:)` accepts UTF-8 `Data` or `String` and parses only `services`, `name`, `asn`, `ip_ranges`, `domains`, and bounded category comments. Unknown keys and their nested lists are opaque.
- `ServiceCatalogLoader.load(remoteURL:fallbackData:previousCatalog:)` is remote-first and returns a `ServiceCatalog` marked `.remote` or `.cached`. String URL overloads are provided as well.

Stable IDs use the source identifier `pincetgore/amnezia-app-ru-list` and a normalized name slug. Duplicate IDs reject the candidate catalog.

## Validation limits

The parser enforces a 4 MiB input limit, 2,000 services, 20,000 domains, 20,000 explicit ranges, 20,000 ASN entries, and 512 UTF-8 bytes per text/item field. It rejects empty catalogs, empty service names, services with no metadata, invalid ASN values, invalid IPv4 ranges, scalar known-list fields, opened empty block lists, malformed bounded arrays, and stable-ID collisions. IPv4 host bits are normalized while parsing ranges. Category metadata is recognized only in the upstream divider / uppercase-heading / divider shape; ordinary, incomplete, or unsupported comments assign the next service to `Без категории`.

The loader enforces an absolute minimum of one service by default (configurable) and rejects a candidate below 50% of the previous successful catalog by default (also configurable). A valid fallback is only published after the same validation. Returning the last successful catalog marks it cached while preserving its original source URL and `loadedAt` timestamp.

## Verification

- `swiftc -parse-as-library Sources/IPList/CatalogModels.swift Sources/IPList/ServiceCatalogLoader.swift Tests/CatalogChecks.swift -o .build/checks/catalog-checks && .build/checks/catalog-checks` — passed.
- `swiftc -parse-as-library Sources/IPList/CatalogModels.swift Sources/IPList/ServiceCatalogLoader.swift Sources/IPList/Core.swift Tests/CatalogChecks.swift -o .build/checks/catalog-checks-with-core && .build/checks/catalog-checks-with-core` — passed.
- Standalone deterministic and live catalog checks — passed (`Catalog checks passed` in both modes).
- `./scripts/test.sh` — currently reaches the parallel Task 2 checks but fails there with `AmneziaWGConfigError.invalidStructure`; the catalog phase passes when run standalone.
- `swift build` — passed; existing linker search-path warnings remain from the local toolchain setup.
- `git diff --check` — passed for the implementation commit.

The isolated `Tests/CatalogChecks.swift` covers Aeroflot parsing and category normalization, unknown-field state isolation, category-comment regressions, invalid ASN/range rejection, scalar and empty-list rejection, stable-ID collisions, relative shrink rejection, legacy Codable defaults, remote failure with cached fallback, last-successful-catalog precedence and timestamp/provenance preservation, remote failure without fallback, and the environment-gated live source check.

## Gaps and handoff

The live upstream YAML, enrichment snapshot, license file, build-app resource copy, and notices update remain with the separate source-preparation/enrichment tasks. `Tests/CoreChecks.swift` was not edited. `scripts/test.sh` now runs the standalone deterministic catalog harness. Direct deterministic/live catalog checks and `swift build` pass (with the existing local linker search-path warnings); the full script is blocked by the parallel Task 2 runtime failure `AmneziaWGConfigError.invalidStructure`. Enrichment, route matching, migration, and persistence are subsequent tasks.
