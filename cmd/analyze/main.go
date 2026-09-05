//go:build darwin

package main

import (
	"context"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

var (
	jsonMode = flag.Bool("json", false, "output analysis as JSON instead of TUI")
)

// usageText is the help every other Mole subcommand prints by hand. The Go flag
// package would otherwise render "Usage of /usr/local/bin/analyze-go:", naming a
// bundled binary the user never typed, so the text is written out here instead.
const usageText = `Usage: mo analyze [OPTIONS] [PATH]

Explore disk usage. Without PATH, scans a machine-wide overview.

Options:
  --json          Output the analysis as JSON instead of the interactive TUI
  -h, --help      Show this help message

Examples:
  mo analyze                 Machine-wide overview
  mo analyze ~/Library       Scan one directory
  mo analyze --json /Volumes Machine-readable output
`

// parseArgs applies Mole's CLI conventions to the flag package: help goes to
// stdout and exits 0, and an unknown flag goes to stderr and exits 1 the way
// every bash subcommand does, rather than the flag package's stderr-and-2.
// It returns the exit code and whether main should keep running.
func parseArgs(args []string, stdout, stderr io.Writer) (int, bool) {
	flag.CommandLine.Init("mo analyze", flag.ContinueOnError)
	// Parse must not print: this function decides which stream each message
	// belongs on, and the default handler writes usage to stderr for both.
	flag.CommandLine.SetOutput(io.Discard)
	flag.CommandLine.Usage = func() {}

	err := flag.CommandLine.Parse(args)
	switch {
	case errors.Is(err, flag.ErrHelp):
		_, _ = fmt.Fprint(stdout, usageText)
		return 0, false
	case err != nil:
		_, _ = fmt.Fprintln(stderr, err)
		_, _ = fmt.Fprintln(stderr, "Use 'mo analyze --help' for usage information")
		return 1, false
	}
	return 0, true
}

func main() {
	if code, keepGoing := parseArgs(os.Args[1:], os.Stdout, os.Stderr); !keepGoing {
		os.Exit(code)
	}

	abs, isOverview, err := resolveScanTarget(os.Getenv("MO_ANALYZE_PATH"), flag.Args())
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}

	go pruneAnalyzerCache()
	if *jsonMode {
		runJSONMode(abs, isOverview)
	} else {
		runTUIMode(abs, isOverview)
	}
}

// resolveScanTarget decides which scan a given invocation asks for. Kept
// separate from main so the overview-vs-directory routing has a test that fails
// when it flips: an end-to-end overview scan measures the real /Applications
// and /Library, which cost 106s of a single CI test file's 134s.
func resolveScanTarget(envPath string, args []string) (string, bool, error) {
	target := envPath
	if target == "" && len(args) > 0 {
		target = args[0]
	}

	// No explicit target means the machine-wide overview, not the root
	// directory: "/" is only where the overview rows are anchored.
	if target == "" {
		return "/", true, nil
	}

	abs, err := filepath.Abs(target)
	if err != nil {
		return "", false, fmt.Errorf("cannot resolve %q: %v", target, err)
	}
	return abs, false, nil
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
		snapshotRunner:      runLocalSnapshotCommand,
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

	entries = append(entries, systemOverviewRoots()...)

	// Hidden space insights: paths that silently accumulate disk usage.
	entries = append(entries, insightEntries...)

	return entries
}

func systemOverviewRoots() []dirEntry {
	return []dirEntry{
		{Name: "Applications", Path: "/Applications", IsDir: true, Size: -1},
		{Name: "System Library", Path: "/Library", IsDir: true, Size: -1},
	}
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
