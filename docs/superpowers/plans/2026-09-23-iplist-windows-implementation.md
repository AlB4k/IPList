# IPList Windows Implementation Plan

> **For agentic workers:** Implement tasks in order with `superpowers:executing-plans`; each task ends in a reviewable test or build result.

**Goal:** Build an independent Windows 10 22H2/Windows 11 IPList 1.4.0 app that preserves the macOS user contract for catalog selection, refresh, manual routes, profiles, history, and Amnezia exports.

**Architecture:** Keep all domain logic, persistence, matching, and export transforms in WPF-free `IPList.Core`; make `IPList.App` a WPF shell over those interfaces. Refreshes build and validate a complete candidate before one atomic state commit; user `.conf` files are parsed and rendered as preserved text, changing only the selected peer's `AllowedIPs`.

**Tech Stack:** C# 13 (`LangVersion=13.0`), .NET 10, WPF, `System.Text.Json`, Windows system DNS, GitHub Actions `windows-latest`; no external UI dependencies.

**Spec:** `docs/superpowers/specs/2026-09-23-iplist-windows-design.md`

## Global Constraints

- Target Windows 10 22H2 and Windows 11, `win-x64` only.
- Use WPF on C# 13 and .NET 10 LTS; set `LangVersion=13.0`.
- Keep Windows as an independent project in `Windows/`; do not reference macOS assemblies or modify Swift/macOS project, state, workflows, or release assets.
- Store state and service files under `%LOCALAPPDATA%\\IPList\\`; preserve old state until validated migration succeeds and create `state-before-v1.4.json` first.
- Use system DNS; do not send the whole catalog to public DoH. Limit enrichment to 8 concurrent requests, 12 seconds per request, 60 seconds per refresh, 4 MiB per response, and 250,000 generated CIDR fragments.
- Accept only the documented `config.yaml` subset; enforce 4 MiB, 2,000 services, 20,000 domains/ranges/ASNs, and 512 UTF-8 bytes per text field.
- Every Lite/Full source address must remain represented by selected services or the selected-by-default «Остальные сети источника» bucket; output must never expand or lose source addresses.
- On any failed validation or refresh, preserve the last successful model, selection, profiles, and autosaved export. Persist state and export with same-directory temporary files and atomic replacement.
- Never read, modify, or export `.vpn`; never change the source `.conf`; never persist or log keys, credentials, source config contents, or user exports.
- Bundle only licensed metadata/resources with attribution; do not bundle lib4u address-list exports, macOS artifacts, user state, or personal files.
- Release as `IPList-1.4.0-windows-x64.zip` containing a self-contained single-file `IPList.exe`, README, notices, and SHA-256; no installer, Store/MSIX, auto-update, signing requirement, or public release.
- Windows CI must build and test on `windows-latest`; release acceptance also requires manual smoke checks on clean Windows 10 22H2 and Windows 11.

## Review Focus

- **Source shrink, malformed metadata, or partial DNS/RIPEstat outage:** retain the last accepted model and cached evidence; cover in `IPList.Core.Tests/RefreshPipelineTests.cs`.
- **Broad Lite/Full routes with narrow or shared evidence:** exact source union and owner selection must hold; cover in `IPList.Core.Tests/CatalogMatcherTests.cs`.
- **CIDR subtraction/collapse and bare-IP normalization:** never widen the address set; cover in `IPList.Core.Tests/IPv4NetworkTests.cs` and `ExportTests.cs`.
- **Legacy or partially written state:** preserve manual entries, groups, notes, history, profiles, schedule, and settings; cover in `IPList.Core.Tests/StateStoreTests.cs`.
- **Malformed, multi-peer, or mixed-line-ending `.conf`:** preserve every byte outside the selected peer's `AllowedIPs`, reject unsafe output, and never expose secrets; cover in `IPList.Core.Tests/AmneziaConfigTests.cs`.

---

### Task 1: Create the Core domain, catalog, and safe refresh pipeline

**Files:**
- Create: `Windows/IPList.Windows.sln`, `Windows/src/IPList.Core/IPList.Core.csproj`, `Windows/tests/IPList.Core.Tests/IPList.Core.Tests.csproj`
- Create: `Windows/src/IPList.Core/Networking/IPv4Network.cs`, `RouteSet.cs`
- Create: `Windows/src/IPList.Core/Catalog/CatalogModels.cs`, `ServiceCatalogParser.cs`, `CatalogMatcher.cs`
- Create: `Windows/src/IPList.Core/Refresh/RefreshPipeline.cs`, `EnrichmentContracts.cs`
- Create: `Windows/src/IPList.Core/Resources/ThirdParty/pincetgore-config.yaml`, `pincetgore-LICENSE`
- Create: `Windows/tests/IPList.Core.Tests/IPv4NetworkTests.cs`, `ServiceCatalogParserTests.cs`, `CatalogMatcherTests.cs`, `RefreshPipelineTests.cs`, sanitized fixtures under `Windows/tests/IPList.Core.Tests/Fixtures/`

**Interfaces:**
- `IPv4Network.TryParse(string, out IPv4Network)`, `Contains`, `Intersects`, `Intersect`, and `Subtract(limit)`; `RouteSet.Normalize`, `Subtract`, `UnionEquals`.
- `ServiceCatalogParser.Parse(ReadOnlySpan<byte>) -> ServiceCatalog`; `CatalogMatcher.Match(catalog, sources, cachedEvidence) -> MatchedCatalog`.
- Inject `IDomainResolver.ResolveIPv4Async`, `IAsnPrefixLoader.LoadAsync`, and four source loaders into `RefreshPipeline.RunAsync(RefreshRequest, CancellationToken) -> RefreshTransaction`. The pipeline returns a complete candidate and diagnostics; it never mutates persisted state.

- [ ] Create the solution/projects targeting `net10.0` and `net10.0-windows`; reference Core from tests only and confirm the Core project has no WPF references.
- [ ] From repository root, scaffold with `dotnet new sln -n IPList.Windows -o Windows --format sln`, `dotnet new classlib -n IPList.Core -o Windows/src/IPList.Core --framework net10.0`, `dotnet new wpf -n IPList.App -o Windows/src/IPList.App`, and `dotnet new xunit -n IPList.Core.Tests -o Windows/tests/IPList.Core.Tests --framework net10.0`; add all three projects using `dotnet sln Windows/IPList.Windows.sln add Windows/src/IPList.Core/IPList.Core.csproj Windows/src/IPList.App/IPList.App.csproj Windows/tests/IPList.Core.Tests/IPList.Core.Tests.csproj`, then set C# 13 and Windows target framework in the project files.
- [ ] Add fixed-seed network tests for host-bit normalization, containment/intersection, exact subtraction, semantic dedupe, adjacent collapse, numeric sort, `/0`, `/31`, `/32`, and fragment-limit rejection; use a small per-address `HashSet<uint>` oracle to prove set equality.
- [ ] Parse sanitized YAML covering section categories, Aeroflot, `aeroflot.ru`, `api.aeroflot.ru`, AS34571, ranges, unknown keys, uncategorized services, duplicate IDs, invalid values, and every documented byte/item/string bound.
- [ ] Use fake DNS, RIPEstat, and source loaders to test targeted matching, exact Lite/Full partitioning, shared ownership, selected remainder, full source-union equality, cached partial enrichment, suspicious shrink, timeout, cancellation, and failure without mutation of any committed state.
- [ ] Run from repository root: `dotnet test Windows/tests/IPList.Core.Tests/IPList.Core.Tests.csproj --configuration Release`; expected: all Core tests pass.

### Task 2: Add durable state, migration, selection, and export history

**Files:**
- Create: `Windows/src/IPList.Core/State/AppState.cs`, `StateStore.cs`, `SelectionProfile.cs`, `ChangeRecord.cs`
- Create: `Windows/src/IPList.Core/Export/AmneziaJsonExporter.cs`, `AllowedIPsExporter.cs`
- Modify: `Windows/src/IPList.Core/IPList.Core.csproj`
- Create: `Windows/tests/IPList.Core.Tests/StateStoreTests.cs`, `SelectionTests.cs`, `ExportTests.cs`, `Fixtures/legacy-state.json`

**Interfaces:**
- `AppState.ExportRoutes(ExportMode)`, `SetSelection`, `ApplyProfile`, and `RecordChange` provide the single selection/export contract.
- `StateStore.LoadAsync(path) -> StateLoadResult` and `SaveAsync(state, path, rawLegacyBytes)` perform schema validation, one-time backup, and atomic replacement.
- `AmneziaJsonExporter.Serialize(routes) -> byte[]`; `AllowedIPsExporter.Format(routes) -> string` share normalized selected routes.

- [ ] Model catalog IDs and per-mode remainder selections, manual IP/groups/notes, history (last 100), profiles, mode, source URLs, interval 1–720/manual, last-check data, freshness, notification flags, and unseen changes.
- [ ] Add a sanitized pre-v1.4 fixture and prove backup creation precedes migration; failed decode or invalid candidate leaves original bytes and backup intact. Verify all manual data, profiles, schedule, URLs, history, and selections survive a successful migration and save/reload cycle.
- [ ] Test fresh-install defaults (all services and remainders selected), deselection with shared route owners, manual-enabled toggle, profile save/apply/update, change history cap and viewed state.
- [ ] Test Amnezia JSON records (`hostname`, empty `ip`, empty `ips`), `/32` rendering for bare IPs, semantic deduplication, covered-network removal, stable numeric order, and refusal to export an empty selection.
- [ ] Test same-directory temporary write plus atomic replace behavior with an injected filesystem failure; verify prior state/export remains readable.
- [ ] Run: `dotnet test Windows/tests/IPList.Core.Tests/IPList.Core.Tests.csproj --configuration Release`; expected: migration, selection, and export tests pass.

### Task 3: Implement the structure-preserving AmneziaWG editor

**Files:**
- Create: `Windows/src/IPList.Core/Amnezia/AmneziaConfigDocument.cs`, `AmneziaConfigError.cs`, `BatchOutputNamer.cs`
- Create: `Windows/tests/IPList.Core.Tests/AmneziaConfigTests.cs`, `BatchOutputNamerTests.cs`, fixtures containing only synthetic secret placeholders

**Interfaces:**
- `AmneziaConfigDocument.Parse(ReadOnlyMemory<byte>) -> AmneziaConfigDocument`; expose peer summaries without key values.
- `Render(peerIndex, AllowedIPsOperation, selectedRoutes, preserveIPv6) -> byte[]`; operations are `Add`, `Replace`, `Bypass`.
- `BatchOutputNamer.Create(inputPaths, outputDirectory) -> IReadOnlyList<string>` returns unique `<stem>-iplist.conf` paths.

- [ ] Test BOM, CRLF/LF, final newline, comments, whitespace suffixes, unknown AmneziaWG keys, duplicate `AllowedIPs` lines, one/multiple peers, and that unselected bytes remain identical.
- [ ] Test add/replace/bypass using exact IPv4 set operations; preserve IPv6 per policy; cover default route, overlapping peers, absent `AllowedIPs`, duplicate singleton keys, missing required keys, invalid CIDRs, empty result, and multi-file unique naming.
- [ ] Assert failures contain neither synthetic private/preshared keys nor source lines; reject the full batch before writing if any input or output name is invalid.
- [ ] Run: `dotnet test Windows/tests/IPList.Core.Tests/IPList.Core.Tests.csproj --configuration Release`; expected: all config preservation and safety tests pass.

### Task 4: Build the WPF desktop app and connect the complete user flow

**Files:**
- Create: `Windows/src/IPList.App/IPList.App.csproj`, `App.xaml`, `MainWindow.xaml`, `MainWindow.xaml.cs`
- Create: `Windows/src/IPList.App/ViewModels/MainViewModel.cs`, `DialogViewModels.cs`
- Create: `Windows/src/IPList.App/Services/WindowsDnsResolver.cs`, `WindowsNotifications.cs`, `TrayApplicationContext.cs`, `ScheduleService.cs`, `NativeFileDialogs.cs`, `ClipboardService.cs`
- Modify: `Windows/IPList.Windows.sln`
- Create: `Windows/src/IPList.App/Resources/` for attributed metadata only; `Windows/tests/IPList.Core.Tests/Fixtures/` remains synthetic

**Interfaces:**
- `MainViewModel` consumes `StateStore`, `RefreshPipeline`, and exporters; exposes `RefreshCommand`, `SetModeCommand`, selection/manual/profile/history/settings state, `IsBusy`, status, and safe user-facing errors.
- `TrayApplicationContext` offers Open, Refresh, Status, Exit; `ScheduleService` invokes the same guarded refresh command used by the window.
- Dialog services use native Windows Open/Save/Folder dialogs; clipboard and notification failures do not fail refresh or export.

- [ ] Implement the five pages in spec order—Catalog, My IP, Changes, Export, Settings—with the macOS section names/order, collapsed categories, search across name/domain/AS/IP/CIDR, per-mode service/remainder selection, freshness evidence, and clear empty/loading/error states.
- [ ] Wire manual IP/group/note CRUD and Amnezia JSON import preview; preserve invalid-row reporting, dedupe normalization, clipboard, and manual-address exclusion from enrichment.
- [ ] Wire JSON and `AllowedIPs` export, save/copy, folder open, `.conf` single/batch wizard, peer selection, three operations, IPv6 choice, Full-mode confirmation, and outputs beside user-selected files; never overwrite input files.
- [ ] Wire source checks, four HTTPS URLs, 1–720-hour/manual schedule, tray lifetime, close-to-tray choice, refresh exclusion, status notifications, and history viewed state. A second app instance must not start a parallel refresh for the same state.
- [ ] Keep WPF focus and keyboard behavior native; verify page layout at 100%, 125%, and 200%, and ensure no exception or key material appears in UI/log output.
- [ ] On Windows run: `dotnet build Windows/src/IPList.App/IPList.App.csproj -c Release -r win-x64`; expected: WPF app builds and launches. Run Core tests with the Task 3 command.

### Task 5: Add Windows CI, self-contained ZIP, documentation, and acceptance evidence

**Files:**
- Create: `.github/workflows/windows.yml`
- Create: `Windows/README.md`, `Windows/THIRD_PARTY_NOTICES.md`
- Modify: `Windows/src/IPList.App/IPList.App.csproj` only for publish metadata/resources

**Interfaces:**
- Publish command: `dotnet publish Windows/src/IPList.App/IPList.App.csproj -c Release -r win-x64 --self-contained true -p:PublishSingleFile=true`.
- Workflow artifact: `IPList-1.4.0-windows-x64.zip` with `IPList.exe`, README, notices, and `SHA256SUMS.txt`.

- [ ] Add a `windows-latest` workflow that installs .NET 10 SDK, runs `dotnet test Windows/tests/IPList.Core.Tests/IPList.Core.Tests.csproj -c Release`, runs the exact publish command, asserts `IPList.exe` and embedded metadata exist, asserts no runtime prerequisite, creates the ZIP and SHA-256, and uploads the artifact. Do not edit macOS workflows.
- [ ] Document supported OS/architecture, first launch/SmartScreen behavior, data location, refresh/cache behavior, import/export, tray/schedule, `.conf` safety, `.vpn` exclusion, limitations of Full, and manual smoke checklist. Preserve MIT attribution for bundled `config.yaml`/LICENSE; do not include generated lib4u lists.
- [ ] On clean Windows 10 22H2 and Windows 11 machines, unzip and launch without installed .NET; smoke-test 100/125/200% scaling, catalog search/selection, refresh/cache fallback, JSON import/export, copy/save `AllowedIPs`, single/batch `.conf`, tray/schedule, native dialogs, and persistence after restart.
- [ ] Inspect ZIP contents and SHA-256; scan for `.vpn`, keys, user state, exports, `.app`, `AppIcon.icns`, and `dist`. Check `git diff --name-only` and confirm every source/workflow change is under `Windows/`, `.github/workflows/windows.yml`, or Windows documentation.
- [ ] Acceptance is complete only when Core tests pass, CI publishes the self-contained ZIP, both OS smoke checks pass, and `.conf` source bytes/secrets remain unchanged and absent from the artifact.
