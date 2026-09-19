# Task 3 loader implementation report

Implementation commits: `4eba7852fcd046f3c468c4f50141f1514631c4a4` (`feat: load licensed service metadata catalog`) and `26ad6a0a0888e1f02b3b635b3fd38b9621f791b9` (`fix: preserve legacy catalog decoding`).

## Interfaces

- `CatalogService` contains the stable ID, name, category, normalized domains, ASN values, explicit IPv4 ranges, and separate targeted/Lite/Full address slots for later enrichment.
- `ServiceCatalog` contains validated services plus `freshness`, source URL, and load date metadata.
- `ServiceCatalogParser.parse(_:)` accepts UTF-8 `Data` or `String` and parses only `services`, `name`, `asn`, `ip_ranges`, `domains`, and bounded category comments. Unknown keys and their nested lists are opaque.
- `ServiceCatalogLoader.load(remoteURL:fallbackData:previousCatalog:)` is remote-first and returns a `ServiceCatalog` marked `.remote` or `.cached`. String URL overloads are provided as well.

Stable IDs use the source identifier `pincetgore/amnezia-app-ru-list` and a normalized name slug. Duplicate IDs reject the candidate catalog.

## Validation limits

The parser enforces a 4 MiB input limit, 2,000 services, 20,000 domains, 20,000 explicit ranges, 20,000 ASN entries, and 512 UTF-8 bytes per text/item field. It rejects empty catalogs, empty service names, services with no metadata, invalid ASN values, invalid IPv4 ranges, malformed bounded arrays, and stable-ID collisions. IPv4 host bits are normalized while parsing ranges.

The loader enforces an absolute minimum of one service by default (configurable) and rejects a candidate below 50% of the previous successful catalog by default (also configurable). A valid fallback is only published after the same validation.

## Verification

- `swiftc -parse-as-library Sources/IPList/CatalogModels.swift Sources/IPList/ServiceCatalogLoader.swift Tests/CatalogChecks.swift -o .build/checks/catalog-checks && .build/checks/catalog-checks` — passed.
- `swiftc -parse-as-library Sources/IPList/CatalogModels.swift Sources/IPList/ServiceCatalogLoader.swift Sources/IPList/Core.swift Tests/CatalogChecks.swift -o .build/checks/catalog-checks-with-core && .build/checks/catalog-checks-with-core` — passed.
- `./scripts/test.sh` — passed (`All checks passed`).
- `swift build` — passed; existing linker search-path warnings remain from the local toolchain setup.
- `git diff --check` — passed for the implementation commit.

The isolated `Tests/CatalogChecks.swift` covers Aeroflot parsing and category normalization, unknown-field state isolation, invalid ASN/range rejection, stable-ID collisions, relative shrink rejection, legacy Codable defaults, remote failure with cached fallback, and remote failure without fallback.

## Gaps and handoff

The live upstream YAML, enrichment snapshot, license file, build-app resource copy, notices update, and live-network test remain with the separate source-preparation task. `Tests/CoreChecks.swift` and `scripts/test.sh` were not edited. Enrichment, route matching, migration, and persistence are subsequent tasks.
