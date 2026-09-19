# Task 3 resource and licensing report

Date: 2026-09-19

## Upstream provenance

- Repository: https://github.com/pincetgore/amnezia-app-ru-list
- Source files: `config.yaml` and `LICENSE`
- Exact upstream commit: `b8cb9566109232f07ceccfe98cce7388c84e773d`
- Commit date: `2026-09-17T19:56:50+03:00`
- Snapshot retrieval date: `2026-09-19`
- Retrieval method: `git ls-remote` to resolve `HEAD`, then a depth-1 fetch of that exact commit and extraction of the two tracked files.

SHA-256 checksums of the committed copies:

- `Resources/ThirdParty/pincetgore-config.yaml`: `d22b844be82ef80cbbb305adf5b9308245a97cfc6822c0c45a0d8897ea32b53e`
- `Resources/ThirdParty/pincetgore-LICENSE`: `89e30247532df2f24ffa96e846f8697222c413cbb1593e6a975fdf5e19955f66`

Both files were byte-compared with the exact files extracted from the upstream commit.

## Repository and bundle changes

- Added the upstream `config.yaml` and MIT license text under `Resources/ThirdParty/`.
- Updated `THIRD_PARTY_NOTICES.md` with the source URL, commit, commit date, snapshot date, retrieval method, license attribution, and checksums in Russian and English.
- Updated `scripts/build-app.sh` to copy every file in `Resources/ThirdParty/` into `IPList.app/Contents/Resources/ThirdParty/`, so a later Task 4 enrichment snapshot is bundled automatically when it exists.
- `Resources/ThirdParty/enrichment-snapshot.json` is intentionally absent. The brief assigns deterministic per-service enrichment generation to Task 4; no snapshot was invented or copied without recorded DNS/RIPEstat provenance.

## Verification

- Resource byte comparison: passed for both files.
- Resource bundle-copy check: passed; both files copied into a temporary `IPList.app/Contents/Resources/ThirdParty/` directory and compared byte-for-byte.
- `git diff --check`: clean for `THIRD_PARTY_NOTICES.md`, `scripts/build-app.sh`, and this report; the exact upstream YAML retains two source indentation-only whitespace lines, which `git diff --check` reports and which were preserved for byte identity.
- `swift build -c release`: currently blocked by an unrelated compile error in the shared worktree’s `Sources/IPList/AddressMatcher.swift` (`static member 'append' cannot be used on instance of type 'IPv4Network'`, lines 74 and 77). No Swift or test files were changed for this resource task.
