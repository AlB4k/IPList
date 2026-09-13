<p align="center">
  <img src="Resources/GitHub/logo-256.png" alt="IPList logo" width="128" height="128">
</p>

# IPList

IPList is a native SwiftUI app for macOS 13+ that keeps an AmneziaVPN split tunneling bypass list up to date. It downloads public Amnezia-compatible lists, lets you choose which service categories should bypass VPN, tracks changes between checks, and exports JSON in the format AmneziaVPN can import.

The app was built around [lib4u/amnezia-tunneling-ru](https://github.com/lib4u/amnezia-tunneling-ru). It supports all three current upstream list variants:

- `amnezia.json`: targeted bypass for known services, with category and service selection inside IPList.
- `amnezia-ip-lite.json`: compact IPv4 subnet list intended for mobile clients and stricter environments.
- `amnezia-ip.json`: full Russian IPv4 segment list for maximum desktop coverage.

Manual addresses can be added in the "My IP" category and optionally included in any export mode.

## Features

- Manual update button and in-app schedule from 1 to 720 hours.
- Source diagnostics page with HTTP status, response time, parsed address count, and exact failing URL.
- Retry and official fallback handling between GitHub Releases and `raw.githubusercontent.com`.
- Category tree with collapsed groups by default, global select-all, search, and per-service selection.
- Named profiles for saving and restoring selected services, export mode, and the "My IP" inclusion flag.
- Import of an existing Amnezia JSON export for manual address selection.
- Change history for added and removed addresses between successful checks.
- Automatic local export to `~/Library/Application Support/IPList/amnezia-direct.json`.
- Menu bar presence, so scheduled checks can continue while the main window is closed.

## Install And Run

Build a local app bundle:

```sh
./scripts/build-app.sh
open dist/IPList.app
```

The produced app is ad-hoc signed and intended for local use on this Mac. It is not notarized for public distribution.

For regular use, move `IPList.app` to `/Applications` and add it to "System Settings -> General -> Login Items" if scheduled checks should resume after reboot.

## Using The App

1. Open IPList and click "Check now".
2. In "Catalog", choose the export mode and select categories or individual services. All categories are selected by default, and groups are collapsed by default.
3. In "My IP", add IPv4/CIDR entries manually or import an existing Amnezia JSON file. Imported entries are shown for selection and are not enabled silently.
4. In "Export", choose whether manual addresses should be included, then save the JSON file.
5. In AmneziaVPN, open site split tunneling, choose the mode where addresses from the list should not use VPN, and import the exported JSON.

When re-importing into AmneziaVPN, check how the client handles previous entries. IPList exports the current desired list, but AmneziaVPN may merge with old imported rules instead of replacing them, depending on the client version and workflow.

## Export Modes

The targeted mode uses `amnezia.json` and applies the category/service selection from IPList. It is the best mode when only known services should bypass VPN.

The Lite and Full modes export the upstream IP range files as whole datasets. Their source format does not preserve a reliable one-to-one relationship between subnet and service category, so category selection is intentionally limited to the targeted mode. Manual addresses can still be included in Lite and Full exports.

IPv6 is not exported. Domain-only entries are visible in the catalog only when the upstream source does not provide an IPv4 address for them.

## Data Storage

IPList stores its local state in:

```text
~/Library/Application Support/IPList/
```

Files in that directory include:

- `state.json`: downloaded catalog, selections, profiles, manual addresses, schedule settings, cached Lite/Full lists, and recent history.
- `state-before-v1.1.json`: one-time backup created on first launch after upgrading to version 1.1.
- `amnezia-direct.json`: automatically saved export for the currently selected mode.

User-provided manual IP addresses are stored only locally. They are not sent to upstream list sources.

## Sources

Default source URLs:

```text
https://github.com/lib4u/amnezia-tunneling-ru/releases/download/latest/amnezia.json
https://github.com/lib4u/amnezia-tunneling-ru/releases/download/latest/amnezia-ip-lite.json
https://github.com/lib4u/amnezia-tunneling-ru/releases/download/latest/amnezia-ip.json
https://raw.githubusercontent.com/v2fly/domain-list-community/master/data/
```

The app also understands compatible custom HTTPS URLs in the same JSON shape.

Category names are derived from files in `v2fly/domain-list-community`, including include chains, `full`, `domain`, and plain domain entries. `regexp` and `keyword` rules are not converted into invented addresses.

## Development

Requirements:

- macOS 13 or newer for running the app.
- Swift Command Line Tools or Xcode with Swift 5.9 support.
- Network access for live source checks.

Build and test:

```sh
./scripts/test.sh
./scripts/build-app.sh
```

Optional live test against real upstream sources:

```sh
IPLIST_LIVE_TEST=1 ./scripts/test.sh
```

The test harness is a standalone Swift executable and does not require XCTest. It covers address normalization, import/export behavior, default selection, migration, profiles, retry logic, fallback URLs, artificial timeout behavior, invalid JSON handling, diagnostics, and the three export modes.

## GitHub Publication Status

This repository is prepared for GitHub publication, but it has not been published from this workspace.

Before making the repository public, decide and add a license file. Until then, the project has no explicit open-source license. Also review whether the app name, bundle identifier, screenshots, and distribution method should be changed for a public release.

Third-party source notes are documented in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md). The repository does not include vendored copies of upstream Amnezia list files.

## Security And Privacy Notes

IPList downloads public list files from the configured URLs and writes local JSON files. It does not control AmneziaVPN directly and does not modify VPN settings.

The app stores local state under the current macOS user account. Do not commit files from `~/Library/Application Support/IPList/`; they may contain personal manual IP entries.
