# Task 6 — atomic refresh pipeline and diagnostics

## Delivered

- Replaced the mode-specific `Store.refresh()` path with one `RefreshPipeline`
  transaction. It concurrently loads service metadata, Targeted, Lite, and
  Full sources; enriches and matches only after all source candidates are
  available; and changes `AppState` once through
  `applyRefreshTransaction`.
- A rejected source, metadata validation, matcher validation, overall deadline,
  or cancellation creates no transaction and `Store` does not persist, export,
  alter last-success timestamps, history, or notifications.
- Preserved the configured Targeted, Lite, and Full URLs. Remote metadata may
  use the last validated persisted catalog only for an actual transport
  failure; malformed or suspicious metadata remains a rejected refresh.
- Added source results for metadata, three route sources, DNS, and RIPEstat,
  including counts, durations, cache/bundle/stale messages and actionable
  failure text. A failed route download waits for the other route tasks so the
  resulting diagnostics remain complete.
- Manual and scheduled execution now call the same whole-data refresh. Success
  updates all three last-success timestamps and preserves the existing change
  history and notification behavior, now recording each changed source.
- Persists the exact decoded pre-1.4 file bytes to `state-before-v1.4.json`
  before the first v1.4 state write, only once, while retaining the existing
  `state-before-v1.1.json` behavior.

## Tests

- Added `Tests/RefreshChecks.swift`, wired into `./scripts/test.sh`.
  It covers successful all-mode replacement, custom URLs, source and catalog
  failure, complete route diagnostics on failure, stale cache, bundled first
  run evidence, deadline, matcher fragment rejection, cancellation, raw
  migration backup, and preservation of the v1.1 backup.
- `./scripts/test.sh` — passed.
- `IPLIST_LIVE_TEST=1 ./scripts/test.sh` — passed. Live checks observed 556
  catalog services, 1,471 Targeted IPs, 1,040 Lite ranges, and 12,819 Full
  ranges; primary and reserve route URLs plus category data returned HTTP 200.
- `swift build`, `swift build -c release`, and `./scripts/build-app.sh` —
  passed. The debug/release linker retained the repository's existing missing
  Command Line Tools search-path warnings.

## Review notes

- Inspected every uncommitted Task 6 line. The only corrective change made to
  the inherited pipeline was waiting for all route outcomes before returning a
  source failure; the regression test first failed against the early-cancel
  implementation and passes with the corrected behavior.
- No new review findings remain in the Task 6 scope.
