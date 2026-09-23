# Changelog

All notable changes to IPList are documented here.

## 1.4.1 — 2026-09-23

### Fixed

- Source refresh no longer compares saved synthetic domain cards from the Targeted list against YAML service metadata. This removes the false catalog shrink error seen after 1.4.0 (for example, 1762 saved entries versus 276 YAML services).
- The shrink guard still rejects a genuinely incomplete YAML catalog, preserving the last verified state.

## 1.4.0 — 2026-09-20

### Added

- Service catalog based on the licensed `pincetgore/amnezia-app-ru-list` metadata snapshot, with categories, domains, ASN values, explicit ranges, freshness information, and searchable services.
- Per-mode route matching for Targeted, Lite, and Full, including visible selected-by-default source remainders so each Lite/Full source set remains complete.
- DNS and RIPEstat enrichment with bounded concurrency, deadline, cached last-known-good evidence, diagnostics, and a bundled evidence snapshot for a clean installation.
- `AllowedIPs` copy and save actions with normalized, semantic IPv4/CIDR deduplication.
- AmneziaWG `.conf` enrichment with peer selection, add, replace, and bypass operations; original files remain untouched and batch inputs create independent outputs.
- Full-mode route/size summary and a blocking mobile warning before `AllowedIPs` actions.
- A one-time `state-before-v1.4.json` backup before the first 1.4 state migration.
- A verified catalog override for 1С: separate service card, common `1c.ru` endpoints, AS61293, and the confirmed `185.12.152.0/22` network.

### Changed

- Service and category selection now applies consistently to Targeted, Lite, and Full exports; shared route fragments stay selected while another selected service owns them.
- Source refresh is atomic across the catalog and all three address sources. An incomplete transaction preserves the previous successful catalog, selections, and automatic export.
- Diagnostics distinguish catalog, Targeted, Lite, Full, DNS, and RIPEstat results.
- Metadata overrides are reapplied to remote, cached, and bundled catalog generations, so an upstream refresh cannot remove the 1С mapping.

### Security and compatibility

- Configuration private keys and other `.conf` contents are handled in memory and are not written to IPList state, history, or logs.
- `.vpn` profiles are not read, modified, or exported.
- The local app remains ad-hoc signed and is not notarized.

### Third-party data

- Bundles the pinned MIT-licensed catalog snapshot, its license text, and the recorded enrichment snapshot. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Does not vendor lib4u runtime address-list files.
