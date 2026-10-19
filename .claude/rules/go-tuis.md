---
paths:
  - "cmd/**"
  - "internal/**"
  - "bin/analyze.sh"
  - "bin/status.sh"
  - "go.mod"
---

# Go TUIs: `cmd/analyze` and `cmd/status`

## Analyze

- `cmd/analyze/` is the Go disk-analysis TUI. `cmd/analyze/main.go` is bootstrap only (flag parsing, `main()`, helpers); `cmd/analyze/model.go` holds types, the model struct and accessor methods.
- `cmd/analyze/update.go` owns the Bubble Tea `Update` chain and message handlers (Init, scanCmd, updateKey, goBack, switchToOverviewMode, enterSelectedDir). This is the largest file in `cmd/analyze/` and the natural landing spot for new key bindings, message types, or navigation behavior. Run `go test ./cmd/analyze`.
- `cmd/analyze/cache.go` owns analyze cache schema, expiry, load/save, invalidation, and cacheability decisions. Computation changes must invalidate stale persisted data in the same change. TUI cache writers register a `scanPublication` before dispatch. Cancel affected live, overview, and background publications before delete or refresh invalidation, and validate overview message identity before clearing its active request. Keep registry mutations on the model event loop; prefetch workers receive a separate immutable jobs map. Preserve unaffected paths. Run `go test ./cmd/analyze`.
- Reserve each directory scan identity and cancellation handle on the model before dispatch, including cache hits, fresh scans and cache-bypassing refreshes. Reject a superseded or canceled start/result even for the same path; canceling before dispatch must prevent enumeration. `TestLiveScanRejectsOlderSamePathStart`, `TestLiveScanRejectsStartAfterCancel`, `TestLiveScanRejectsDelayedStartedRequest`, `TestLiveScanVariantsRejectSupersededStart` and `TestCachedScanRejectsSupersededResult` pin these boundaries; `TestLiveScanCurrentRequestCompletes` keeps the valid path working.
- Directory mtime changes invalidate disk-cache entries immediately, including changes within a minute of scanning. Stale data may render only while a fresh scan is scheduled. Cache tests must include recent mutations, not only old timestamps that bypass a grace interval. Locked by `TestLoadCacheRefusesRecentEntryAfterDirectoryChanges` and `TestScanPathConcurrentRescansChangedChildCache`.
- `cmd/analyze/scanner.go` owns disk traversal, Spotlight integration, cancellation, and all scan concurrency budgets. Treat its semaphores as independent resource limits and measure before changing them. Top-level and nested folded directories share `duSem`; keep it separate from traversal, entry-info, and overview budgets. Overview dispatch subtracts already-active publications from its budget, and both direct and history returns restart loading ticks while those publications remain active. Run `go test ./cmd/analyze`.
- The User Library overview row is one serial `du` bounded by `duTimeout` so cross-directory hardlinks count once; a Library that takes longer shows as unavailable and nothing is stored for it, so do not describe the row as faster or timeout-free. `TestGetDirectorySizeFromDuMeasuresUserLibraryInOneTraversal` and `TestUserLibraryOverviewDeduplicatesHardlinks` pin the single traversal.
- The loading frames in `cmd/analyze/constants.go` stay in sync with `lib/core/ui.sh` (`.claude/rules/core.md`); `mo analyze` runs `/usr/bin/du` (`.claude/rules/shell.md`); each Trash move logs to operations.log (`cmd/analyze/oplog_test.go`, `AGENTS.md`).

## Status

- `cmd/status/view.go` owns status rendering only; collection and JSON/NDJSON contracts live elsewhere in `cmd/status/`. Keep narrow-terminal layout and automation output independent. Run `go test ./cmd/status` and `MOLE_TEST_NO_AUTH=1 bats tests/cli.bats` when command routing changes.

## Tests

- `cmd/analyze/analyze_test.go` and `cmd/status/view_test.go` are test hotspots. Add new cases near related behavior; split later only when touching many adjacent cases. Run `go test ./cmd/...`.
- `cmd/*/usage_test.go` own the flag-parser assertions that the core Bats subset job cannot reach (`.claude/rules/tests.md`).
