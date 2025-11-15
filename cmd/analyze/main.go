//go:build darwin

package main

import (
	"bytes"
	"context"
	"encoding/gob"
	"encoding/json"
	"fmt"
	"io/fs"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/cespare/xxhash/v2"
	"golang.org/x/sync/singleflight"
)

const (
	maxEntries            = 20
	maxLargeFiles         = 20
	barWidth              = 24
	minLargeFileSize      = 100 << 20 // 100 MB
	entryViewport         = 10
	largeViewport         = 10
	overviewCacheTTL      = 7 * 24 * time.Hour // 7 days
	overviewCacheFile     = "overview_sizes.json"
	duTimeout             = 60 * time.Second // Increased for large directories
	mdlsTimeout           = 5 * time.Second
	maxConcurrentOverview = 3   // Scan up to 3 overview dirs concurrently
	pathUpdateInterval    = 500 // Update current path every N files
	batchUpdateSize       = 100 // Batch atomic updates every N items
)

// Directories to fold: calculate size but don't expand children
// These are typically dependency/cache dirs with thousands of small files
var foldDirs = map[string]bool{
	// Version control
	".git": true,
	".svn": true,
	".hg":  true,

	// JavaScript/Node
	"node_modules":     true,
	".npm":             true,
	"_npx":             true, // ~/.npm/_npx global cache
	"_cacache":         true, // ~/.npm/_cacache
	"_logs":            true, // ~/.npm/_logs
	"_locks":           true, // ~/.npm/_locks
	"_quick":           true, // Quick install cache
	"_libvips":         true, // ~/.npm/_libvips
	"_prebuilds":       true, // ~/.npm/_prebuilds
	"_update-notifier-last-checked": true, // npm update notifier
	".yarn":            true,
	".pnpm-store":      true,
	".next":            true,
	".nuxt":            true,
	"bower_components": true,
	".vite":            true,
	".turbo":           true,
	".parcel-cache":    true,
	".nx":              true,
	".rush":            true,
	"tnpm":             true, // Taobao npm
	".tnpm":            true, // Taobao npm cache
	".bun":             true, // Bun cache
	".deno":            true, // Deno cache

	// Python
	"__pycache__":   true,
	".pytest_cache": true,
	".mypy_cache":   true,
	".ruff_cache":   true,
	"venv":          true,
	".venv":         true,
	"virtualenv":    true,
	".tox":          true,
	"site-packages": true,
	".eggs":         true,
	"*.egg-info":    true,
	".pyenv":        true, // ~/.pyenv
	".poetry":       true, // ~/.poetry
	".pip":          true, // ~/.pip cache
	".pipx":         true, // ~/.pipx

	// Ruby/Go/PHP (vendor), Java/Kotlin/Scala/Rust (target)
	"vendor":        true,
	".bundle":       true,
	"gems":          true,
	".rbenv":        true, // ~/.rbenv
	"target":        true,
	".gradle":       true,
	".m2":           true,
	".ivy2":         true,
	"out":           true,
	"pkg":           true,
	"composer.phar": true,
	".composer":     true, // ~/.composer
	".cargo":        true, // ~/.cargo

	// Build outputs
	"build":     true,
	"dist":      true,
	".output":   true,
	"coverage":  true,
	".coverage": true,

	// IDE
	".idea":   true,
	".vscode": true,
	".vs":     true,
	".fleet":  true,

	// Cache directories
	".cache":          true,
	"__MACOSX":        true,
	".DS_Store":       true,
	".Trash":          true,
	"Caches":          true,
	".Spotlight-V100": true,
	".fseventsd":      true,
	".DocumentRevisions-V100": true,
	".TemporaryItems": true,
	"$RECYCLE.BIN":    true,
	".temp":           true,
	".tmp":            true,
	"_temp":           true,
	"_tmp":            true,
	".Homebrew":       true, // Homebrew cache
	".rustup":         true, // Rust toolchain
	".sdkman":         true, // SDK manager
	".nvm":            true, // Node version manager

	// Docker & Containers
	".docker":     true,
	".containerd": true,

	// Mobile development
	"Pods":        true,
	"DerivedData": true,
	".build":      true,
	"xcuserdata":  true,
	"Carthage":    true,

	// Web frameworks
	".angular":    true,
	".svelte-kit": true,
	".astro":      true,
	".solid":      true,

	// Databases
	".mysql":    true,
	".postgres": true,
	"mongodb":   true,

	// Other
	".terraform": true,
	".vagrant":   true,
	"tmp":        true,
	"temp":       true,
}

// System directories to skip (macOS specific)
var skipSystemDirs = map[string]bool{
	"dev":                     true,
	"tmp":                     true,
	"private":                 true,
	"cores":                   true,
	"net":                     true,
	"home":                    true,
	"System":                  true, // macOS system files
	"sbin":                    true,
	"bin":                     true,
	"etc":                     true,
	"var":                     true,
	".vol":                    true,
	".Spotlight-V100":         true,
	".fseventsd":              true,
	".DocumentRevisions-V100": true,
	".TemporaryItems":         true,
}

// File extensions to skip for large file tracking
var skipExtensions = map[string]bool{
	".go":    true,
	".js":    true,
	".ts":    true,
	".jsx":   true,
	".tsx":   true,
	".py":    true,
	".rb":    true,
	".java":  true,
	".c":     true,
	".cpp":   true,
	".h":     true,
	".hpp":   true,
	".rs":    true,
	".swift": true,
	".m":     true,
	".mm":    true,
	".sh":    true,
	".txt":   true,
	".md":    true,
	".json":  true,
	".xml":   true,
	".yaml":  true,
	".yml":   true,
	".toml":  true,
	".css":   true,
	".scss":  true,
	".html":  true,
	".svg":   true,
}

var spinnerFrames = []string{"⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧"}

// Global singleflight group to avoid duplicate scans of the same path
var scanGroup singleflight.Group

type overviewSizeSnapshot struct {
	Size    int64     `json:"size"`
	Updated time.Time `json:"updated"`
}

var (
	overviewSnapshotMu      sync.Mutex
	overviewSnapshotCache   map[string]overviewSizeSnapshot
	overviewSnapshotLoaded  bool
	overviewSnapshotPathErr error
)

const (
	colorPurple = "\033[0;35m"
	colorBlue   = "\033[0;34m"
	colorGray   = "\033[0;90m"
	colorRed    = "\033[0;31m"
	colorYellow = "\033[1;33m"
	colorGreen  = "\033[0;32m"
	colorCyan   = "\033[0;36m"
	colorReset  = "\033[0m"
	colorBold   = "\033[1m"
	colorBgCyan = "\033[46m"
	colorBgDark = "\033[100m"
	colorInvert = "\033[7m"
)

type dirEntry struct {
	name       string
	path       string
	size       int64
	isDir      bool
	lastAccess time.Time
}

type fileEntry struct {
	name string
	path string
	size int64
}

type scanResult struct {
	entries    []dirEntry
	largeFiles []fileEntry
	totalSize  int64
}

type cacheEntry struct {
	Entries    []dirEntry
	LargeFiles []fileEntry
	TotalSize  int64
	ModTime    time.Time
	ScanTime   time.Time
}

type historyEntry struct {
	path          string
	entries       []dirEntry
	largeFiles    []fileEntry
	totalSize     int64
	selected      int
	entryOffset   int
	largeSelected int
	largeOffset   int
	dirty         bool
}

type scanResultMsg struct {
	result scanResult
	err    error
}

type overviewSizeMsg struct {
	path  string
	index int
	size  int64
	err   error
}

type tickMsg time.Time

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
	currentPath          *string
	showLargeFiles       bool
	isOverview           bool
	deleteConfirm        bool
	deleteTarget         *dirEntry
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
}

func main() {
	target := os.Getenv("MO_ANALYZE_PATH")
	if target == "" && len(os.Args) > 1 {
		target = os.Args[1]
	}

	var abs string
	var isOverview bool

	if target == "" {
		// Default to overview mode
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

	p := tea.NewProgram(newModel(abs, isOverview), tea.WithAltScreen())
	if err := p.Start(); err != nil {
		fmt.Fprintf(os.Stderr, "analyzer error: %v\n", err)
		os.Exit(1)
	}
}

func newModel(path string, isOverview bool) model {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := ""
	var overviewFilesScanned, overviewDirsScanned, overviewBytesScanned int64
	overviewCurrentPath := ""

	m := model{
		path:                 path,
		selected:             0,
		status:               "Preparing scan...",
		scanning:             !isOverview,
		filesScanned:         &filesScanned,
		dirsScanned:          &dirsScanned,
		bytesScanned:         &bytesScanned,
		currentPath:          &currentPath,
		showLargeFiles:       false,
		isOverview:           isOverview,
		cache:                make(map[string]historyEntry),
		overviewFilesScanned: &overviewFilesScanned,
		overviewDirsScanned:  &overviewDirsScanned,
		overviewBytesScanned: &overviewBytesScanned,
		overviewCurrentPath:  &overviewCurrentPath,
		overviewSizeCache:    make(map[string]int64),
		overviewScanningSet:  make(map[string]bool),
	}

	// In overview mode, create shortcut entries
	if isOverview {
		m.scanning = false
		m.hydrateOverviewEntries()
		m.selected = 0
		m.offset = 0
		if nextPendingOverviewIndex(m.entries) >= 0 {
			m.overviewScanning = true
			m.status = "Estimating system roots..."
		} else {
			m.status = "Ready"
		}
	}

	return m
}

func createOverviewEntries() []dirEntry {
	home := os.Getenv("HOME")
	entries := []dirEntry{}

	if home != "" {
		entries = append(entries,
			dirEntry{name: "Home (~)", path: home, isDir: true, size: -1},
			dirEntry{name: "Library (~/Library)", path: filepath.Join(home, "Library"), isDir: true, size: -1},
		)
	}

	entries = append(entries,
		dirEntry{name: "Applications", path: "/Applications", isDir: true, size: -1},
		dirEntry{name: "System Library", path: "/Library", isDir: true, size: -1},
	)

	// Add Volumes if exists
	if _, err := os.Stat("/Volumes"); err == nil {
		entries = append(entries, dirEntry{name: "Volumes", path: "/Volumes", isDir: true, size: -1})
	}

	return entries
}

func (m *model) hydrateOverviewEntries() {
	m.entries = createOverviewEntries()
	if m.overviewSizeCache == nil {
		m.overviewSizeCache = make(map[string]int64)
	}
	for i := range m.entries {
		if size, ok := m.overviewSizeCache[m.entries[i].path]; ok {
			m.entries[i].size = size
			continue
		}
		if size, err := loadOverviewCachedSize(m.entries[i].path); err == nil {
			m.entries[i].size = size
			m.overviewSizeCache[m.entries[i].path] = size
		}
	}
	m.totalSize = sumKnownEntrySizes(m.entries)
}

func (m *model) scheduleOverviewScans() tea.Cmd {
	if !m.isOverview {
		return nil
	}

	// Find pending entries (not scanned and not currently scanning)
	var pendingIndices []int
	for i, entry := range m.entries {
		if entry.size < 0 && !m.overviewScanningSet[entry.path] {
			pendingIndices = append(pendingIndices, i)
			if len(pendingIndices) >= maxConcurrentOverview {
				break
			}
		}
	}

	// No more work to do
	if len(pendingIndices) == 0 {
		m.overviewScanning = false
		if !hasPendingOverviewEntries(m.entries) {
			m.status = "Ready"
		}
		return nil
	}

	// Mark all as scanning
	var cmds []tea.Cmd
	for _, idx := range pendingIndices {
		entry := m.entries[idx]
		m.overviewScanningSet[entry.path] = true
		cmd := scanOverviewPathCmd(entry.path, idx)
		cmds = append(cmds, cmd)
	}

	m.overviewScanning = true
	remaining := 0
	for _, e := range m.entries {
		if e.size < 0 {
			remaining++
		}
	}
	if len(pendingIndices) > 0 {
		firstEntry := m.entries[pendingIndices[0]]
		if len(pendingIndices) == 1 {
			m.status = fmt.Sprintf("Scanning %s... (%d left)", firstEntry.name, remaining)
		} else {
			m.status = fmt.Sprintf("Scanning %d directories... (%d left)", len(pendingIndices), remaining)
		}
	}

	cmds = append(cmds, tickCmd())
	return tea.Batch(cmds...)
}

func (m *model) updateScanProgress(files, dirs, bytes int64, path string) {
	if m.filesScanned != nil {
		atomic.StoreInt64(m.filesScanned, files)
	}
	if m.dirsScanned != nil {
		atomic.StoreInt64(m.dirsScanned, dirs)
	}
	if m.bytesScanned != nil {
		atomic.StoreInt64(m.bytesScanned, bytes)
	}
	if m.currentPath != nil && path != "" {
		*m.currentPath = path
	}
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

func (m *model) getOverviewScanProgress() (files, dirs, bytes int64) {
	if m.overviewFilesScanned != nil {
		files = atomic.LoadInt64(m.overviewFilesScanned)
	}
	if m.overviewDirsScanned != nil {
		dirs = atomic.LoadInt64(m.overviewDirsScanned)
	}
	if m.overviewBytesScanned != nil {
		bytes = atomic.LoadInt64(m.overviewBytesScanned)
	}
	return
}

func (m model) Init() tea.Cmd {
	if m.isOverview {
		return m.scheduleOverviewScans()
	}
	return tea.Batch(m.scanCmd(m.path), tickCmd())
}

func (m model) scanCmd(path string) tea.Cmd {
	return func() tea.Msg {
		// Try to load from persistent cache first
		if cached, err := loadCacheFromDisk(path); err == nil {
			result := scanResult{
				entries:    cached.Entries,
				largeFiles: cached.LargeFiles,
				totalSize:  cached.TotalSize,
			}
			return scanResultMsg{result: result, err: nil}
		}

		// Use singleflight to avoid duplicate scans of the same path
		// If multiple goroutines request the same path, only one scan will be performed
		v, err, _ := scanGroup.Do(path, func() (interface{}, error) {
			return scanPathConcurrent(path, m.filesScanned, m.dirsScanned, m.bytesScanned, m.currentPath)
		})

		if err != nil {
			return scanResultMsg{err: err}
		}

		result := v.(scanResult)

		// Save to persistent cache asynchronously with error logging
		go func(p string, r scanResult) {
			if err := saveCacheToDisk(p, r); err != nil {
				// Log error but don't fail the scan
				_ = err // Cache save failure is not critical
			}
		}(path, result)

		return scanResultMsg{result: result, err: nil}
	}
}

func tickCmd() tea.Cmd {
	return tea.Tick(time.Millisecond*120, func(t time.Time) tea.Msg {
		return tickMsg(t)
	})
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		return m.updateKey(msg)
	case scanResultMsg:
		m.scanning = false
		if msg.err != nil {
			m.status = fmt.Sprintf("Scan failed: %v", msg.err)
			return m, nil
		}
		m.entries = msg.result.entries
		m.largeFiles = msg.result.largeFiles
		m.totalSize = msg.result.totalSize
		m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		m.clampEntrySelection()
		m.clampLargeSelection()
		m.cache[m.path] = cacheSnapshot(m)
		if m.totalSize > 0 {
			if m.overviewSizeCache == nil {
				m.overviewSizeCache = make(map[string]int64)
			}
			m.overviewSizeCache[m.path] = m.totalSize
			go func(path string, size int64) {
				_ = storeOverviewSize(path, size)
			}(m.path, m.totalSize)
		}
		return m, nil
	case overviewSizeMsg:
		// Remove from scanning set
		delete(m.overviewScanningSet, msg.path)

		if msg.err == nil {
			m.overviewSizeCache[msg.path] = msg.size
		}

		if m.isOverview {
			// Update entry with result
			for i := range m.entries {
				if m.entries[i].path == msg.path {
					if msg.err == nil {
						m.entries[i].size = msg.size
					} else {
						m.entries[i].size = 0
					}
					break
				}
			}
			m.totalSize = sumKnownEntrySizes(m.entries)

			// Show error briefly if any
			if msg.err != nil {
				m.status = fmt.Sprintf("Unable to measure %s: %v", displayPath(msg.path), msg.err)
			}

			// Schedule next batch of scans
			cmd := m.scheduleOverviewScans()
			return m, cmd
		}
		return m, nil
	case tickMsg:
		if m.scanning || (m.isOverview && m.overviewScanning) {
			m.spinner = (m.spinner + 1) % len(spinnerFrames)
			return m, tickCmd()
		}
		return m, nil
	default:
		return m, nil
	}
}

func (m model) updateKey(msg tea.KeyMsg) (tea.Model, tea.Cmd) {
	// Handle delete confirmation
	if m.deleteConfirm {
		if msg.String() == "delete" || msg.String() == "backspace" {
			// Confirm delete
			if m.deleteTarget != nil {
				err := os.RemoveAll(m.deleteTarget.path)
				if err != nil {
					m.status = fmt.Sprintf("Failed to delete: %v", err)
				} else {
					m.status = fmt.Sprintf("Deleted %s", m.deleteTarget.name)
					for i := range m.history {
						m.history[i].dirty = true
					}
					for path := range m.cache {
						entry := m.cache[path]
						entry.dirty = true
						m.cache[path] = entry
					}
					// Refresh the view
					m.scanning = true
					m.deleteConfirm = false
					m.deleteTarget = nil
					return m, tea.Batch(m.scanCmd(m.path), tickCmd())
				}
			}
			m.deleteConfirm = false
			m.deleteTarget = nil
			return m, nil
		} else if msg.String() == "esc" || msg.String() == "q" {
			// Cancel delete with ESC or Q
			m.status = "Cancelled"
			m.deleteConfirm = false
			m.deleteTarget = nil
			return m, nil
		} else {
			// Any other key also cancels
			m.status = "Cancelled"
			m.deleteConfirm = false
			m.deleteTarget = nil
			return m, nil
		}
	}

	switch msg.String() {
	case "q", "ctrl+c":
		return m, tea.Quit
	case "esc":
		if m.showLargeFiles {
			m.showLargeFiles = false
			return m, nil
		}
		return m, tea.Quit
	case "up", "k":
		if m.showLargeFiles {
			if m.largeSelected > 0 {
				m.largeSelected--
				if m.largeSelected < m.largeOffset {
					m.largeOffset = m.largeSelected
				}
			}
		} else if len(m.entries) > 0 && m.selected > 0 {
			m.selected--
			if m.selected < m.offset {
				m.offset = m.selected
			}
		}
	case "down", "j":
		if m.showLargeFiles {
			if m.largeSelected < len(m.largeFiles)-1 {
				m.largeSelected++
				if m.largeSelected >= m.largeOffset+largeViewport {
					m.largeOffset = m.largeSelected - largeViewport + 1
				}
			}
		} else if len(m.entries) > 0 && m.selected < len(m.entries)-1 {
			m.selected++
			if m.selected >= m.offset+entryViewport {
				m.offset = m.selected - entryViewport + 1
			}
		}
	case "enter":
		if m.showLargeFiles {
			return m, nil
		}
		return m.enterSelectedDir()
	case "right":
		if m.showLargeFiles {
			return m, nil
		}
		return m.enterSelectedDir()
	case "b", "left":
		if m.showLargeFiles {
			m.showLargeFiles = false
			return m, nil
		}
		if len(m.history) == 0 {
			// Return to overview if at top level
			if !m.isOverview {
				return m, m.switchToOverviewMode()
			}
			return m, nil
		}
		last := m.history[len(m.history)-1]
		m.history = m.history[:len(m.history)-1]
		m.path = last.path
		m.selected = last.selected
		m.offset = last.entryOffset
		m.largeSelected = last.largeSelected
		m.largeOffset = last.largeOffset
		m.isOverview = false
		if last.dirty {
			m.status = "Scanning..."
			m.scanning = true
			return m, tea.Batch(m.scanCmd(m.path), tickCmd())
		}
		m.entries = last.entries
		m.largeFiles = last.largeFiles
		m.totalSize = last.totalSize
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
		m.status = fmt.Sprintf("Scanned %s", humanizeBytes(m.totalSize))
		m.scanning = false
		return m, nil
	case "r":
		m.status = "Refreshing..."
		m.scanning = true
		return m, tea.Batch(m.scanCmd(m.path), tickCmd())
	case "l":
		m.showLargeFiles = !m.showLargeFiles
		if m.showLargeFiles {
			m.largeSelected = 0
			m.largeOffset = 0
		}
	case "o":
		// Open selected entry
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				selected := m.largeFiles[m.largeSelected]
				go func() {
					_ = exec.Command("open", selected.path).Run()
				}()
				m.status = fmt.Sprintf("Opening %s...", selected.name)
			}
		} else if len(m.entries) > 0 {
			selected := m.entries[m.selected]
			go func() {
				_ = exec.Command("open", selected.path).Run()
			}()
			m.status = fmt.Sprintf("Opening %s...", selected.name)
		}
	case "f", "F":
		// Reveal selected entry in Finder
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				selected := m.largeFiles[m.largeSelected]
				go func(path string) {
					_ = exec.Command("open", "-R", path).Run()
				}(selected.path)
				m.status = fmt.Sprintf("Revealing %s in Finder...", selected.name)
			}
		} else if len(m.entries) > 0 {
			selected := m.entries[m.selected]
			go func(path string) {
				_ = exec.Command("open", "-R", path).Run()
			}(selected.path)
			m.status = fmt.Sprintf("Revealing %s in Finder...", selected.name)
		}
	case "delete", "backspace":
		// Delete selected file or directory
		if m.showLargeFiles {
			if len(m.largeFiles) > 0 {
				selected := m.largeFiles[m.largeSelected]
				m.deleteConfirm = true
				m.deleteTarget = &dirEntry{
					name:  selected.name,
					path:  selected.path,
					size:  selected.size,
					isDir: false,
				}
			}
		} else if len(m.entries) > 0 && !m.isOverview {
			selected := m.entries[m.selected]
			m.deleteConfirm = true
			m.deleteTarget = &selected
		}
	}
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
	}
	return cmd
}

func (m model) enterSelectedDir() (tea.Model, tea.Cmd) {
	if len(m.entries) == 0 {
		return m, nil
	}
	selected := m.entries[m.selected]
	if selected.isDir {
		if !m.isOverview {
			m.history = append(m.history, snapshotFromModel(m))
		}
		m.path = selected.path
		m.selected = 0
		m.offset = 0
		m.status = "Scanning..."
		m.scanning = true
		m.isOverview = false
		if cached, ok := m.cache[m.path]; ok && !cached.dirty {
			m.entries = cloneDirEntries(cached.entries)
			m.largeFiles = cloneFileEntries(cached.largeFiles)
			m.totalSize = cached.totalSize
			m.selected = cached.selected
			m.offset = cached.entryOffset
			m.largeSelected = cached.largeSelected
			m.largeOffset = cached.largeOffset
			m.clampEntrySelection()
			m.clampLargeSelection()
			m.status = fmt.Sprintf("Cached view for %s", displayPath(m.path))
			m.scanning = false
			return m, nil
		}
		return m, tea.Batch(m.scanCmd(m.path), tickCmd())
	}
	m.status = fmt.Sprintf("File: %s (%s)", selected.name, humanizeBytes(selected.size))
	return m, nil
}

func (m model) View() string {
	var b strings.Builder
	fmt.Fprintln(&b)

	if m.deleteConfirm && m.deleteTarget != nil {
		// Show delete confirmation prominently at the top
		fmt.Fprintf(&b, "%sDelete: %s (%s)? Press Delete again to confirm, ESC to cancel%s\n\n",
			colorRed, m.deleteTarget.name, humanizeBytes(m.deleteTarget.size), colorReset)
	}

	if m.isOverview {
		fmt.Fprintf(&b, "%sAnalyze Disk%s\n", colorPurple, colorReset)
		if m.overviewScanning {
			fmt.Fprintf(&b, "%sSelect a location to explore:%s  ", colorGray, colorReset)
			fmt.Fprintf(&b, "%s%s%s%s Scanning...\n", colorCyan, colorBold, spinnerFrames[m.spinner], colorReset)
		} else {
			fmt.Fprintf(&b, "%sSelect a location to explore:%s\n", colorGray, colorReset)
		}
	} else {
		fmt.Fprintf(&b, "%sAnalyze Disk%s  %s%s%s", colorPurple, colorReset, colorGray, displayPath(m.path), colorReset)
		if !m.scanning {
			fmt.Fprintf(&b, "  |  Total: %s", humanizeBytes(m.totalSize))
		}
		fmt.Fprintln(&b)
	}

	if m.scanning {
		filesScanned, dirsScanned, bytesScanned := m.getScanProgress()

		fmt.Fprintf(&b, "\n%s%s%s%s Scanning: %s%s files%s, %s%s dirs%s, %s%s%s\n",
			colorCyan, colorBold,
			spinnerFrames[m.spinner],
			colorReset,
			colorYellow, formatNumber(filesScanned), colorReset,
			colorYellow, formatNumber(dirsScanned), colorReset,
			colorGreen, humanizeBytes(bytesScanned), colorReset)

		if m.currentPath != nil {
			currentPath := *m.currentPath
			if currentPath != "" {
				shortPath := displayPath(currentPath)
				shortPath = truncateMiddle(shortPath, 60)
				fmt.Fprintf(&b, "%s%s%s\n", colorGray, shortPath, colorReset)
			}
		}

		return b.String()
	}

	fmt.Fprintln(&b)

	if m.showLargeFiles {
		if len(m.largeFiles) == 0 {
			fmt.Fprintln(&b, "  No large files found (>=100MB)")
		} else {
			start := m.largeOffset
			if start < 0 {
				start = 0
			}
			end := start + largeViewport
			if end > len(m.largeFiles) {
				end = len(m.largeFiles)
			}
			maxLargeSize := int64(1)
			for _, file := range m.largeFiles {
				if file.size > maxLargeSize {
					maxLargeSize = file.size
				}
			}
			for idx := start; idx < end; idx++ {
				file := m.largeFiles[idx]
				shortPath := displayPath(file.path)
				shortPath = truncateMiddle(shortPath, 56)
				entryPrefix := "    "
				if idx == m.largeSelected {
					entryPrefix = fmt.Sprintf(" %s%s▶%s  ", colorCyan, colorBold, colorReset)
				}
				nameColumn := padName(shortPath, 56)
				size := humanizeBytes(file.size)
				bar := coloredProgressBar(file.size, maxLargeSize, 0)
				fmt.Fprintf(&b, "%s%2d. %s  |  📄 %s %s%10s%s\n",
					entryPrefix, idx+1, bar, nameColumn, colorGray, size, colorReset)
			}
		}
	} else {
		if len(m.entries) == 0 {
			fmt.Fprintln(&b, "  Empty directory")
		} else {
			if m.isOverview {
				maxSize := int64(1)
				for _, entry := range m.entries {
					if entry.size > maxSize {
						maxSize = entry.size
					}
				}
				totalSize := m.totalSize
				for idx, entry := range m.entries {
					icon := "📁"
					sizeVal := entry.size
					barValue := sizeVal
					if barValue < 0 {
						barValue = 0
					}
					var percent float64
					if totalSize > 0 && sizeVal >= 0 {
						percent = float64(sizeVal) / float64(totalSize) * 100
					} else {
						percent = 0
					}
					percentStr := fmt.Sprintf("%5.1f%%", percent)
					if totalSize == 0 || sizeVal < 0 {
						percentStr = "  --  "
					}
					bar := coloredProgressBar(barValue, maxSize, percent)
					sizeText := "pending.."
					if sizeVal >= 0 {
						sizeText = humanizeBytes(sizeVal)
					}
					sizeColor := colorGray
					if sizeVal >= 0 && totalSize > 0 {
						switch {
						case percent >= 50:
							sizeColor = colorRed
						case percent >= 20:
							sizeColor = colorYellow
						case percent >= 5:
							sizeColor = colorCyan
						default:
							sizeColor = colorGray
						}
					}
					entryPrefix := "    "
					name := trimName(entry.name)
					paddedName := padName(name, 28)
					nameSegment := fmt.Sprintf("%s %s", icon, paddedName)
					if idx == m.selected {
						entryPrefix = fmt.Sprintf(" %s%s▶%s  ", colorCyan, colorBold, colorReset)
						nameSegment = fmt.Sprintf("%s%s %s%s", colorBold, icon, paddedName, colorReset)
					}
					displayIndex := idx + 1

					// Add unused time label if applicable
					// For overview mode, get access time on-demand if not set and cache it
					lastAccess := entry.lastAccess
					if lastAccess.IsZero() && entry.path != "" {
						lastAccess = getLastAccessTime(entry.path)
						// Cache the result to avoid repeated syscalls
						m.entries[idx].lastAccess = lastAccess
					}
					unusedLabel := formatUnusedTime(lastAccess)
					if unusedLabel == "" {
						fmt.Fprintf(&b, "%s%2d. %s %s  |  %s %s%10s%s\n",
							entryPrefix, displayIndex, bar, percentStr,
							nameSegment, sizeColor, sizeText, colorReset)
					} else {
						fmt.Fprintf(&b, "%s%2d. %s %s  |  %s %s%10s%s  %s%s%s\n",
							entryPrefix, displayIndex, bar, percentStr,
							nameSegment, sizeColor, sizeText, colorReset,
							colorGray, unusedLabel, colorReset)
					}
				}
			} else {
				// Normal mode with sizes and progress bars
				maxSize := int64(1)
				for _, entry := range m.entries {
					if entry.size > maxSize {
						maxSize = entry.size
					}
				}

				start := m.offset
				if start < 0 {
					start = 0
				}
				end := start + entryViewport
				if end > len(m.entries) {
					end = len(m.entries)
				}

				for idx := start; idx < end; idx++ {
					entry := m.entries[idx]
					icon := "📄"
					if entry.isDir {
						icon = "📁"
					}
					size := humanizeBytes(entry.size)
					name := trimName(entry.name)
					paddedName := padName(name, 28)

					// Calculate percentage
					percent := float64(entry.size) / float64(m.totalSize) * 100
					percentStr := fmt.Sprintf("%5.1f%%", percent)

					// Get colored progress bar
					bar := coloredProgressBar(entry.size, maxSize, percent)

					// Color the size based on magnitude
					var sizeColor string
					if percent >= 50 {
						sizeColor = colorRed
					} else if percent >= 20 {
						sizeColor = colorYellow
					} else if percent >= 5 {
						sizeColor = colorCyan
					} else {
						sizeColor = colorGray
					}

					// Keep chart columns aligned even when arrow is shown
					entryPrefix := "    "
					nameSegment := fmt.Sprintf("%s %s", icon, paddedName)
					if idx == m.selected {
						entryPrefix = fmt.Sprintf(" %s%s▶%s  ", colorCyan, colorBold, colorReset)
						nameSegment = fmt.Sprintf("%s%s %s%s", colorBold, icon, paddedName, colorReset)
					}

					displayIndex := idx + 1

					// Add unused time label if applicable
					unusedLabel := formatUnusedTime(entry.lastAccess)
					if unusedLabel == "" {
						fmt.Fprintf(&b, "%s%2d. %s %s  |  %s %s%10s%s\n",
							entryPrefix, displayIndex, bar, percentStr,
							nameSegment, sizeColor, size, colorReset)
					} else {
						fmt.Fprintf(&b, "%s%2d. %s %s  |  %s %s%10s%s  %s%s%s\n",
							entryPrefix, displayIndex, bar, percentStr,
							nameSegment, sizeColor, size, colorReset,
							colorGray, unusedLabel, colorReset)
					}
				}
			}
		}
	}

	fmt.Fprintln(&b)
	if m.isOverview {
		fmt.Fprintf(&b, "%s  ↑↓←→ Navigate  |  Enter Explore  |  O Open  |  F Reveal  |  Q Quit%s\n", colorGray, colorReset)
	} else if m.showLargeFiles {
		fmt.Fprintf(&b, "%s  ↑↓ Navigate  |  O Open  |  F Reveal  |  ⌫ Delete  |  Q Quit%s\n", colorGray, colorReset)
	} else {
		largeFileCount := len(m.largeFiles)
		if largeFileCount > 0 {
			fmt.Fprintf(&b, "%s  ↑↓←→ Navigate  |  O Open  |  F Reveal  |  ⌫ Delete  |  L Large(%d)  |  Q Quit%s\n", colorGray, largeFileCount, colorReset)
		} else {
			fmt.Fprintf(&b, "%s  ↑↓←→ Navigate  |  O Open  |  F Reveal  |  ⌫ Delete  |  Q Quit%s\n", colorGray, colorReset)
		}
	}
	return b.String()
}

func scanPathConcurrent(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) (scanResult, error) {
	children, err := os.ReadDir(root)
	if err != nil {
		return scanResult{}, err
	}

	tracker := newLargeFileTracker()
	var total int64
	entries := make([]dirEntry, 0, len(children))
	var entriesMu sync.Mutex

	// Use worker pool for concurrent directory scanning
	// For I/O-bound operations, use more workers than CPU count
	maxWorkers := runtime.NumCPU() * 4
	if maxWorkers < 16 {
		maxWorkers = 16 // Minimum 16 workers for better I/O throughput
	}
	// Cap at 128 to avoid excessive goroutines
	if maxWorkers > 128 {
		maxWorkers = 128
	}
	if maxWorkers > len(children) {
		maxWorkers = len(children)
	}
	if maxWorkers < 1 {
		maxWorkers = 1
	}
	sem := make(chan struct{}, maxWorkers)
	var wg sync.WaitGroup

	isRootDir := root == "/"

	for _, child := range children {
		fullPath := filepath.Join(root, child.Name())

		if child.IsDir() {
			// In root directory, skip system directories completely
			if isRootDir && skipSystemDirs[child.Name()] {
				continue
			}

			// For folded directories, calculate size quickly without expanding
			if shouldFoldDirWithPath(child.Name(), fullPath) {
				wg.Add(1)
				go func(name, path string) {
					defer wg.Done()
					sem <- struct{}{}
					defer func() { <-sem }()

					// Try du command first for folded dirs (much faster)
					size := calculateDirSizeWithDu(path)
					if size <= 0 {
						// Fallback to walk if du fails
						size = calculateDirSizeFast(path, filesScanned, dirsScanned, bytesScanned, currentPath)
					}
					atomic.AddInt64(&total, size)
					atomic.AddInt64(dirsScanned, 1)

					entry := dirEntry{
						name:       name,
						path:       path,
						size:       size,
						isDir:      true,
						lastAccess: getLastAccessTime(path),
					}
					entriesMu.Lock()
					entries = append(entries, entry)
					entriesMu.Unlock()
				}(child.Name(), fullPath)
				continue
			}

			// Normal directory: full scan with detail
			wg.Add(1)
			go func(name, path string) {
				defer wg.Done()
				sem <- struct{}{}
				defer func() { <-sem }()

				size := calculateDirSizeConcurrent(path, tracker, filesScanned, dirsScanned, bytesScanned, currentPath)
				atomic.AddInt64(&total, size)
				atomic.AddInt64(dirsScanned, 1)

				entry := dirEntry{
					name:       name,
					path:       path,
					size:       size,
					isDir:      true,
					lastAccess: getLastAccessTime(path),
				}
				entriesMu.Lock()
				entries = append(entries, entry)
				entriesMu.Unlock()
			}(child.Name(), fullPath)
			continue
		}

		info, err := child.Info()
		if err != nil {
			continue
		}
		size := fileDiskUsage(info)
		atomic.AddInt64(&total, size)
		atomic.AddInt64(filesScanned, 1)
		atomic.AddInt64(bytesScanned, size)

		entries = append(entries, dirEntry{
			name:       child.Name(),
			path:       fullPath,
			size:       size,
			isDir:      false,
			lastAccess: getLastAccessTime(fullPath),
		})
		// Only track large files that are not code/text files
		if !shouldSkipFileForLargeTracking(fullPath) {
			tracker.add(fileEntry{name: child.Name(), path: fullPath, size: size})
		}
	}

	wg.Wait()

	sort.Slice(entries, func(i, j int) bool {
		return entries[i].size > entries[j].size
	})
	if len(entries) > maxEntries {
		entries = entries[:maxEntries]
	}

	// Try to use Spotlight for faster large file discovery
	var largeFiles []fileEntry
	if spotlightFiles := findLargeFilesWithSpotlight(root, minLargeFileSize); len(spotlightFiles) > 0 {
		largeFiles = spotlightFiles
	} else {
		// Fallback to manual tracking
		largeFiles = tracker.list()
	}

	return scanResult{
		entries:    entries,
		largeFiles: largeFiles,
		totalSize:  total,
	}, nil
}

func shouldFoldDir(name string) bool {
	return foldDirs[name]
}

// shouldFoldDirWithPath checks if a directory should be folded based on path context
func shouldFoldDirWithPath(name, path string) bool {
	// Check basic fold list first
	if foldDirs[name] {
		return true
	}

	// Special case: .npm directory - fold all single-letter subdirectories (npm cache structure)
	if strings.Contains(path, "/.npm/") && len(name) == 1 {
		return true
	}

	return false
}

// calculateDirSizeWithDu uses du command for fast directory size calculation
// Returns size in bytes, or 0 if command fails
func calculateDirSizeWithDu(path string) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	// Use -sb for exact byte count (matches fileDiskUsage behavior)
	// -s: summarize (don't show subdirs), -b: bytes (not blocks)
	cmd := exec.CommandContext(ctx, "du", "-sb", path)
	output, err := cmd.Output()
	if err != nil {
		return 0
	}

	fields := strings.Fields(string(output))
	if len(fields) < 1 {
		return 0
	}

	bytes, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0
	}

	return bytes
}

func shouldSkipFileForLargeTracking(path string) bool {
	ext := strings.ToLower(filepath.Ext(path))
	return skipExtensions[ext]
}

// calculateDirSizeFast performs fast directory size calculation without detailed tracking or large file detection.
// Updates progress counters in batches to reduce atomic operation overhead.
func calculateDirSizeFast(root string, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) int64 {
	var total int64
	var localFiles, localDirs int64
	var batchBytes int64

	// Create context with timeout
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	walkFunc := func(path string, d fs.DirEntry, err error) error {
		// Check for timeout
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if err != nil {
			return nil
		}
		if d.IsDir() {
			localDirs++
			// Batch update every N dirs to reduce atomic operations
			if localDirs%batchUpdateSize == 0 {
				atomic.AddInt64(dirsScanned, batchUpdateSize)
				localDirs = 0
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		size := fileDiskUsage(info)
		total += size
		batchBytes += size
		localFiles++
		if currentPath != nil {
			*currentPath = path
		}
		// Batch update every N files to reduce atomic operations
		if localFiles%batchUpdateSize == 0 {
			atomic.AddInt64(filesScanned, batchUpdateSize)
			atomic.AddInt64(bytesScanned, batchBytes)
			localFiles = 0
			batchBytes = 0
		}
		return nil
	}

	_ = filepath.WalkDir(root, walkFunc)

	// Final update for remaining counts
	if localFiles > 0 {
		atomic.AddInt64(filesScanned, localFiles)
	}
	if localDirs > 0 {
		atomic.AddInt64(dirsScanned, localDirs)
	}
	if batchBytes > 0 {
		atomic.AddInt64(bytesScanned, batchBytes)
	}

	return total
}

// Use Spotlight (mdfind) to quickly find large files in a directory
func findLargeFilesWithSpotlight(root string, minSize int64) []fileEntry {
	// mdfind query: files >= minSize in the specified directory
	query := fmt.Sprintf("kMDItemFSSize >= %d", minSize)

	cmd := exec.Command("mdfind", "-onlyin", root, query)
	output, err := cmd.Output()
	if err != nil {
		// Fallback: mdfind not available or failed
		return nil
	}

	lines := strings.Split(strings.TrimSpace(string(output)), "\n")
	var files []fileEntry

	for _, line := range lines {
		if line == "" {
			continue
		}

		// Check if it's a directory, skip it
		info, err := os.Stat(line)
		if err != nil || info.IsDir() {
			continue
		}

		// Filter out files in folded directories
		inFoldedDir := false
		for foldDir := range foldDirs {
			if strings.Contains(line, string(os.PathSeparator)+foldDir+string(os.PathSeparator)) ||
				strings.HasSuffix(filepath.Dir(line), string(os.PathSeparator)+foldDir) {
				inFoldedDir = true
				break
			}
		}
		if inFoldedDir {
			continue
		}

		// Filter out code files
		if shouldSkipFileForLargeTracking(line) {
			continue
		}

		files = append(files, fileEntry{
			name: filepath.Base(line),
			path: line,
			size: fileDiskUsage(info),
		})
	}

	// Sort by size (descending)
	sort.Slice(files, func(i, j int) bool {
		return files[i].size > files[j].size
	})

	// Return top N
	if len(files) > maxLargeFiles {
		files = files[:maxLargeFiles]
	}

	return files
}

func calculateDirSizeConcurrent(root string, tracker *largeFileTracker, filesScanned, dirsScanned, bytesScanned *int64, currentPath *string) int64 {
	var total int64
	var updateCounter int64
	var localFiles, localDirs int64
	var batchBytes int64

	// Create context with timeout for very large directories
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Minute)
	defer cancel()

	walkFunc := func(path string, d fs.DirEntry, err error) error {
		// Check for context cancellation
		select {
		case <-ctx.Done():
			return ctx.Err()
		default:
		}
		if err != nil {
			return nil
		}
		if d.IsDir() {
			// Skip folded directories during recursive scanning, but calculate their size first
			if shouldFoldDirWithPath(d.Name(), path) {
				// Calculate folded directory size and add to parent total
				foldedSize := calculateDirSizeWithDu(path)
				if foldedSize > 0 {
					total += foldedSize
					atomic.AddInt64(bytesScanned, foldedSize)
				}
				return filepath.SkipDir
			}
			localDirs++
			// Batch update every N dirs to reduce atomic operations
			if localDirs%batchUpdateSize == 0 {
				atomic.AddInt64(dirsScanned, batchUpdateSize)
				localDirs = 0
			}
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		size := fileDiskUsage(info)
		total += size
		batchBytes += size
		localFiles++

		// Batch update every N files to reduce atomic operations
		if localFiles%batchUpdateSize == 0 {
			atomic.AddInt64(filesScanned, batchUpdateSize)
			atomic.AddInt64(bytesScanned, batchBytes)
			localFiles = 0
			batchBytes = 0
		}

		// Only track large files that are not code/text files
		if !shouldSkipFileForLargeTracking(path) {
			tracker.add(fileEntry{name: filepath.Base(path), path: path, size: size})
		}

		// Update current path periodically to reduce contention
		updateCounter++
		if updateCounter%pathUpdateInterval == 0 && currentPath != nil {
			*currentPath = path
		}

		return nil
	}

	_ = filepath.WalkDir(root, walkFunc)

	// Final update for remaining counts
	if localFiles > 0 {
		atomic.AddInt64(filesScanned, localFiles)
	}
	if localDirs > 0 {
		atomic.AddInt64(dirsScanned, localDirs)
	}
	if batchBytes > 0 {
		atomic.AddInt64(bytesScanned, batchBytes)
	}

	return total
}

type largeFileTracker struct {
	mu        sync.Mutex
	entries   []fileEntry
	minSize   int64
	needsSort bool
}

func newLargeFileTracker() *largeFileTracker {
	return &largeFileTracker{
		entries: make([]fileEntry, 0, maxLargeFiles*2), // Pre-allocate more space
		minSize: minLargeFileSize,
	}
}

func (t *largeFileTracker) add(f fileEntry) {
	if f.size < t.minSize {
		return
	}

	t.mu.Lock()
	defer t.mu.Unlock()

	// Just append without sorting - sort only once at the end
	t.entries = append(t.entries, f)
	t.needsSort = true

	// Update minimum size threshold dynamically
	if len(t.entries) > maxLargeFiles*3 {
		// Periodically sort and trim to avoid memory bloat
		sort.Slice(t.entries, func(i, j int) bool {
			return t.entries[i].size > t.entries[j].size
		})
		if len(t.entries) > maxLargeFiles {
			t.minSize = t.entries[maxLargeFiles-1].size
			t.entries = t.entries[:maxLargeFiles]
		}
		t.needsSort = false
	}
}

func (t *largeFileTracker) list() []fileEntry {
	t.mu.Lock()
	defer t.mu.Unlock()

	// Sort only when needed
	if t.needsSort {
		sort.Slice(t.entries, func(i, j int) bool {
			return t.entries[i].size > t.entries[j].size
		})
		if len(t.entries) > maxLargeFiles {
			t.entries = t.entries[:maxLargeFiles]
		}
		t.needsSort = false
	}

	return append([]fileEntry(nil), t.entries...)
}

func displayPath(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	if strings.HasPrefix(path, home) {
		return strings.Replace(path, home, "~", 1)
	}
	return path
}

// truncateMiddle truncates string in the middle, keeping head and tail
// e.g. "very/long/path/to/file.txt" -> "very/long/.../file.txt"
func truncateMiddle(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}

	// Reserve 3 chars for "..."
	if maxLen < 10 {
		return s[:maxLen]
	}

	// Keep more of the tail (filename usually more important)
	headLen := (maxLen - 3) / 3
	tailLen := maxLen - 3 - headLen

	return s[:headLen] + "..." + s[len(s)-tailLen:]
}

func formatNumber(n int64) string {
	if n < 1000 {
		return fmt.Sprintf("%d", n)
	}
	if n < 1000000 {
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	}
	return fmt.Sprintf("%.1fM", float64(n)/1000000)
}

func humanizeBytes(size int64) string {
	if size < 0 {
		return "0 B"
	}
	const unit = 1024
	if size < unit {
		return fmt.Sprintf("%d B", size)
	}
	div, exp := int64(unit), 0
	for n := size / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	value := float64(size) / float64(div)
	return fmt.Sprintf("%.1f %cB", value, "KMGTPE"[exp])
}

func progressBar(value, max int64) string {
	if max <= 0 {
		return strings.Repeat("░", barWidth)
	}
	filled := int((value * int64(barWidth)) / max)
	if filled > barWidth {
		filled = barWidth
	}
	bar := strings.Repeat("█", filled)
	if filled < barWidth {
		bar += strings.Repeat("░", barWidth-filled)
	}
	return bar
}

func coloredProgressBar(value, max int64, percent float64) string {
	if max <= 0 {
		return colorGray + strings.Repeat("░", barWidth) + colorReset
	}

	filled := int((value * int64(barWidth)) / max)
	if filled > barWidth {
		filled = barWidth
	}

	// Choose color based on percentage
	var barColor string
	if percent >= 50 {
		barColor = colorRed // Large files in red
	} else if percent >= 20 {
		barColor = colorYellow // Medium files in yellow
	} else if percent >= 5 {
		barColor = colorCyan // Small-medium in cyan
	} else {
		barColor = colorGreen // Small files in green
	}

	// Create gradient bar with different characters
	bar := barColor
	for i := 0; i < barWidth; i++ {
		if i < filled {
			if i < filled-1 {
				bar += "█"
			} else {
				// Last filled character might be partial
				remainder := (value * int64(barWidth)) % max
				if remainder > max/2 {
					bar += "█"
				} else if remainder > max/4 {
					bar += "▓"
				} else {
					bar += "▒"
				}
			}
		} else {
			bar += colorGray + "░" + barColor
		}
	}
	bar += colorReset

	return bar
}

// Calculate display width considering CJK characters
func runeWidth(r rune) int {
	if r >= 0x4E00 && r <= 0x9FFF || // CJK Unified Ideographs
		r >= 0x3400 && r <= 0x4DBF || // CJK Extension A
		r >= 0xAC00 && r <= 0xD7AF || // Hangul
		r >= 0xFF00 && r <= 0xFFEF { // Fullwidth forms
		return 2
	}
	return 1
}

func displayWidth(s string) int {
	width := 0
	for _, r := range s {
		width += runeWidth(r)
	}
	return width
}

func trimName(name string) string {
	const (
		maxWidth      = 28
		ellipsis      = "..."
		ellipsisWidth = 3
	)

	runes := []rune(name)
	widths := make([]int, len(runes))
	for i, r := range runes {
		widths[i] = runeWidth(r)
	}

	currentWidth := 0
	for i, w := range widths {
		if currentWidth+w > maxWidth {
			subWidth := currentWidth
			j := i
			for j > 0 && subWidth+ellipsisWidth > maxWidth {
				j--
				subWidth -= widths[j]
			}
			if j == 0 {
				return ellipsis
			}
			return string(runes[:j]) + ellipsis
		}
		currentWidth += w
	}

	return name
}

func padName(name string, targetWidth int) string {
	currentWidth := displayWidth(name)
	if currentWidth >= targetWidth {
		return name
	}
	return name + strings.Repeat(" ", targetWidth-currentWidth)
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
	maxOffset := len(m.entries) - entryViewport
	if maxOffset < 0 {
		maxOffset = 0
	}
	if m.offset > maxOffset {
		m.offset = maxOffset
	}
	if m.selected < m.offset {
		m.offset = m.selected
	}
	if m.selected >= m.offset+entryViewport {
		m.offset = m.selected - entryViewport + 1
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
	maxOffset := len(m.largeFiles) - largeViewport
	if maxOffset < 0 {
		maxOffset = 0
	}
	if m.largeOffset > maxOffset {
		m.largeOffset = maxOffset
	}
	if m.largeSelected < m.largeOffset {
		m.largeOffset = m.largeSelected
	}
	if m.largeSelected >= m.largeOffset+largeViewport {
		m.largeOffset = m.largeSelected - largeViewport + 1
	}
}

func cloneDirEntries(entries []dirEntry) []dirEntry {
	if len(entries) == 0 {
		return nil
	}
	copied := make([]dirEntry, len(entries))
	copy(copied, entries)
	return copied
}

func cloneFileEntries(files []fileEntry) []fileEntry {
	if len(files) == 0 {
		return nil
	}
	copied := make([]fileEntry, len(files))
	copy(copied, files)
	return copied
}

func fileDiskUsage(info fs.FileInfo) int64 {
	if info == nil {
		return 0
	}
	if stat, ok := info.Sys().(*syscall.Stat_t); ok {
		if stat.Blocks > 0 {
			const blockSize = 512 // stat.Blocks counts 512-byte units on POSIX systems
			return int64(stat.Blocks) * blockSize
		}
		if stat.Blksize > 0 && info.Size() > 0 {
			// Approximate allocation by rounding the logical size up to block size.
			blk := int64(stat.Blksize)
			blocks := (info.Size() + blk - 1) / blk
			return blocks * blk
		}
	}
	return info.Size()
}

func sumKnownEntrySizes(entries []dirEntry) int64 {
	var total int64
	for _, entry := range entries {
		if entry.size > 0 {
			total += entry.size
		}
	}
	return total
}

func nextPendingOverviewIndex(entries []dirEntry) int {
	for i, entry := range entries {
		if entry.size < 0 {
			return i
		}
	}
	return -1
}

func hasPendingOverviewEntries(entries []dirEntry) bool {
	for _, entry := range entries {
		if entry.size < 0 {
			return true
		}
	}
	return false
}

func ensureOverviewSnapshotCacheLocked() error {
	if overviewSnapshotLoaded {
		return nil
	}
	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		return err
	}
	data, err := os.ReadFile(storePath)
	if err != nil {
		if os.IsNotExist(err) {
			overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
			overviewSnapshotLoaded = true
			return nil
		}
		return err
	}
	if len(data) == 0 {
		overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
		overviewSnapshotLoaded = true
		return nil
	}
	var snapshots map[string]overviewSizeSnapshot
	if err := json.Unmarshal(data, &snapshots); err != nil || snapshots == nil {
		// File is corrupted, rename it instead of silently discarding
		backupPath := storePath + ".corrupt"
		_ = os.Rename(storePath, backupPath)
		overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
		overviewSnapshotLoaded = true
		return nil
	}
	overviewSnapshotCache = snapshots
	overviewSnapshotLoaded = true
	return nil
}

func getOverviewSizeStorePath() (string, error) {
	cacheDir, err := getCacheDir()
	if err != nil {
		return "", err
	}
	return filepath.Join(cacheDir, "overview_sizes.json"), nil
}

// loadStoredOverviewSize retrieves cached directory size from JSON cache.
// Returns error if cache is missing or expired (older than overviewCacheTTL).
func loadStoredOverviewSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}
	overviewSnapshotMu.Lock()
	defer overviewSnapshotMu.Unlock()
	if err := ensureOverviewSnapshotCacheLocked(); err != nil {
		return 0, err
	}
	if overviewSnapshotCache == nil {
		return 0, fmt.Errorf("snapshot cache unavailable")
	}
	if snapshot, ok := overviewSnapshotCache[path]; ok && snapshot.Size > 0 {
		// Check if cache is still valid
		if time.Since(snapshot.Updated) < overviewCacheTTL {
			return snapshot.Size, nil
		}
		return 0, fmt.Errorf("snapshot expired")
	}
	return 0, fmt.Errorf("snapshot not found")
}

// storeOverviewSize saves directory size to JSON cache with current timestamp.
func storeOverviewSize(path string, size int64) error {
	if path == "" || size <= 0 {
		return fmt.Errorf("invalid overview size")
	}
	overviewSnapshotMu.Lock()
	defer overviewSnapshotMu.Unlock()
	if err := ensureOverviewSnapshotCacheLocked(); err != nil {
		return err
	}
	if overviewSnapshotCache == nil {
		overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
	}
	overviewSnapshotCache[path] = overviewSizeSnapshot{
		Size:    size,
		Updated: time.Now(),
	}
	return persistOverviewSnapshotLocked()
}

func persistOverviewSnapshotLocked() error {
	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		return err
	}
	tmpPath := storePath + ".tmp"
	data, err := json.MarshalIndent(overviewSnapshotCache, "", "  ")
	if err != nil {
		return err
	}
	if err := os.WriteFile(tmpPath, data, 0644); err != nil {
		return err
	}
	return os.Rename(tmpPath, storePath)
}

func loadOverviewCachedSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}
	if snapshot, err := loadStoredOverviewSize(path); err == nil {
		return snapshot, nil
	}
	cacheEntry, err := loadCacheFromDisk(path)
	if err != nil {
		return 0, err
	}
	_ = storeOverviewSize(path, cacheEntry.TotalSize)
	return cacheEntry.TotalSize, nil
}

func scanOverviewPathCmd(path string, index int) tea.Cmd {
	return func() tea.Msg {
		size, err := measureOverviewSize(path)
		return overviewSizeMsg{
			path:  path,
			index: index,
			size:  size,
			err:   err,
		}
	}
}

// measureOverviewSize calculates the size of a directory using multiple strategies:
// 1. Check JSON cache (fast)
// 2. Try mdls metadata (fast, macOS only)
// 3. Walk the directory to get logical size (matches detailed scans)
// 4. Try du command (moderate speed, physical size)
// 5. Check gob cache (fallback)
func measureOverviewSize(path string) (int64, error) {
	if path == "" {
		return 0, fmt.Errorf("empty path")
	}

	// Clean and validate path
	path = filepath.Clean(path)
	if !filepath.IsAbs(path) {
		return 0, fmt.Errorf("path must be absolute: %s", path)
	}

	if _, err := os.Stat(path); err != nil {
		return 0, fmt.Errorf("cannot access path: %v", err)
	}

	// Strategy 1: Check JSON cache
	if cached, err := loadStoredOverviewSize(path); err == nil && cached > 0 {
		return cached, nil
	}

	// Strategy 2: Try mdls (fastest, macOS only)
	if metadataSize, err := getDirectorySizeFromMetadata(path); err == nil && metadataSize > 0 {
		_ = storeOverviewSize(path, metadataSize)
		return metadataSize, nil
	}

	// Strategy 3: Fall back to a quick logical size walk so the result matches detailed scans.
	if logicalSize, err := getDirectoryLogicalSize(path); err == nil && logicalSize > 0 {
		_ = storeOverviewSize(path, logicalSize)
		return logicalSize, nil
	}

	// Strategy 4: Try du command (fast and reliable for physical size)
	if duSize, err := getDirectorySizeFromDu(path); err == nil && duSize > 0 {
		_ = storeOverviewSize(path, duSize)
		return duSize, nil
	}

	// Strategy 5: Check gob cache as fallback
	if cached, err := loadCacheFromDisk(path); err == nil {
		_ = storeOverviewSize(path, cached.TotalSize)
		return cached.TotalSize, nil
	}

	// If every shortcut fails, bubble the error so caller can display a warning.
	return 0, fmt.Errorf("unable to measure directory size with fast methods")
}

// getDirectorySizeFromMetadata attempts to retrieve directory size using macOS Spotlight metadata.
// This is much faster than filesystem traversal but may not be available for all directories.
func getDirectorySizeFromMetadata(path string) (int64, error) {
	// mdls only works on directories
	info, err := os.Stat(path)
	if err != nil {
		return 0, fmt.Errorf("cannot stat path: %v", err)
	}
	if !info.IsDir() {
		return 0, fmt.Errorf("not a directory")
	}

	ctx, cancel := context.WithTimeout(context.Background(), mdlsTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "mdls", "-raw", "-name", "kMDItemFSSize", path)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return 0, fmt.Errorf("mdls timeout after %v", mdlsTimeout)
		}
		if stderr.Len() > 0 {
			return 0, fmt.Errorf("mdls failed: %v (%s)", err, stderr.String())
		}
		return 0, fmt.Errorf("mdls failed: %v", err)
	}
	value := strings.TrimSpace(stdout.String())
	if value == "" || value == "(null)" {
		return 0, fmt.Errorf("metadata size unavailable")
	}
	size, err := strconv.ParseInt(value, 10, 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse mdls output: %v", err)
	}
	if size <= 0 {
		return 0, fmt.Errorf("mdls size invalid: %d", size)
	}
	return size, nil
}

// getDirectorySizeFromDu calculates directory size using the du command.
// Uses -d 0 to avoid recursing into subdirectories, and includes a timeout protection.
func getDirectorySizeFromDu(path string) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), duTimeout)
	defer cancel()

	cmd := exec.CommandContext(ctx, "du", "-sk", "-d", "0", path)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr

	if err := cmd.Run(); err != nil {
		if ctx.Err() == context.DeadlineExceeded {
			return 0, fmt.Errorf("du timeout after %v", duTimeout)
		}
		if stderr.Len() > 0 {
			return 0, fmt.Errorf("du failed: %v (%s)", err, stderr.String())
		}
		return 0, fmt.Errorf("du failed: %v", err)
	}
	fields := strings.Fields(stdout.String())
	if len(fields) == 0 {
		return 0, fmt.Errorf("du output empty")
	}
	kb, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0, fmt.Errorf("failed to parse du output: %v", err)
	}
	if kb <= 0 {
		return 0, fmt.Errorf("du size invalid: %d", kb)
	}
	return kb * 1024, nil
}

// getDirectoryLogicalSize walks the directory tree and sums file sizes to estimate
// the logical (Finder-style) usage.
func getDirectoryLogicalSize(path string) (int64, error) {
	var total int64
	err := filepath.WalkDir(path, func(p string, d fs.DirEntry, err error) error {
		if err != nil {
			if os.IsPermission(err) {
				return filepath.SkipDir
			}
			return nil
		}
		if d.IsDir() {
			return nil
		}
		info, err := d.Info()
		if err != nil {
			return nil
		}
		total += info.Size()
		return nil
	})
	if err != nil && err != filepath.SkipDir {
		return 0, err
	}
	return total, nil
}

func snapshotFromModel(m model) historyEntry {
	return historyEntry{
		path:          m.path,
		entries:       cloneDirEntries(m.entries),
		largeFiles:    cloneFileEntries(m.largeFiles),
		totalSize:     m.totalSize,
		selected:      m.selected,
		entryOffset:   m.offset,
		largeSelected: m.largeSelected,
		largeOffset:   m.largeOffset,
	}
}

func cacheSnapshot(m model) historyEntry {
	entry := snapshotFromModel(m)
	entry.dirty = false
	return entry
}

// Persistent cache functions
func getCacheDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	cacheDir := filepath.Join(home, ".cache", "mole")
	if err := os.MkdirAll(cacheDir, 0755); err != nil {
		return "", err
	}
	return cacheDir, nil
}

func getCachePath(path string) (string, error) {
	cacheDir, err := getCacheDir()
	if err != nil {
		return "", err
	}
	// Use xxhash (faster than MD5) of path as cache filename
	hash := xxhash.Sum64String(path)
	filename := fmt.Sprintf("%x.cache", hash)
	return filepath.Join(cacheDir, filename), nil
}

func loadCacheFromDisk(path string) (*cacheEntry, error) {
	cachePath, err := getCachePath(path)
	if err != nil {
		return nil, err
	}

	file, err := os.Open(cachePath)
	if err != nil {
		return nil, err
	}
	defer file.Close()

	var entry cacheEntry
	decoder := gob.NewDecoder(file)
	if err := decoder.Decode(&entry); err != nil {
		return nil, err
	}

	// Validate cache: check if directory was modified after cache creation
	info, err := os.Stat(path)
	if err != nil {
		return nil, err
	}

	// If directory was modified after cache, invalidate
	if info.ModTime().After(entry.ModTime) {
		return nil, fmt.Errorf("cache expired: directory modified")
	}

	// If cache is older than 7 days, invalidate
	if time.Since(entry.ScanTime) > 7*24*time.Hour {
		return nil, fmt.Errorf("cache expired: too old")
	}

	return &entry, nil
}

func saveCacheToDisk(path string, result scanResult) error {
	cachePath, err := getCachePath(path)
	if err != nil {
		return err
	}

	info, err := os.Stat(path)
	if err != nil {
		return err
	}

	entry := cacheEntry{
		Entries:    result.entries,
		LargeFiles: result.largeFiles,
		TotalSize:  result.totalSize,
		ModTime:    info.ModTime(),
		ScanTime:   time.Now(),
	}

	file, err := os.Create(cachePath)
	if err != nil {
		return err
	}
	defer file.Close()

	encoder := gob.NewEncoder(file)
	return encoder.Encode(entry)
}

// getLastAccessTime returns the last access time of a file or directory (macOS only)
func getLastAccessTime(path string) time.Time {
	info, err := os.Stat(path)
	if err != nil {
		return time.Time{}
	}

	// Use syscall to get atime on macOS
	stat, ok := info.Sys().(*syscall.Stat_t)
	if !ok {
		return time.Time{}
	}

	// macOS Darwin stores atime in Atimespec
	// This is guaranteed to exist on macOS due to build tag
	return time.Unix(stat.Atimespec.Sec, stat.Atimespec.Nsec)
}

// formatUnusedTime formats the time since last access in a compact way
func formatUnusedTime(lastAccess time.Time) string {
	if lastAccess.IsZero() {
		return ""
	}

	duration := time.Since(lastAccess)
	days := int(duration.Hours() / 24)

	// Only show if unused for more than 3 months
	if days < 90 {
		return ""
	}

	months := days / 30
	years := days / 365

	if years >= 2 {
		return fmt.Sprintf(">%dyr", years)
	} else if years >= 1 {
		return ">1yr"
	} else if months >= 3 {
		return fmt.Sprintf(">%dmo", months)
	}

	return ""
}
