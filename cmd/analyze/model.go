//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"slices"
	"sort"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
)

// scanState describes measurement coverage within Mole's scan filters, not an
// atomic filesystem snapshot. The zero value represents a complete measurement.
type scanState uint8

const (
	scanComplete scanState = iota
	scanPartial
	scanUnavailable
)

func (s scanState) String() string {
	switch s {
	case scanPartial:
		return "partial"
	case scanUnavailable:
		return "unavailable"
	case scanComplete:
		return "complete"
	default:
		return "unknown"
	}
}

// MarshalText gives the existing JSON boundary the same typed coverage state.
func (s scanState) MarshalText() ([]byte, error) {
	if s > scanUnavailable {
		return nil, fmt.Errorf("invalid scan state: %d", s)
	}
	return []byte(s.String()), nil
}

// measurementState preserves the distinction between a useful partial size and
// a failed probe that measured nothing. Callers must retain the returned bytes.
func measurementState(size int64, err error) scanState {
	if err == nil {
		return scanComplete
	}
	if size > 0 {
		return scanPartial
	}
	return scanUnavailable
}

// isPermissionFailure reports a denial macOS will repeat on every scan until
// access changes (no Full Disk Access, chmod 000), so a partial result caused
// only by these is as current as a complete one. Everything else (timeouts,
// cancellation, vanished files, I/O errors) may clear on the next attempt.
func isPermissionFailure(err error) bool {
	return err != nil && (errors.Is(err, fs.ErrPermission) || errors.Is(err, syscall.EACCES) || errors.Is(err, syscall.EPERM))
}

func isTransientFailure(err error) bool {
	return err != nil && !isPermissionFailure(err)
}

type dirEntry struct {
	State      scanState
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
	State      scanState
	Entries    []dirEntry
	LargeFiles []fileEntry
	TotalSize  int64
	TotalFiles int64
	// dedupedHardlink is true when a hardlinked file in this subtree was
	// counted as zero because another link was seen earlier in the same
	// scan. Such a result is scan-order dependent and must not be written
	// to the on-disk cache. In-memory only; never serialized to cacheEntry.
	dedupedHardlink bool
	// transientFailure is true when some coverage was lost to a failure that
	// may not recur (see isPermissionFailure). Such a partial result is never
	// persisted and is always refreshed; a partial result lost only to
	// permission denials is kept like a complete one. In-memory only.
	transientFailure bool
}

// persistable reports whether the result may be reused without a rescan.
func (r scanResult) persistable() bool {
	return r.State == scanComplete || (r.State == scanPartial && !r.transientFailure)
}

type cacheEntry struct {
	State        scanState
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
	State         scanState
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

type liveScanStartMsg struct {
	state         scanState
	id            int64
	path          string
	entries       []dirEntry
	totalSize     int64
	totalFiles    int64
	largeFiles    []fileEntry
	scanningPaths []string
	events        <-chan liveScanEventMsg
	cancel        context.CancelFunc
	err           error
}

type liveScanEventKind int

const (
	liveScanChildProgress liveScanEventKind = iota + 1
	liveScanChildDone
	liveScanComplete
	liveScanFailed
)

type liveScanEventMsg struct {
	id     int64
	path   string
	kind   liveScanEventKind
	entry  dirEntry
	result scanResult
	err    error
}

type liveSortMode int

const (
	liveSortContinuous liveSortMode = iota
	liveSortFreezeOnMove
)

type overviewSizeMsg struct {
	publication *scanPublication
	Path        string
	Index       int
	Size        int64
	Err         error
}

type initializeMsg struct{}

type tickMsg time.Time

type deleteProgressMsg struct {
	done         bool
	err          error
	count        int64
	path         string
	removedPaths []string
}

type model struct {
	scanState           scanState
	scanTransient       bool // scanState != scanComplete because of a transient failure
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
	tickRunning         bool // one tickCmd loop is already re-arming itself
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
	overviewScanningSet map[string]*scanPublication // Track active measurements by identity
	cachePublications   map[string]*scanPublication
	width               int             // Terminal width
	height              int             // Terminal height
	multiSelected       map[string]bool // Track multi-selected items by path (safer than index)
	largeMultiSelected  map[string]bool // Track multi-selected large files by path (safer than index)
	totalFiles          int64           // Total files found in current/last scan
	lastTotalFiles      int64           // Total files from previous scan (for progress bar)
	diskFree            int64           // Free disk space for the analyzed volume
	localSnapshotCount  int             // Read-only Time Machine snapshot count for overview context
	localSnapshotFresh  bool            // False after the latest matching probe failed
	snapshotProbeID     int64
	snapshotRunner      localSnapshotCommandRunner
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
	entriesAll          []dirEntry
	entryFilter         string
	entryFiltering      bool
	liveScanID          int64
	liveScanCancel      context.CancelFunc
	liveScanEvents      <-chan liveScanEventMsg
	liveScanningPaths   map[string]bool
	autoSortLiveEntries bool
	liveSortMode        liveSortMode
}

func (m model) inOverviewMode() bool {
	return m.isOverview && m.path == "/"
}

func entryScanState(entries []dirEntry) scanState {
	for _, entry := range entries {
		if entry.Size < 0 || entry.State != scanComplete {
			return scanPartial
		}
	}
	return scanComplete
}

// selectedEntryMeasurement is shared by selection feedback and confirmation.
func (m model) selectedEntryMeasurement() (int64, scanState) {
	var size int64
	state := scanComplete
	for _, entry := range m.entries {
		if !m.multiSelected[entry.Path] {
			continue
		}
		size += max(entry.Size, 0)
		if entry.Size < 0 || entry.State != scanComplete {
			state = scanPartial
		}
	}
	return size, state
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
		if size, state, err := loadOverviewCachedMeasurement(m.entries[i].Path); err == nil {
			m.entries[i].Size = size
			m.entries[i].State = state
			// The in-memory map holds sizes only, so it keeps complete ones.
			if state == scanComplete {
				m.overviewSizeCache[m.entries[i].Path] = size
			}
		}
	}
	m.totalSize = sumKnownEntrySizes(m.entries)
	m.scanState = entryScanState(m.entries)
	m.scanTransient = false
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

// pathIsWithin reports whether path is root or lies below it. A bare
// root+"/" prefix never matches for the overview, whose path is "/": the
// prefix becomes "//".
func pathIsWithin(path, root string) bool {
	if path == root {
		return true
	}
	prefix := root
	if !strings.HasSuffix(prefix, "/") {
		prefix += "/"
	}
	return strings.HasPrefix(path, prefix)
}

// pathTouchesRemoved reports whether a delete changed what path measures: it
// contains a removed path, or was itself inside one.
func pathTouchesRemoved(path string, removedPaths []string) bool {
	return slices.ContainsFunc(removedPaths, func(removed string) bool {
		return pathIsWithin(removed, path) || pathIsWithin(path, removed)
	})
}

// markRemovedOverviewRowsPending resets the overview rows a delete changed to
// pending so they are measured again instead of restored.
func markRemovedOverviewRowsPending(entries []dirEntry, removedPaths []string) {
	for i := range entries {
		if pathTouchesRemoved(entries[i].Path, removedPaths) {
			entries[i].Size = -1
			entries[i].State = scanComplete
		}
	}
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
