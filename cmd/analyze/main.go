//go:build darwin

package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

var (
	jsonMode    = flag.Bool("json", false, "output analysis as JSON instead of TUI")
	jsonLimit   = flag.Int("limit", 0, "limit JSON output to the largest N top-level entries (0 = all)")
	jsonCompact = flag.Bool("compact", false, "emit compact JSON without indentation")
)

func main() {
	flag.Parse()

	limitSet := false
	flag.Visit(func(f *flag.Flag) {
		if f.Name == "limit" {
			limitSet = true
		}
	})

	if *jsonLimit < 0 {
		fmt.Fprintln(os.Stderr, "analyze: --limit must be 0 or greater")
		os.Exit(2)
	}
	if limitSet && !*jsonMode {
		fmt.Fprintln(os.Stderr, "analyze: --limit requires --json")
		os.Exit(2)
	}
	if *jsonCompact && !*jsonMode {
		fmt.Fprintln(os.Stderr, "analyze: --compact requires --json")
		os.Exit(2)
	}

	target := os.Getenv("MO_ANALYZE_PATH")
	if target == "" && len(flag.Args()) > 0 {
		target = flag.Args()[0]
	}

	var abs string
	var isOverview bool

	if target == "" {
		isOverview = true
		abs = "/"
	} else {
		var err error
		abs, err = filepath.Abs(target)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cannot resolve %q: %v\n", target, err)
			os.Exit(1)
		}
		isOverview = false
	}

	go pruneAnalyzerCache()
	if *jsonMode {
		runJSONMode(abs, isOverview, *jsonLimit, *jsonCompact)
	} else {
		runTUIMode(abs, isOverview)
	}
}

func runTUIMode(path string, isOverview bool) {
	// Warm overview cache only when the user opens a specific directory.
	// Overview mode already schedules the same measurements for the foreground UI;
	// running the prefetcher there doubles the du/io workload on cold start.
	if !isOverview {
		prefetchCtx, prefetchCancel := context.WithTimeout(context.Background(), 30*time.Second)
		defer prefetchCancel()
		go prefetchOverviewCache(prefetchCtx)
	}

	p := tea.NewProgram(newModel(path, isOverview), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "analyzer error: %v\n", err)
		os.Exit(1)
	}
}

func newModel(path string, isOverview bool) model {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")
	var diskFreeBytes int64
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err == nil {
		diskFreeBytes = int64(stat.Bavail) * int64(stat.Bsize)
	}

	m := model{
		path:                path,
		selected:            0,
		status:              "Preparing scan...",
		diskFree:            diskFreeBytes,
		scanning:            !isOverview,
		filesScanned:        &filesScanned,
		dirsScanned:         &dirsScanned,
		bytesScanned:        &bytesScanned,
		currentPath:         currentPath,
		showLargeFiles:      false,
		isOverview:          isOverview,
		cache:               make(map[string]historyEntry),
		overviewSizeCache:   make(map[string]int64),
		overviewScanningSet: make(map[string]bool),
		multiSelected:       make(map[string]bool),
		largeMultiSelected:  make(map[string]bool),
		liveSortMode:        liveScanSortModeFromEnv(),
	}

	if isOverview {
		m.scanning = false
		m.hydrateOverviewEntries()
		m.selected = 0
		m.offset = 0
		if nextPendingOverviewIndex(m.entries) >= 0 {
			m.overviewScanning = true
			m.status = "Checking system folders..."
		} else {
			m.status = "Ready"
		}
	}

	// Try to peek last total files for progress bar, even if cache is stale
	if !isOverview {
		if total, err := peekCacheTotalFiles(path); err == nil && total > 0 {
			m.lastTotalFiles = total
		}
	}

	return m
}

func createOverviewEntries() []dirEntry {
	return createOverviewEntriesWithInsights(createInsightEntries())
}

func createOverviewEntriesWithInsights(insightEntries []dirEntry) []dirEntry {
	home := os.Getenv("HOME")
	entries := []dirEntry{}

	// Separate Home and ~/Library to avoid double counting.
	if home != "" {
		entries = append(entries, dirEntry{Name: "Home", Path: home, IsDir: true, Size: -1})

		userLibrary := filepath.Join(home, "Library")
		if _, err := os.Stat(userLibrary); err == nil {
			// Renamed from "App Library" to "User Library" so it parallels
			// "System Library" (`/Library`) and is not confused with
			// `/Applications`. Path unchanged.
			entries = append(entries, dirEntry{Name: "User Library", Path: userLibrary, IsDir: true, Size: -1})
		}
	}

	entries = append(entries,
		dirEntry{Name: "Applications", Path: "/Applications", IsDir: true, Size: -1},
		dirEntry{Name: "System Library", Path: "/Library", IsDir: true, Size: -1},
	)

	// Hidden space insights: paths that silently accumulate disk usage.
	entries = append(entries, insightEntries...)

	return entries
}

func sumKnownEntrySizes(entries []dirEntry) int64 {
	var total int64
	for _, entry := range entries {
		if entry.Size > 0 {
			total += entry.Size
		}
	}
	return total
}

func nextPendingOverviewIndex(entries []dirEntry) int {
	for i, entry := range entries {
		if entry.Size < 0 {
			return i
		}
	}
	return -1
}

func hasPendingOverviewEntries(entries []dirEntry) bool {
	for _, entry := range entries {
		if entry.Size < 0 {
			return true
		}
	}
	return false
}

func safeOpen(path string, reveal bool) error {
	if err := validatePath(path); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), openCommandTimeout)
	defer cancel()
	args := []string{path}
	if reveal {
		args = []string{"-R", path}
	}
	return exec.CommandContext(ctx, "open", args...).Run()
}

// safePreview opens the file with the default macOS application.
func safePreview(path string) error {
	if err := validatePath(path); err != nil {
		return err
	}
	ctx, cancel := context.WithTimeout(context.Background(), openCommandTimeout)
	defer cancel()
	return exec.CommandContext(ctx, "open", path).Run()
}
