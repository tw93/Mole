//go:build darwin

package main

import (
	"sort"
	"strings"
	"sync/atomic"
	"time"
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
	// dedupedHardlink is true when a hardlinked file in this subtree was
	// counted as zero because another link was seen earlier in the same
	// scan. Such a result is scan-order dependent and must not be written
	// to the on-disk cache. In-memory only; never serialized to cacheEntry.
	dedupedHardlink bool
}

type cacheEntry struct {
	Entries      []dirEntry
	LargeFiles   []fileEntry
	TotalSize    int64
	TotalFiles   int64
	ModTime      time.Time
	ScanTime     time.Time
	NeedsRefresh bool
	// SchemaVersion guards against reusing cache written by an older binary
	// with different sizing semantics. Entries not at cacheSchemaVersion are
	// rejected on load. Old caches decode this as 0.
	SchemaVersion int
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
	path                string
	history             []historyEntry
	entries             []dirEntry
	largeFiles          []fileEntry
	selected            int
	offset              int
	status              string
	totalSize           int64
	scanning            bool
	spinner             int
	filesScanned        *int64
	dirsScanned         *int64
	bytesScanned        *int64
	currentPath         *atomic.Value
	showLargeFiles      bool
	isOverview          bool
	deleteConfirm       bool
	deleteTarget        *dirEntry
	deleting            bool
	deleteCount         *int64
	cache               map[string]historyEntry
	largeSelected       int
	largeOffset         int
	overviewSizeCache   map[string]int64
	overviewScanning    bool
	overviewScanningSet map[string]bool // Track which paths are currently being scanned
	width               int             // Terminal width
	height              int             // Terminal height
	multiSelected       map[string]bool // Track multi-selected items by path (safer than index)
	largeMultiSelected  map[string]bool // Track multi-selected large files by path (safer than index)
	totalFiles          int64           // Total files found in current/last scan
	lastTotalFiles      int64           // Total files from previous scan (for progress bar)
	diskFree            int64           // Free disk space for the analyzed volume
	viewNeedsRefresh    bool
	// Top-files (T) view incremental filter. largeFilesAll is the full,
	// size-ranked list; largeFiles is the view actually rendered and acted on,
	// which equals largeFilesAll when no filter is set and the matching subset
	// otherwise. largeFiltering is true only while the user is typing a query.
	largeFilesAll  []fileEntry
	largeFilter    string
	largeFiltering bool
	// Directory (drill-down) view incremental filter, mirroring the Top-files
	// one. entriesAll is the full non-empty entry list; entries is the rendered,
	// possibly filtered view. Disabled in overview mode.
	entriesAll     []dirEntry
	entryFilter    string
	entryFiltering bool
}

func (m model) inOverviewMode() bool {
	return m.isOverview && m.path == "/"
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

func (m *model) removePathFromView(path string) {
	if path == "" {
		return
	}

	var removedSize int64
	for _, entry := range m.entriesAll {
		if entry.Path == path {
			if entry.Size > 0 {
				removedSize = entry.Size
			}
			break
		}
	}

	// Trim the backing lists once, then rebuild each view from them. Removing
	// directly from both a backing list and its (possibly aliased) view would
	// shift the shared array twice and corrupt it; rebuilding via the filters
	// keeps the view, the query, and the selection consistent.
	m.entriesAll = removeByPath(m.entriesAll, path, dirEntryPath)
	m.largeFilesAll = removeByPath(m.largeFilesAll, path, fileEntryPath)

	if removedSize > 0 {
		if removedSize > m.totalSize {
			m.totalSize = 0
		} else {
			m.totalSize -= removedSize
		}
	}

	m.applyEntryFilter()
	m.applyLargeFilter()
}

func fileEntryName(f fileEntry) string { return f.Name }
func fileEntryPath(f fileEntry) string { return f.Path }
func dirEntryName(e dirEntry) string   { return e.Name }
func dirEntryPath(e dirEntry) string   { return e.Path }

// filterMatches reports whether an item with the given name and path matches a
// case-insensitive substring query. Single source of truth for both the
// Top-files and directory filters so their match semantics cannot drift.
func filterMatches(name, path, query string) bool {
	needle := strings.ToLower(query)
	return strings.Contains(strings.ToLower(name), needle) ||
		strings.Contains(strings.ToLower(displayPath(path)), needle)
}

// filterByQuery returns the items matching query, or the original slice
// unchanged when the query is empty. nameOf/pathOf project the fields matched.
func filterByQuery[T any](all []T, query string, nameOf, pathOf func(T) string) []T {
	if query == "" {
		return all
	}
	out := make([]T, 0, len(all))
	for _, item := range all {
		if filterMatches(nameOf(item), pathOf(item), query) {
			out = append(out, item)
		}
	}
	return out
}

// removeByPath drops the first item whose projected path equals path.
func removeByPath[T any](items []T, path string, pathOf func(T) string) []T {
	for i := range items {
		if pathOf(items[i]) == path {
			return append(items[:i], items[i+1:]...)
		}
	}
	return items
}

// applyLargeFilter rebuilds the rendered Top-files view from largeFilesAll
// using the current query. An empty query restores the full list.
func (m *model) applyLargeFilter() {
	m.largeFiles = filterByQuery(m.largeFilesAll, m.largeFilter, fileEntryName, fileEntryPath)
	m.clampLargeSelection()
}

// resetLargeFilter clears any active Top-files filter and restores the full
// list. Callers that leave the Top-files view use this so the next visit and
// the per-path navigation state start clean.
func (m *model) resetLargeFilter() {
	m.largeFilter = ""
	m.largeFiltering = false
	if m.largeFilesAll != nil {
		m.largeFiles = m.largeFilesAll
	}
}

// applyEntryFilter rebuilds the rendered directory view from entriesAll using
// the current query. The directory view is the drill-down list (m.entries) in
// non-overview mode.
func (m *model) applyEntryFilter() {
	m.entries = filterByQuery(m.entriesAll, m.entryFilter, dirEntryName, dirEntryPath)
	m.clampEntrySelection()
}

// resetEntryFilter clears any active directory filter and restores the full
// entry list.
func (m *model) resetEntryFilter() {
	m.entryFilter = ""
	m.entryFiltering = false
	if m.entriesAll != nil {
		m.entries = m.entriesAll
	}
}
