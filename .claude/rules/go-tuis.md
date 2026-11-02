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
- Analyzers before 1.48.0 wrote one flat `<hash>.cache` per directory into `~/.cache/mole` with no cap (1.88M files and 7.82GB on one Mac; on 2026-10-26 a user's copy froze Mole Mac's Analyze and `ls`). Two entry points sweep them with one predicate, top-level regular `*.cache` files plus `overview_sizes.json`, never the shell's state files or subdirectories: `sweepLegacyAnalyzerCache` on analyzer start and `start_legacy_analyzer_cache_sweep` in `mo clean` (background, skipped in dry runs and for a symlinked root), because users who stop running `mo analyze` never reach the first. Keep the two predicates identical. Locked by the `legacy analyzer cache` cases in `tests/clean_app_caches.bats`.
- Reserve each directory scan identity and cancellation handle on the model before dispatch, including cache hits, fresh scans and cache-bypassing refreshes. Reject a superseded or canceled start/result even for the same path; canceling before dispatch must prevent enumeration. `TestLiveScanRejectsOlderSamePathStart`, `TestLiveScanRejectsStartAfterCancel`, `TestLiveScanRejectsDelayedStartedRequest`, `TestLiveScanVariantsRejectSupersededStart` and `TestCachedScanRejectsSupersededResult` pin these boundaries; `TestLiveScanCurrentRequestCompletes` keeps the valid path working.
- Directory mtime changes invalidate disk-cache entries immediately, including changes within a minute of scanning. Stale data may render only while a fresh scan is scheduled. Cache tests must include recent mutations, not only old timestamps that bypass a grace interval. Locked by `TestLoadCacheRefusesRecentEntryAfterDirectoryChanges` and `TestScanPathConcurrentRescansChangedChildCache`.
- Directory mtime cannot validate file rewrites or descendant growth. Only a complete bounded file-only snapshot with matching live metadata is authoritative; other snapshots remain first paint and refresh through the cache-bypass path, including history returns and memory-cache re-entry. Live disk writes keep zero-size children even while UI/history hide them, and schema 11 invalidates earlier filtered snapshots. Locked by `TestInPlaceFileChangesInvalidateDiskCache`, `TestLiveDiskSnapshotKeepsZeroSizeChildren`, `TestFilteredSchema10CacheIsRefused` and `TestStaleHomeRefreshBypassesLibraryOverviewSnapshot`.
- Keep every direct child browsable after a live scan and an in-memory revisit. Recursive summaries and disk snapshots stay bounded, but shortened listings must refresh before browsing; changing persisted completeness requires cache invalidation. Preserve the selected path and its viewport when rows reorder. `directory_browsing_test.go` covers full listings, warmed summaries and multi-digit row widths.
- Apply live child accounting immediately through a scan-local path index, then sort and rebuild filtered rows on the existing display tick. Invalidate that index after sorting, row removal, cancellation and completion; never coalesce away a completion or cache result. `TestLiveUpdatesSortOnceAtTick`, `TestLiveUpdateTickKeepsFilteredSelection` and `BenchmarkLiveChildUpdates` cover event bursts and selection across the tick.
- `cmd/analyze/scanner.go` owns disk traversal, Spotlight integration, cancellation, and all scan concurrency budgets. Treat its semaphores as independent resource limits and measure before changing them. Top-level and nested folded directories share `duSem`; keep it separate from traversal, entry-info, and overview budgets. Overview dispatch subtracts already-active publications from its budget, and both direct and history returns restart loading ticks while those publications remain active. Run `go test ./cmd/analyze`.
- The User Library overview row is one serial `du` bounded by `duTimeout` so cross-directory hardlinks count once; a Library that takes longer shows as unavailable and nothing is stored for it, so do not describe the row as faster or timeout-free. `TestGetDirectorySizeFromDuMeasuresUserLibraryInOneTraversal` and `TestUserLibraryOverviewDeduplicatesHardlinks` pin the single traversal.
- Mounted-volume overview rows come from the cached kernel mount table (`MNT_NOWAIT`), restricted to local writable, browsable disk mounts directly below `/Volumes`. Do not enumerate network mounts to discover these rows. Their sizes use the existing bounded overview workers; read-only installer images are excluded, but writable disk images may qualify. `TestOverviewEntriesForMounts` covers filtering and pending sizes.
- The loading frames in `cmd/analyze/constants.go` stay in sync with `lib/core/ui.sh` (`.claude/rules/core.md`); `mo analyze` runs `/usr/bin/du` (`.claude/rules/shell.md`); each Trash move logs to operations.log (`cmd/analyze/oplog_test.go`, `AGENTS.md`).

- While Analyze is deleting, the busy view must not accept hidden navigation or confirmation actions; keep only quit and the existing safe refresh path. Locked by `TestDeletingIgnoresHiddenActions` and `TestDeletingCannotDispatchHiddenConfirmation`.
- Protect both known runtime roots and their containing directories before a recursive Trash move. Docker/OrbStack ancestor checks require an existing or unreadable state root, and Darwin user/cache structural containers stay protected without recursively scanning them. Keep empty-container and ordinary-cache positive controls in `delete_test.go`.

## Status

- `cmd/status/view.go` owns status rendering only; collection and JSON/NDJSON contracts live elsewhere in `cmd/status/`. Keep narrow-terminal layout and automation output independent. Unknown battery capacity must not render Healthy from cycle count alone; retain independent cycle counts, their known warnings and a known system condition. `TestBatteryHealthLabel` and `TestBatteryCardUnknownCapacityPreservesCycles` pin the label and card. Run `go test ./cmd/status` and `MOLE_TEST_NO_AUTH=1 bats tests/cli.bats` when command routing changes.

## Tests

- `cmd/analyze/analyze_test.go` and `cmd/status/view_test.go` are test hotspots. Add new cases near related behavior; split later only when touching many adjacent cases. Run `go test ./cmd/...`.
- `cmd/*/usage_test.go` own the flag-parser assertions that the core Bats subset job cannot reach (`.claude/rules/tests.md`).
