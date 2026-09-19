# Task 6 — fix round 1

## Findings closed

- Replaced the structured overall-deadline task group with a locked,
  unstructured deadline race. Timeout and caller cancellation now resume the
  refresh immediately, request cancellation of the worker, and discard every
  late worker result. A callback-backed loader that ignores task cancellation
  therefore cannot hold `Store.busy` beyond the deadline or publish a late
  transaction.
- Added `sourceRouteSnapshots` to `AppState`. It decodes to an empty migration
  default and is replaced only by `applyRefreshTransaction`; it stores the
  normalized raw Targeted, Lite, and Full source sets before catalog ownership
  fragments are formed. Source history now compares this snapshot with the
  next raw transaction set. The first migrated refresh establishes a baseline
  without synthesizing a source change.
- `AppState.saveProfile` returns the created or updated UUID after sorting.
  `Store.saveProfile` uses that UUID, so a newly created alphabetically early
  profile remains the active profile instead of selecting an older final row.

## Regression coverage

- `RefreshChecks` now uses a `DispatchQueue.asyncAfter` continuation that
  deliberately ignores cancellation. Both a 20 ms deadline and explicit
  cancellation return in under 120 ms instead of waiting for its 250 ms late
  result.
- Added atomic raw-snapshot persistence coverage and a partitioned `/24`
  regression: the stored catalog representation has multiple owner/remainder
  fragments, while the next identical raw source produces no route change.
- Added 1.3 decode/default coverage for raw snapshots and profile-ID coverage
  for a `Z` profile followed by an `A` profile.

## Validation

- `./scripts/test.sh` — passed.
- `./scripts/test-task7.sh` — passed.
- `swift build` and `swift build -c release` — passed.
- `IPLIST_LIVE_TEST=1 ./scripts/test.sh` and `./scripts/build-app.sh` — passed.

The Task 7 isolated harness prints existing macOS 14 `onChange` deprecation
warnings from `App.swift`; no Task 6 failure was reported.
