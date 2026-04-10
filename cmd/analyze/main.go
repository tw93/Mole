//go:build darwin

package main

import (
	"context"
	"flag"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"slices"
	"sort"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

var (
	jsonMode = flag.Bool("json", false, "output analysis as JSON instead of TUI")
)

type dirEntry struct {
	Name       string
	Path       string
	Size       int64
	IsDir      bool
	LastAccess time.Time
}

type fileEntry struct {
	Name string
	Path string
	Size int64
}

type scanResult struct {
	Entries    []dirEntry
	LargeFiles []fileEntry
	TotalSize  int64
	TotalFiles int64
}

type cacheEntry struct {
	Entries      []dirEntry
	LargeFiles   []fileEntry
	TotalSize    int64
	TotalFiles   int64
	ModTime      time.Time
	ScanTime     time.Time
	NeedsRefresh bool
}

type historyEntry struct {
	Path          string
	Entries       []dirEntry
	LargeFiles    []fileEntry
	TotalSize     int64
	TotalFiles    int64
	Selected      int
	EntryOffset   int
	LargeSelected int
	LargeOffset   int
	Dirty         bool
	NeedsRefresh  bool
	IsOverview    bool
}

type scanResultMsg struct {
	path   string
	result scanResult
	err    error
	stale  bool
}

type overviewSizeMsg struct {
	Path  string
	Index int
	Size  int64
	Err   error
}

type tickMsg time.Time

type deleteProgressMsg struct {
	done  bool
	err   error
	count int64
	path  string
}

type model struct {
	path                 string
	history              []historyEntry
	entries              []dirEntry
	largeFiles           []fileEntry
	selected             int
	offset               int
	status               string
	totalSize            int64
	scanning             bool
	spinner              int
	filesScanned         *int64
	dirsScanned          *int64
	bytesScanned         *int64
	currentPath          *atomic.Value
	showLargeFiles       bool
	isOverview           bool
	deleteConfirm        bool
	deleteTarget         *dirEntry
	deleting             bool
	deleteCount          *int64
	cache                map[string]historyEntry
	largeSelected        int
	largeOffset          int
	overviewSizeCache    map[string]int64
	overviewFilesScanned *int64
	overviewDirsScanned  *int64
	overviewBytesScanned *int64
	overviewCurrentPath  *string
	overviewScanning     bool
	overviewScanningSet  map[string]bool // Track which paths are currently being scanned
	width                int             // Terminal width
	height               int             // Terminal height
	multiSelected        map[string]bool // Track multi-selected items by path (safer than index)
	largeMultiSelected   map[string]bool // Track multi-selected large files by path (safer than index)
	totalFiles           int64           // Total files found in current/last scan
	lastTotalFiles       int64           // Total files from previous scan (for progress bar)
	diskFree             int64           // Free disk space for the analyzed volume
	viewNeedsRefresh     bool
}

func (m model) inOverviewMode() bool {
	return m.isOverview && m.path == "/"
}

func main() {
	flag.Parse()

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

	if *jsonMode {
		runJSONMode(abs, isOverview)
	} else {
		runTUIMode(abs, isOverview)
	}
}

func runTUIMode(path string, isOverview bool) {
	// Warm overview cache in background.
	prefetchCtx, prefetchCancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer prefetchCancel()
	go prefetchOverviewCache(prefetchCtx)

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
	var overviewFilesScanned, overviewDirsScanned, overviewBytesScanned int64
	overviewCurrentPath := ""
	var diskFreeBytes int64
	var stat syscall.Statfs_t
	if err := syscall.Statfs(path, &stat); err == nil {
		diskFreeBytes = int64(stat.Bavail) * int64(stat.Bsize)
	}

	m := model{
		path:                 path,
		selected:             0,
		status:               "Preparing scan...",
		diskFree:             diskFreeBytes,
		scanning:             !isOverview,
		filesScanned:         &filesScanned,
		dirsScanned:          &dirsScanned,
		bytesScanned:         &bytesScanned,
		currentPath:          currentPath,
		showLargeFiles:       false,
		isOverview:           isOverview,
		cache:                make(map[string]historyEntry),
		overviewFilesScanned: &overviewFilesScanned,
		overviewDirsScanned:  &overviewDirsScanned,
		overviewBytesScanned: &overviewBytesScanned,
		overviewCurrentPath:  &overviewCurrentPath,
		overviewSizeCache:    make(map[string]int64),
		overviewScanningSet:  make(map[string]bool),
		multiSelected:        make(map[string]bool),
		largeMultiSelected:   make(map[string]bool),
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
	home := os.Getenv("HOME")
	entries := []dirEntry{}

	// Separate Home and ~/Library to avoid double counting.
	if home != "" {
		entries = append(entries, dirEntry{Name: "Home", Path: home, IsDir: true, Size: -1})

		userLibrary := filepath.Join(home, "Library")
		if _, err := os.Stat(userLibrary); err == nil {
			entries = append(entries, dirEntry{Name: "App Library", Path: userLibrary, IsDir: true, Size: -1})
		}
	}

	entries = append(entries,
		dirEntry{Name: "Applications", Path: "/Applications", IsDir: true, Size: -1},
		dirEntry{Name: "System Library", Path: "/Library", IsDir: true, Size: -1},
	)

	// Hidden space insights — paths that silently accumulate disk usage.
	entries = append(entries, createInsightEntries()...)

	return entries
}

func (m *model) hydrateOverviewEntries() {
	m.entries = createOverviewEntries()
	if m.overviewSizeCache == nil {
		m.overviewSizeCache = make(map[string]int64)
	}
	for i := range m.entries {
		if size, ok := m.overviewSizeCache[m.entries[i].Path]; ok {
			m.entries[i].Size = size
			continue
		}
		if size, err := loadOverviewCachedSize(m.entries[i].Path); err == nil {
			m.entries[i].Size = size
			m.overviewSizeCache[m.entries[i].Path] = size
		}
	}
	m.totalSize = sumKnownEntrySizes(m.entries)
}

func (m *model) sortOverviewEntriesBySize() {
	// Stable sort by size.
	sort.SliceStable(m.entries, func(i, j int) bool {
		return m.entries[i].Size > m.entries[j].Size
	})
}

func (m *model) scheduleOverviewScans() tea.Cmd {
	if !m.inOverviewMode() {
		return nil
	}

	var pendingIndices []int
	for i, entry := range m.entries {
		if entry.Size < 0 && !m.overviewScanningSet[entry.Path] {
			pendingIndices = append(pendingIndices, i)
			if len(pendingIndices) >= maxConcurrentOverview {
				break
			}
		}
	}

	if len(pendingIndices) == 0 {
		m.overviewScanning = false
		if !hasPendingOverviewEntries(m.entries) {
			m.sortOverviewEntriesBySize()
			m.status = "Ready"
		}
		return nil
	}

	var cmds []tea.Cmd
	for _, idx := range pendingIndices {
		entry := m.entries[idx]
		m.overviewScanningSet[entry.Path] = true
		cmd := scanOverviewPathCmd(entry.Path, idx)
		cmds = append(cmds, cmd)
	}

	m.overviewScanning = true
	remaining := 0
	for _, e := range m.entries {
		if e.Size < 0 {
			remaining++
		}
	}
	if len(pendingIndices) > 0 {
		firstEntry := m.entries[pendingIndices[0]]
		if len(pendingIndices) == 1 {
			m.status = fmt.Sprintf("Scanning %s..., %d left", firstEntry.Name, remaining)
		} else {
			m.status = fmt.Sprintf("Scanning %d directories..., %d left", len(pendingIndices), remaining)
		}
	}

	cmds = append(cmds, tickCmd())
	return tea.Batch(cmds...)
}

func (m *model) getScanProgress() (files, dirs, bytes int64) {
	if m.filesScanned != nil {
		files = atomic.LoadInt64(m.filesScanned)
	}
	if m.dirsScanned != nil {
		dirs = atomic.LoadInt64(m.dirsScanned)
	}
	if m.bytesScanned != nil {
		bytes = atomic.LoadInt64(m.bytesScanned)
	}
	return
}

func (m model) Init() tea.Cmd {
	if m.inOverviewMode() {
		return m.scheduleOverviewScans()
	}
	return tea.Batch(m.scanCmd(m.path), tickCmd())
}

func (m model) scanCmd(path string) tea.Cmd {
	return func() tea.Msg {
		if cached, err := loadCacheFromDisk(path); err == nil {
			result := scanResult{
				Entries:    cached.Entries,
				LargeFiles: cached.LargeFiles,
				TotalSize:  cached.TotalSize,
				TotalFiles: cached.TotalFiles,
			}
			if cached.NeedsRefresh {
				return scanResultMsg{path: path, result: result, err: nil, stale: true}
			}
			return scanResultMsg{path: path, result: result, err: nil}
		}

		if stale, err := loadStaleCacheFromDisk(path); err == nil {
			result := scanResult{
				Entries:    stale.Entries,
				LargeFiles: stale.LargeFiles,
				TotalSize:  stale.TotalSize,
				TotalFiles: stale.TotalFiles,
			}
			return scanResultMsg{path: path, result: result, err: nil, stale: true}
		}

		v, err, _ := scanGroup.Do(path, func() (any, error) {
			return scanPathConcurrent(path, m.filesScanned, m.dirsScanned, m.bytesScanned, m.currentPath)
		})

		if err != nil {
			return scanResultMsg{path: path, err: err}
		}

		result := v.(scanResult)

		go func(p string, r scanResult) {
			if err := saveCacheToDisk(p, r); err != nil {
				_ = err // Cache save failure is not critical
			}
		}(path, result)

		return scanResultMsg{path: path, result: result, err: nil}
	}
}

func (m model) scanFreshCmd(path string) tea.Cmd {
	return func() tea.Msg {
		v, err, _ := scanGroup.Do(path, func() (any, error) {
			return scanPathConcurrent(path, m.filesScanned, m.dirsScanned, m.bytesScanned, m.currentPath)
		})

		if err != nil {
			return scanResultMsg{path: path, err: err}
		}

		result := v.(scanResult)
		go func(p string, r scanResult) {
			if err := saveCacheToDisk(p, r); err != nil {
				_ = err
			}
		}(path, result)

		return scanResultMsg{path: path, result: result}
	}
}

func tickCmd() tea.Cmd {
	return tea.Tick(time.Millisecond*100, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		return m.updateKey(msg)
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil
	case deleteProgressMsg:
		if msg.done {
			m.deleting = false
			m.multiSelected = make(map[string]bool)
			m.largeMultiSelected = make(map[string]bool)
			if msg.err != nil {
				m.status = fmt.Sprintf("Failed to delete: %v", msg.err)
			} else {
				if msg.path != "" {
					m.removePathFromView(msg.path)
					invalidateCache(msg.path)
				}
				invalidateCache(m.path)
				m.status = fmt.Sprintf("Deleted %d items", msg.count)
				for i := range m.history {
					m.history[i].Dirty = true
				}
				for path := range m.cache {
					entry := m.cache[path]
					entry.Dirty = true
					m.cache[path] = entry
				}
				m.scanning = true
				atomic.StoreInt64(m.filesScanned, 0)
				atomic.StoreInt64(m.dirsScanned, 0)
				atomic.StoreInt64(m.bytesScanned, 0)
				if m.currentPath != nil {
					m.currentPath.Store("")
				}
				return m, tea.Batch(m.scanCmd(m.path), tickCmd())
			}
		}
		return m, nil
	case scanResultMsg:
		if msg.path != "" && msg.path != m.path {
			if msg.err == nil {
				filteredEntries := filterNonEmptyEntries(msg.result.Entries)
				result := msg.result
				result.Entries = filteredEntries
				m.cache[msg.path] = historyEntryFromScanResult(msg.path, result, m.cache[msg.path], msg.stale)
			}
			return m, nil
		}
		m.scanning = false
		if msg.err != nil {
			m.status = fmt.Sprintf("Scan failed: %v", msg.err)
			return m, nil
		}
		filteredEntries := filterNonEmptyEntries(msg.result.Entries)
		result := msg.result
		result.Entries = filteredEntries
		m.entries = filteredEntries
		m.largeFiles = msg.result.LargeFiles
		m.totalSize = msg.result.TotalSize
		m.totalFiles = msg.result.TotalFiles
		m.viewNeedsRefresh = msg.stale
		m.clampEntrySelection()
		m.clampLargeSelection()
		m.cache[m.path] = historyEntryFromScanResult(m.path, result, m.cache[m.path], msg.stale)
		if m.totalSize > 0 {
			if m.overviewSizeCache == nil {
				m.overviewSizeCache = make(map[string]int64)
			}
			m.overviewSizeCache[m.path] = m.totalSize
			go func(path string, size int64) {
				_ = storeOverviewSize(path, size)
			}(m.path, m.totalSize)
		}

		if msg.stale {
			m.status = fmt.Sprintf("Loaded cached data for %s, refreshing...", displayPath(m.path))
			m.scanning = true
			if m.totalFiles > 0 {
				m.lastTotalFiles = m.totalFiles
			}
			atomic.StoreInt64(m.filesScanned, 0)
			atomic.StoreInt64(m.dirsScanned, 0)
			atomic.StoreInt64(m.bytesScanned, 0)
			if m.currentPath != nil {
				m.currentPath.Store("")
			}
			return m, tea.Batch(m.scanFreshCmd(m.path), tickCmd())
		}

		m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		return m, nil
	case overviewSizeMsg:
		delete(m.overviewScanningSet, msg.Path)

		if msg.Err == nil {
			if m.overviewSizeCache == nil {
				m.overviewSizeCache = make(map[string]int64)
			}
			m.overviewSizeCache[msg.Path] = msg.Size
		}

		if m.inOverviewMode() {
			for i := range m.entries {
				if m.entries[i].Path == msg.Path {
					if msg.Err == nil {
						m.entries[i].Size = msg.Size
					} else {
						m.entries[i].Size = 0
					}
					break
				}
			}
			m.totalSize = sumKnownEntrySizes(m.entries)

			if msg.Err != nil {
				m.status = fmt.Sprintf("Unable to measure %s: %v", displayPath(msg.Path), msg.Err)
			}

			cmd := m.scheduleOverviewScans()
			return m, cmd
		}
		return m, nil
	case tickMsg:
		hasPending := false
		if m.inOverviewMode() {
			for _, entry := range m.entries {
				if entry.Size < 0 {
					hasPending = true
					break
				}
			}
		}
		if m.scanning || m.deleting || (m.inOverviewMode() && (m.overviewScanning || hasPending)) {
			m.spinner = (m.spinner + 1) % len(spinnerFrames)
			if m.deleting && m.deleteCount != nil {
				count := atomic.LoadInt64(m.deleteCount)
				if count > 0 {
					m.status = fmt.Sprintf("Moving to Trash... %s items", formatNumber(count))
				}
			}
			return m, tickCmd()
		}
		return m, nil
	default:
		return m, nil
	}
}

func (m model) updateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Delete confirm flow.
	if m.deleteConfirm {
		switch msg.String() {
		case "enter":
			m.deleteConfirm = false
			m.deleting = true
			var deleteCount int64
			m.deleteCount = &deleteCount

			// Collect paths (safer than indices).
			var pathsToDelete []string
			if m.showLargeFiles {
				if len(m.largeMultiSelected) > 0 {
					for path := range m.largeMultiSelected {
						pathsToDelete = append(pathsToDelete, path)
					}
				} else if m.deleteTarget != nil {
					pathsToDelete = append(pathsToDelete, m.deleteTarget.Path)
				}
			} else {
				if len(m.multiSelected) > 0 {
					for path := range m.multiSelected {
						pathsToDelete = append(pathsToDelete, path)
					}
				} else if m.deleteTarget != nil {
					pathsToDelete = append(pathsToDelete, m.deleteTarget.Path)
				}
			}

			m.deleteTarget = nil
			if len(pathsToDelete) == 0 {
				m.deleting = false
				m.status = "Nothing to delete"
				return m, nil
			}

			if len(pathsToDelete) == 1 {
				targetPath := pathsToDelete[0]
				m.status = fmt.Sprintf("Deleting %s...", filepath.Base(targetPath))
				return m, tea.Batch(deletePathCmd(targetPath, m.deleteCount), tickCmd())
			}

			m.status = fmt.Sprintf("Deleting %d items...", len(pathsToDelete))
			return m, tea.Batch(deleteMultiplePathsCmd(pathsToDelete, m.deleteCount), tickCmd())
		case "esc", "q":
			m.status = "Cancelled"
			m.deleteConfirm = false
			m.deleteTarget = nil
			return m, nil
		case "ctrl+c":
			return m, tea.Quit
		default:
			return m, nil
		}
	}

	switch msg.String() {
	case "q", "Q", "ctrl+c":
		return m, tea.Quit
	case "esc":
		if m.showLargeFiles {
			m.showLargeFiles = false
			return m, nil
		}
		return m.goBack()
	case "up", "k", "K":
		if m.showLargeFiles {
			if m.largeSelected > 0 {
				m.largeSelected--
				if m.largeSelected < m.largeOffset {
					m.largeOffset = m.largeSelected
				}
			}
		} else if len(m.entries) > 0 && m.selected > 0 {
			next := m.selected - 1
			for next > 0 && m.entries[next].Size == 0 {
				next--
			}
			m.selected = next
			if m.selected < m.offset {
				m.offset = m.selected
			}
		}
	case "down", "j", "J":
		if m.showLargeFiles {
			if m.largeSelected < len(m.largeFiles)-1 {
				m.largeSelected++
				viewport := calculateViewport(m.height, true)
				if m.largeSelected >= m.largeOffset+viewport {
					m.largeOffset = m.largeSelected - viewport + 1
				}
			}
		} else if len(m.entries) > 0 && m.selected < len(m.entries)-1 {
			next := m.selected + 1
			for next < len(m.entries)-1 && m.entries[next].Size == 0 {
				next++
			}
			m.selected = next
			viewport := calculateViewport(m.height, false)
			if m.selected >= m.offset+viewport {
				m.offset = m.selected - viewport + 1
			}
		}
	case "enter", "right", "l", "L":
		if m.showLargeFiles {
			return m, nil
		}
		return m.enterSelectedDir()
	case "b", "left", "h", "B", "H":
		if m.showLargeFiles {
			m.showLargeFiles = false
			return m, nil
		}
		return m.goBack()
	case "r", "R":
		m.multiSelected = make(map[string]bool)
		m.largeMultiSelected = make(map[string]bool)

		if m.inOverviewMode() {
			// Explicitly invalidate cache for all overview entries to force re-scan
			for _, entry := range m.entries {
				invalidateCache(entry.Path)
			}

			m.overviewSizeCache = make(map[string]int64)
			m.overviewScanningSet = make(map[string]bool)
			m.hydrateOverviewEntries() // Reset sizes to pending

			for i := range m.entries {
				m.entries[i].Size = -1
			}
			m.totalSize = 0

			m.status = "Refreshing..."
			m.overviewScanning = true
			return m, tea.Batch(m.scheduleOverviewScans(), tickCmd())
		}

		invalidateCache(m.path)
		m.status = "Refreshing..."
		m.scanning = true
		if m.totalFiles > 0 {
			m.lastTotalFiles = m.totalFiles
		}
		atomic.StoreInt64(m.filesScanned, 0)
		atomic.StoreInt64(m.dirsScanned, 0)
		atomic.StoreInt64(m.bytesScanned, 0)
		if m.currentPath != nil {
			m.currentPath.Store("")
		}
		return m, tea.Batch(m.scanCmd(m.path), tickCmd())
	case "t", "T":
		if !m.inOverviewMode() {
			m.showLargeFiles = !m.showLargeFiles
			if m.showLargeFiles {
				m.largeSelected = 0
				m.largeOffset = 0
				m.largeMultiSelected = make(map[string]bool)
			} else {
				m.multiSelected = make(map[string]bool)
			}
			m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		}
	case "o", "O":
		// Open selected entries (multi-select aware).
		const maxBatchOpen = 20
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				if len(m.largeMultiSelected) > 0 {
					count := len(m.largeMultiSelected)
					if count > maxBatchOpen {
						m.status = fmt.Sprintf("Too many items to open, max %d, selected %d", maxBatchOpen, count)
						return m, nil
					}
					for path := range m.largeMultiSelected {
						go func(p string) {
							_ = safeOpen(p, false)
						}(path)
					}
					m.status = fmt.Sprintf("Opening %d items...", count)
				} else {
					selected := m.largeFiles[m.largeSelected]
					go func(path string) {
						_ = safeOpen(path, false)
					}(selected.Path)
					m.status = fmt.Sprintf("Opening %s...", selected.Name)
				}
			}
		} else if len(m.entries) > 0 {
			if len(m.multiSelected) > 0 {
				count := len(m.multiSelected)
				if count > maxBatchOpen {
					m.status = fmt.Sprintf("Too many items to open, max %d, selected %d", maxBatchOpen, count)
					return m, nil
				}
				for path := range m.multiSelected {
					go func(p string) {
						_ = safeOpen(p, false)
					}(path)
				}
				m.status = fmt.Sprintf("Opening %d items...", count)
			} else {
				selected := m.entries[m.selected]
				go func(path string) {
					_ = safeOpen(path, false)
				}(selected.Path)
				m.status = fmt.Sprintf("Opening %s...", selected.Name)
			}
		}
	case "f", "F":
		// Reveal in Finder (multi-select aware).
		const maxBatchReveal = 20
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				if len(m.largeMultiSelected) > 0 {
					count := len(m.largeMultiSelected)
					if count > maxBatchReveal {
						m.status = fmt.Sprintf("Too many items to reveal, max %d, selected %d", maxBatchReveal, count)
						return m, nil
					}
					for path := range m.largeMultiSelected {
						go func(p string) {
							_ = safeOpen(p, true)
						}(path)
					}
					m.status = fmt.Sprintf("Showing %d items in Finder...", count)
				} else {
					selected := m.largeFiles[m.largeSelected]
					go func(path string) {
						_ = safeOpen(path, true)
					}(selected.Path)
					m.status = fmt.Sprintf("Showing %s in Finder...", selected.Name)
				}
			}
		} else if len(m.entries) > 0 {
			if len(m.multiSelected) > 0 {
				count := len(m.multiSelected)
				if count > maxBatchReveal {
					m.status = fmt.Sprintf("Too many items to reveal, max %d, selected %d", maxBatchReveal, count)
					return m, nil
				}
				for path := range m.multiSelected {
					go func(p string) {
						_ = safeOpen(p, true)
					}(path)
				}
				m.status = fmt.Sprintf("Showing %d items in Finder...", count)
			} else {
				selected := m.entries[m.selected]
				go func(path string) {
					_ = safeOpen(path, true)
				}(selected.Path)
				m.status = fmt.Sprintf("Showing %s in Finder...", selected.Name)
			}
		}
	case "p", "P":
		// Quick Look preview (single file only, no multi-select).
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				selected := m.largeFiles[m.largeSelected]
				go func(path string) {
					_ = safePreview(path)
				}(selected.Path)
				m.status = fmt.Sprintf("Previewing %s...", selected.Name)
			}
		} else if len(m.entries) > 0 {
			selected := m.entries[m.selected]
			if !selected.IsDir {
				go func(path string) {
					_ = safePreview(path)
				}(selected.Path)
				m.status = fmt.Sprintf("Previewing %s...", selected.Name)
			}
		}
	case " ":
		// Toggle multi-select (paths as keys).
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 && m.largeSelected < len(m.largeFiles) {
				if m.largeMultiSelected == nil {
					m.largeMultiSelected = make(map[string]bool)
				}
				selectedPath := m.largeFiles[m.largeSelected].Path
				if m.largeMultiSelected[selectedPath] {
					delete(m.largeMultiSelected, selectedPath)
				} else {
					m.largeMultiSelected[selectedPath] = true
				}
				count := len(m.largeMultiSelected)
				if count > 0 {
					var totalSize int64
					for path := range m.largeMultiSelected {
						for _, file := range m.largeFiles {
							if file.Path == path {
								totalSize += file.Size
								break
							}
						}
					}
					m.status = fmt.Sprintf("%d selected, %s", count, humanizeBytes(totalSize))
				} else {
					m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
				}
			}
		} else if len(m.entries) > 0 && !m.inOverviewMode() && m.selected < len(m.entries) {
			if m.multiSelected == nil {
				m.multiSelected = make(map[string]bool)
			}
			selectedPath := m.entries[m.selected].Path
			if m.multiSelected[selectedPath] {
				delete(m.multiSelected, selectedPath)
			} else {
				m.multiSelected[selectedPath] = true
			}
			count := len(m.multiSelected)
			if count > 0 {
				var totalSize int64
				for path := range m.multiSelected {
					for _, entry := range m.entries {
						if entry.Path == path {
							totalSize += entry.Size
							break
						}
					}
				}
				m.status = fmt.Sprintf("%d selected, %s", count, humanizeBytes(totalSize))
			} else {
				m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
			}
		}
	case "delete", "backspace":
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				if len(m.largeMultiSelected) > 0 {
					m.deleteConfirm = true
					for path := range m.largeMultiSelected {
						for _, file := range m.largeFiles {
							if file.Path == path {
								m.deleteTarget = &dirEntry{
									Name:  file.Name,
									Path:  file.Path,
									Size:  file.Size,
									IsDir: false,
								}
								break
							}
						}
						break // Only need first one for display
					}
				} else if m.largeSelected < len(m.largeFiles) {
					selected := m.largeFiles[m.largeSelected]
					m.deleteConfirm = true
					m.deleteTarget = &dirEntry{
						Name:  selected.Name,
						Path:  selected.Path,
						Size:  selected.Size,
						IsDir: false,
					}
				}
			}
		} else if len(m.entries) > 0 && !m.inOverviewMode() {
			if len(m.multiSelected) > 0 {
				m.deleteConfirm = true
				for path := range m.multiSelected {
					// Resolve entry by path.
					for i := range m.entries {
						if m.entries[i].Path == path {
							m.deleteTarget = &m.entries[i]
							break
						}
					}
					break // Only need first one for display
				}
			} else if m.selected < len(m.entries) {
				selected := m.entries[m.selected]
				m.deleteConfirm = true
				m.deleteTarget = &selected
			}
		}
	}
	return m, nil
}

func (m model) goBack() (tea.Model, tea.Cmd) {
	if len(m.history) == 0 {
		if !m.inOverviewMode() {
			return m, m.switchToOverviewMode()
		}
		return m, tea.Quit
	}

	last := m.history[len(m.history)-1]
	m.history = m.history[:len(m.history)-1]
	m.path = last.Path
	m.selected = last.Selected
	m.offset = last.EntryOffset
	m.largeSelected = last.LargeSelected
	m.largeOffset = last.LargeOffset
	m.isOverview = last.IsOverview
	if last.Dirty {
		// On overview return, refresh cached entries.
		if last.IsOverview {
			m.hydrateOverviewEntries()
			m.totalSize = sumKnownEntrySizes(m.entries)
			m.status = "Ready"
			m.scanning = false
			if nextPendingOverviewIndex(m.entries) >= 0 {
				m.overviewScanning = true
				return m, m.scheduleOverviewScans()
			}
			return m, nil
		}
		m.status = "Scanning..."
		m.scanning = true
		return m, tea.Batch(m.scanCmd(m.path), tickCmd())
	}
	m.entries = last.Entries
	m.largeFiles = last.LargeFiles
	m.totalSize = last.TotalSize
	m.totalFiles = last.TotalFiles
	m.viewNeedsRefresh = last.NeedsRefresh
	m.clampEntrySelection()
	m.clampLargeSelection()
	if len(m.entries) == 0 {
		m.selected = 0
	} else if m.selected >= len(m.entries) {
		m.selected = len(m.entries) - 1
	}
	if m.selected < 0 {
		m.selected = 0
	}
	if last.NeedsRefresh {
		m.status = fmt.Sprintf("Loaded cached data for %s, refreshing...", displayPath(m.path))
		m.scanning = true
		if m.totalFiles > 0 {
			m.lastTotalFiles = m.totalFiles
		}
		atomic.StoreInt64(m.filesScanned, 0)
		atomic.StoreInt64(m.dirsScanned, 0)
		atomic.StoreInt64(m.bytesScanned, 0)
		if m.currentPath != nil {
			m.currentPath.Store("")
		}
		return m, tea.Batch(m.scanFreshCmd(m.path), tickCmd())
	}
	m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
	m.scanning = false
	return m, nil
}

func (m *model) switchToOverviewMode() tea.Cmd {
	m.isOverview = true
	m.path = "/"
	m.scanning = false
	m.showLargeFiles = false
	m.largeFiles = nil
	m.largeSelected = 0
	m.largeOffset = 0
	m.deleteConfirm = false
	m.deleteTarget = nil
	m.selected = 0
	m.offset = 0
	m.hydrateOverviewEntries()
	cmd := m.scheduleOverviewScans()
	if cmd == nil {
		m.status = "Ready"
		return nil
	}
	return tea.Batch(cmd, tickCmd())
}

func (m model) enterSelectedDir() (tea.Model, tea.Cmd) {
	if len(m.entries) == 0 {
		return m, nil
	}
	selected := m.entries[m.selected]
	if selected.IsDir {
		if len(m.history) == 0 || m.history[len(m.history)-1].Path != m.path {
			m.history = append(m.history, snapshotFromModel(m))
		}
		m.path = selected.Path
		m.selected = 0
		m.offset = 0
		m.status = "Scanning..."
		m.scanning = true
		m.isOverview = false
		m.viewNeedsRefresh = false
		m.multiSelected = make(map[string]bool)
		m.largeMultiSelected = make(map[string]bool)

		atomic.StoreInt64(m.filesScanned, 0)
		atomic.StoreInt64(m.dirsScanned, 0)
		atomic.StoreInt64(m.bytesScanned, 0)
		if m.currentPath != nil {
			m.currentPath.Store("")
		}

		if cached, ok := m.cache[m.path]; ok && !cached.Dirty {
			m.entries = slices.Clone(cached.Entries)
			m.largeFiles = slices.Clone(cached.LargeFiles)
			m.totalSize = cached.TotalSize
			m.totalFiles = cached.TotalFiles
			m.viewNeedsRefresh = cached.NeedsRefresh
			m.selected = cached.Selected
			m.offset = cached.EntryOffset
			m.largeSelected = cached.LargeSelected
			m.largeOffset = cached.LargeOffset
			m.clampEntrySelection()
			m.clampLargeSelection()
			if cached.NeedsRefresh {
				m.status = fmt.Sprintf("Loaded cached data for %s, refreshing...", displayPath(m.path))
				m.scanning = true
				if m.totalFiles > 0 {
					m.lastTotalFiles = m.totalFiles
				}
				return m, tea.Batch(m.scanFreshCmd(m.path), tickCmd())
			}
			m.status = fmt.Sprintf("Cached view for %s", displayPath(m.path))
			m.scanning = false
			return m, nil
		}
		m.lastTotalFiles = 0
		if total, err := peekCacheTotalFiles(m.path); err == nil && total > 0 {
			m.lastTotalFiles = total
		}
		return m, tea.Batch(m.scanCmd(m.path), tickCmd())
	}
	m.status = fmt.Sprintf("File: %s, %s", selected.Name, humanizeBytes(selected.Size))
	return m, nil
}

func (m *model) clampEntrySelection() {
	if len(m.entries) == 0 {
		m.selected = 0
		m.offset = 0
		return
	}
	if m.selected >= len(m.entries) {
		m.selected = len(m.entries) - 1
	}
	if m.selected < 0 {
		m.selected = 0
	}
	viewport := calculateViewport(m.height, false)
	maxOffset := max(len(m.entries)-viewport, 0)
	if m.offset > maxOffset {
		m.offset = maxOffset
	}
	if m.selected < m.offset {
		m.offset = m.selected
	}
	if m.selected >= m.offset+viewport {
		m.offset = m.selected - viewport + 1
	}
}

func (m *model) clampLargeSelection() {
	if len(m.largeFiles) == 0 {
		m.largeSelected = 0
		m.largeOffset = 0
		return
	}
	if m.largeSelected >= len(m.largeFiles) {
		m.largeSelected = len(m.largeFiles) - 1
	}
	if m.largeSelected < 0 {
		m.largeSelected = 0
	}
	viewport := calculateViewport(m.height, true)
	maxOffset := max(len(m.largeFiles)-viewport, 0)
	if m.largeOffset > maxOffset {
		m.largeOffset = maxOffset
	}
	if m.largeSelected < m.largeOffset {
		m.largeOffset = m.largeSelected
	}
	if m.largeSelected >= m.largeOffset+viewport {
		m.largeOffset = m.largeSelected - viewport + 1
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

func (m *model) removePathFromView(path string) {
	if path == "" {
		return
	}

	var removedSize int64
	for i, entry := range m.entries {
		if entry.Path == path {
			if entry.Size > 0 {
				removedSize = entry.Size
			}
			m.entries = append(m.entries[:i], m.entries[i+1:]...)
			break
		}
	}

	for i := 0; i < len(m.largeFiles); i++ {
		if m.largeFiles[i].Path == path {
			m.largeFiles = append(m.largeFiles[:i], m.largeFiles[i+1:]...)
			break
		}
	}

	if removedSize > 0 {
		if removedSize > m.totalSize {
			m.totalSize = 0
		} else {
			m.totalSize -= removedSize
		}
		m.clampEntrySelection()
	}
	m.clampLargeSelection()
}

func scanOverviewPathCmd(path string, index int) tea.Cmd {
	return func() tea.Msg {
		size, err := measureInsightSize(path)
		return overviewSizeMsg{
			Path:  path,
			Index: index,
			Size:  size,
			Err:   err,
		}
	}
}

// safeOpen executes 'open' command with path validation.
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
