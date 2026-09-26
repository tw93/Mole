//go:build darwin

package main

import (
	"container/heap"
	"context"
	"encoding/gob"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"slices"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/cespare/xxhash/v2"
)

// cacheSchemaVersion is bumped whenever directory-size semantics change so
// stale on-disk cache entries are rejected instead of silently reused.
// v2: analyze deduplicates hardlinked files to match `du`.
// v3: ordinary Parallels VM storage is included instead of skipped by name.
// v4: incomplete scans are no longer authoritative directory measurements.
const cacheSchemaVersion = 4

type overviewSizeSnapshot struct {
	Size          int64     `json:"size"`
	Updated       time.Time `json:"updated"`
	SchemaVersion int       `json:"schema_version"`
}

var (
	overviewSnapshotMu     sync.Mutex
	overviewSnapshotCache  map[string]overviewSizeSnapshot
	overviewSnapshotLoaded bool
)

func snapshotFromModel(m model) historyEntry {
	return historyEntry{
		Path:          m.path,
		Entries:       slices.Clone(m.entries),
		LargeFiles:    slices.Clone(m.largeFiles),
		TotalSize:     m.totalSize,
		TotalFiles:    m.totalFiles,
		Selected:      m.selected,
		EntryOffset:   m.offset,
		LargeSelected: m.largeSelected,
		LargeOffset:   m.largeOffset,
		NeedsRefresh:  m.viewNeedsRefresh || m.scanning,
		IsOverview:    m.isOverview,
	}
}

func filterNonEmptyEntries(entries []dirEntry) []dirEntry {
	filtered := make([]dirEntry, 0, len(entries))
	for _, entry := range entries {
		if entry.Size > 0 {
			filtered = append(filtered, entry)
		}
	}
	return filtered
}

func historyEntryFromScanResult(path string, result scanResult, previous historyEntry, needsRefresh bool) historyEntry {
	entry := historyEntry{
		Path:          path,
		Entries:       slices.Clone(result.Entries),
		LargeFiles:    slices.Clone(result.LargeFiles),
		TotalSize:     result.TotalSize,
		TotalFiles:    result.TotalFiles,
		Selected:      previous.Selected,
		EntryOffset:   previous.EntryOffset,
		LargeSelected: previous.LargeSelected,
		LargeOffset:   previous.LargeOffset,
		NeedsRefresh:  needsRefresh,
		IsOverview:    previous.IsOverview,
	}
	return entry
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
		backupPath := storePath + ".corrupt"
		_ = os.Rename(storePath, backupPath)
		overviewSnapshotCache = make(map[string]overviewSizeSnapshot)
		overviewSnapshotLoaded = true
		return nil
	}
	// Drop what the loader would refuse anyway. Snapshots were only ever added,
	// so without this every directory ever browsed stayed in the file forever,
	// and each save re-serialized all of them.
	now := time.Now()
	for path, snapshot := range snapshots {
		if snapshot.SchemaVersion != cacheSchemaVersion || snapshot.Size <= 0 || now.Sub(snapshot.Updated) >= overviewCacheTTL {
			delete(snapshots, path)
		}
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
	return filepath.Join(cacheDir, overviewCacheFile), nil
}

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
		if time.Since(snapshot.Updated) < overviewCacheTTL {
			return snapshot.Size, nil
		}
		return 0, fmt.Errorf("snapshot expired")
	}
	return 0, fmt.Errorf("snapshot not found")
}

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
	// Re-measuring a directory usually returns the size already on record, and
	// every save re-serializes and rewrites the entire store. Skip the write
	// while the recorded value still stands; the timestamp is only refreshed
	// often enough to keep a live entry from aging out.
	if existing, ok := overviewSnapshotCache[path]; ok && existing.Size == size &&
		time.Since(existing.Updated) < overviewCacheTTL/overviewRefreshDivisor {
		return nil
	}
	overviewSnapshotCache[path] = overviewSizeSnapshot{
		Size:          size,
		Updated:       time.Now(),
		SchemaVersion: cacheSchemaVersion,
	}
	evictOverviewSnapshotsLocked()
	return persistOverviewSnapshotLocked()
}

// evictOverviewSnapshotsLocked keeps the store bounded by dropping the oldest
// snapshots once it outgrows the cap, in one pass down to the low-water mark so
// eviction does not run on every subsequent save.
func evictOverviewSnapshotsLocked() {
	if len(overviewSnapshotCache) <= overviewCacheMaxEntries ||
		overviewCacheKeepEntries >= len(overviewSnapshotCache) {
		return
	}
	type agedSnapshot struct {
		path    string
		updated time.Time
	}
	aged := make([]agedSnapshot, 0, len(overviewSnapshotCache))
	for path, snapshot := range overviewSnapshotCache {
		aged = append(aged, agedSnapshot{path: path, updated: snapshot.Updated})
	}
	slices.SortFunc(aged, func(a, b agedSnapshot) int { return a.updated.Compare(b.updated) })
	for _, entry := range aged[:len(aged)-overviewCacheKeepEntries] {
		delete(overviewSnapshotCache, entry.path)
	}
}

func persistOverviewSnapshotLocked() error {
	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		return err
	}
	// No indentation: nothing reads this by eye, and the padding was a third of
	// a file rewritten on every save.
	data, err := json.Marshal(overviewSnapshotCache)
	if err != nil {
		return err
	}
	// A uniquely named temp file, so two analyzers running at once cannot land
	// in each other's half-written store.
	tmp, err := os.CreateTemp(filepath.Dir(storePath), overviewCacheFile+".*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	// Chmod through the handle, not the path: CreateTemp opens at 0600 and the
	// store has always been world-readable.
	if err := tmp.Chmod(0644); err != nil {
		tmp.Close() //nolint:errcheck
		_ = os.Remove(tmpPath)
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close() //nolint:errcheck
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	if err := os.Rename(tmpPath, storePath); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return nil
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

// moleCacheRoot is the single definition of the shared cache location; both
// accessors below build on it so the layout is stated once.
func moleCacheRoot(home string) string {
	return filepath.Join(home, ".cache", "mole")
}

// getMoleCacheRoot is the shared `~/.cache/mole` directory. The shell side
// keeps its own state files there, so nothing may be swept from it wholesale.
func getMoleCacheRoot() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	return moleCacheRoot(home), nil
}

// resolvedCacheDir memoizes the analyzer cache directory together with the HOME
// it was derived from, so a test that repoints HOME still gets a fresh answer.
type resolvedCacheDir struct {
	home string
	dir  string
	err  error
}

var cachedAnalyzerDir atomic.Pointer[resolvedCacheDir]

// getCacheDir is the analyzer-owned subdirectory. Keeping analyzer entries out
// of the shared root is what lets the legacy sweep and the entry caps operate
// on a directory whose every file the analyzer owns.
//
// The MkdirAll result is memoized because this sits on the scan hot path: every
// directory walked resolves a cache path at least once, so re-running the
// syscall per directory cost a measured 1.5us and 688B each, roughly 470ms and
// 200MB of garbage across a whole-disk scan, all to re-learn that a directory
// created moments ago still exists.
func getCacheDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	if resolved := cachedAnalyzerDir.Load(); resolved != nil && resolved.home == home {
		return resolved.dir, resolved.err
	}

	dir := filepath.Join(moleCacheRoot(home), analyzerCacheDirName)
	resolved := &resolvedCacheDir{home: home, dir: dir}
	if mkErr := os.MkdirAll(dir, 0755); mkErr != nil {
		resolved.dir, resolved.err = "", mkErr
	}
	cachedAnalyzerDir.Store(resolved)
	return resolved.dir, resolved.err
}

func getCachePath(path string) (string, error) {
	cacheDir, err := getCacheDir()
	if err != nil {
		return "", err
	}
	// Built by concatenation rather than filepath.Join: cacheDir is already
	// clean, and Join would re-Clean it on every directory scanned.
	hash := xxhash.Sum64String(path)
	var name strings.Builder
	name.Grow(len(cacheDir) + 23)
	name.WriteString(cacheDir)
	name.WriteByte(filepath.Separator)
	name.WriteString(strconv.FormatUint(hash, 16))
	name.WriteString(".cache")
	return name.String(), nil
}

// shouldPersistSubdirCache decides whether a scanned subtree earns a cache
// file. Memoizing a directory that holds a handful of files costs more than it
// saves: the entry occupies a whole 4KB block plus an inode, and reading it
// back is slower than the single readdir it replaces. Only subtrees expensive
// enough to rescan are persisted; see the budget comment in constants.go.
func shouldPersistSubdirCache(result scanResult) bool {
	return result.TotalFiles >= subdirCacheMinFiles || result.TotalSize >= subdirCacheMinSize
}

// removeCacheEntry drops a cache file that can never be useful again (its
// schema is gone, it failed to decode, its directory no longer exists, or it
// outlived the TTL). Expiring an entry only at load time used to leave the file
// on disk until a prune pass happened to reach it, which is how a store grows
// far past what any scan still reads.
//
// Deliberately not invalidateCache: that also drops the overview snapshot,
// which rewrites the whole JSON store under a lock. This runs per entry inside
// a scan, so it stays a single unlink.
func removeCacheEntry(path string) {
	if cachePath, err := getCachePath(path); err == nil {
		_ = os.Remove(cachePath)
	}
}

// cacheFileStat is the eviction record for one analyzer cache file.
type cacheFileStat struct {
	name    string
	modTime time.Time
	size    int64
}

// oldestFirstHeap is a min-heap by mod time, so the root is always the next
// entry to evict. Retaining the newest N through a bounded heap keeps prune's
// memory tied to the cap instead of to the directory it is pruning.
type oldestFirstHeap []cacheFileStat

func (h oldestFirstHeap) Len() int           { return len(h) }
func (h oldestFirstHeap) Less(i, j int) bool { return h[i].modTime.Before(h[j].modTime) }
func (h oldestFirstHeap) Swap(i, j int)      { h[i], h[j] = h[j], h[i] }
func (h *oldestFirstHeap) Push(x any)        { *h = append(*h, x.(cacheFileStat)) }
func (h *oldestFirstHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[0 : n-1]
	return x
}

func pruneAnalyzerCache() {
	// Best-effort throughout; errors are ignored so startup never blocks on
	// cache housekeeping.
	if root, err := getMoleCacheRoot(); err == nil {
		_ = sweepLegacyAnalyzerCache(root)
	}
	cacheDir, err := getCacheDir()
	if err != nil {
		return
	}
	_ = pruneAnalyzerCacheDir(cacheDir, time.Now())
}

// pruneAnalyzerCacheDir removes expired entries and then enforces the count and
// byte caps, evicting oldest first. The directory is streamed in batches rather
// than read whole: os.ReadDir buffers and sorts every name, which is exactly
// what an oversized store cannot afford.
func pruneAnalyzerCacheDir(cacheDir string, now time.Time) error {
	return pruneAnalyzerCacheDirWithLimits(cacheDir, now, analyzerCacheMaxEntries, analyzerCacheMaxBytes)
}

// maxEntries must stay positive: it is what bounds the retained heap, and with
// it the memory this pass needs. A non-positive maxBytes just disables the byte
// cap.
func pruneAnalyzerCacheDirWithLimits(cacheDir string, now time.Time, maxEntries int, maxBytes int64) error {
	if cacheDir == "" || analyzerCacheTTL <= 0 {
		return nil
	}

	dir, err := os.Open(cacheDir)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer dir.Close() //nolint:errcheck

	cutoff := now.Add(-analyzerCacheTTL)
	retained := &oldestFirstHeap{}
	var retainedBytes int64

	evictOldest := func() {
		if retained.Len() == 0 {
			return
		}
		oldest := heap.Pop(retained).(cacheFileStat)
		retainedBytes -= oldest.size
		_ = os.Remove(filepath.Join(cacheDir, oldest.name))
	}

	tempCutoff := now.Add(-staleTempFileTTL)
	for {
		entries, readErr := dir.ReadDir(cacheDirReadBatch)
		for _, entry := range entries {
			if entry.Type()&os.ModeSymlink != 0 {
				continue
			}
			// Atomic saves stage through temp files. One only outlives its
			// write by milliseconds, so anything older is debris from a killed
			// process, and nothing else in this pass would ever collect it.
			if filepath.Ext(entry.Name()) == ".tmp" {
				if info, infoErr := entry.Info(); infoErr == nil &&
					info.Mode().IsRegular() && !info.ModTime().After(tempCutoff) {
					_ = os.Remove(filepath.Join(cacheDir, entry.Name()))
				}
				continue
			}
			if filepath.Ext(entry.Name()) != ".cache" {
				continue
			}

			info, infoErr := entry.Info()
			if infoErr != nil || !info.Mode().IsRegular() {
				continue
			}
			if !info.ModTime().After(cutoff) {
				_ = os.Remove(filepath.Join(cacheDir, entry.Name()))
				continue
			}

			heap.Push(retained, cacheFileStat{
				name:    entry.Name(),
				modTime: info.ModTime(),
				size:    info.Size(),
			})
			retainedBytes += info.Size()
			if maxEntries > 0 && retained.Len() > maxEntries {
				evictOldest()
			}
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				break
			}
			return readErr
		}
		if len(entries) == 0 {
			break
		}
	}

	for maxBytes > 0 && retained.Len() > 0 && retainedBytes > maxBytes {
		evictOldest()
	}

	return nil
}

// sweepLegacyAnalyzerCache removes the flat `<hash>.cache` entries the analyzer
// used to write directly into `~/.cache/mole`, plus the overview snapshot that
// sat beside them. Everything else in that directory belongs to the shell side
// and is left alone.
//
// The sweep streams the directory rather than reading it whole, so a legacy
// store with millions of entries is never held in memory, and it is resumable:
// whatever a short-lived process does not reach is picked up by the next run.
// Unlinks are spread over a few workers because a single one clears roughly
// 7k files/s on APFS, which is a long tail on the largest stores seen in the
// wild (1.88M files); the small pool roughly doubles that without turning
// housekeeping into a competitor for the scan itself.
func sweepLegacyAnalyzerCache(root string) error {
	if root == "" {
		return nil
	}

	dir, err := os.Open(root)
	if err != nil {
		if os.IsNotExist(err) {
			return nil
		}
		return err
	}
	defer dir.Close() //nolint:errcheck

	names := make(chan string, cacheDirReadBatch)
	var workers sync.WaitGroup
	for range legacySweepWorkers {
		workers.Go(func() {
			for name := range names {
				_ = os.Remove(filepath.Join(root, name))
			}
		})
	}
	defer func() {
		close(names)
		workers.Wait()
	}()

	for {
		entries, readErr := dir.ReadDir(cacheDirReadBatch)
		for _, entry := range entries {
			if !entry.Type().IsRegular() {
				continue
			}
			if filepath.Ext(entry.Name()) != ".cache" && entry.Name() != overviewCacheFile {
				continue
			}
			names <- entry.Name()
		}
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
		if len(entries) == 0 {
			return nil
		}
	}
}

func loadRawCacheFromDisk(path string) (*cacheEntry, error) {
	cachePath, err := getCachePath(path)
	if err != nil {
		return nil, err
	}

	file, err := os.Open(cachePath)
	if err != nil {
		return nil, err
	}
	defer file.Close() //nolint:errcheck

	var entry cacheEntry
	decoder := gob.NewDecoder(file)
	if err := decoder.Decode(&entry); err != nil {
		// A truncated or foreign payload will never decode; keeping it only
		// costs a block until some prune pass reaches it.
		_ = os.Remove(cachePath)
		return nil, err
	}

	if entry.SchemaVersion != cacheSchemaVersion {
		_ = os.Remove(cachePath)
		return nil, fmt.Errorf("cache schema mismatch: got %d, want %d", entry.SchemaVersion, cacheSchemaVersion)
	}

	return &entry, nil
}

func loadCacheFromDisk(path string) (*cacheEntry, error) {
	entry, err := loadRawCacheFromDisk(path)
	if err != nil {
		return nil, err
	}

	info, err := os.Stat(path)
	if err != nil {
		// The directory is gone, so nothing will ever refresh or reuse this
		// entry. Churn-heavy trees (node_modules, simulator data) otherwise
		// leave one orphan per directory behind for a full TTL.
		if os.IsNotExist(err) {
			removeCacheEntry(path)
		}
		return nil, err
	}

	scanAge := time.Since(entry.ScanTime)
	if scanAge > analyzerCacheTTL {
		removeCacheEntry(path)
		return nil, fmt.Errorf("cache expired: too old")
	}

	if info.ModTime().After(entry.ModTime) {
		// Allow grace window.
		if cacheModTimeGrace <= 0 || info.ModTime().Sub(entry.ModTime) > cacheModTimeGrace {
			// Directory mod time is noisy on macOS; reuse recent cache to avoid
			// frequent full rescans while still forcing refresh for older entries.
			if cacheReuseWindow <= 0 || scanAge > cacheReuseWindow {
				return nil, fmt.Errorf("cache expired: directory modified")
			}
		}
	}

	return entry, nil
}

// loadStaleCacheFromDisk loads cache without strict freshness checks.
// It is used for fast first paint before triggering a background refresh.
func loadStaleCacheFromDisk(path string) (*cacheEntry, error) {
	entry, err := loadRawCacheFromDisk(path)
	if err != nil {
		return nil, err
	}

	if _, err := os.Stat(path); err != nil {
		if os.IsNotExist(err) {
			removeCacheEntry(path)
		}
		return nil, err
	}

	// Only the authoritative TTL deletes: staleCacheTTL is the shorter
	// first-paint window, and an entry past it is still valid for a full scan.
	if time.Since(entry.ScanTime) > staleCacheTTL {
		return nil, fmt.Errorf("stale cache expired")
	}

	return entry, nil
}

func saveCacheToDisk(path string, result scanResult) error {
	ctx := context.Background()
	return saveCacheToDiskWithOptions(newScanPublication(ctx, nil), path, result, false)
}

func saveCacheToDiskWithOptions(publication *scanPublication, path string, result scanResult, needsRefresh bool) error {
	if result.State != scanComplete {
		return nil
	}
	if err := publication.ctx.Err(); err != nil {
		return err
	}
	cachePath, err := getCachePath(path)
	if err != nil {
		return err
	}

	info, err := os.Stat(path)
	if err != nil {
		return err
	}

	entry := cacheEntry{
		Entries:       result.Entries,
		LargeFiles:    result.LargeFiles,
		TotalSize:     result.TotalSize,
		TotalFiles:    result.TotalFiles,
		ModTime:       info.ModTime(),
		ScanTime:      time.Now(),
		NeedsRefresh:  needsRefresh,
		SchemaVersion: cacheSchemaVersion,
	}

	// Written through a temp file so a kill mid-encode cannot leave a truncated
	// entry in place of a good one, and so two analyzers scanning the same tree
	// never interleave into one file.
	tmp, err := os.CreateTemp(filepath.Dir(cachePath), "entry-*.tmp")
	if err != nil {
		return err
	}
	tmpPath := tmp.Name()
	if err := tmp.Chmod(0644); err != nil {
		tmp.Close() //nolint:errcheck
		_ = os.Remove(tmpPath)
		return err
	}
	if err := gob.NewEncoder(tmp).Encode(entry); err != nil {
		tmp.Close() //nolint:errcheck
		_ = os.Remove(tmpPath)
		return err
	}
	if err := tmp.Close(); err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	err = publication.commit(func() error {
		return os.Rename(tmpPath, cachePath)
	})
	if err != nil {
		_ = os.Remove(tmpPath)
		return err
	}
	return nil
}

func removeCacheEntryForScan(publication *scanPublication, path string) error {
	return publication.commit(func() error {
		removeCacheEntry(path)
		return nil
	})
}

// peekCacheTotalFiles reads the total file count from cache, ignoring
// expiration, for initial scan progress estimates. It shares
// loadRawCacheFromDisk so a schema-stale or corrupt entry is rejected and
// cleaned up here too rather than feeding an estimate no scan would accept.
func peekCacheTotalFiles(path string) (int64, error) {
	entry, err := loadRawCacheFromDisk(path)
	if err != nil {
		return 0, err
	}
	return entry.TotalFiles, nil
}

func invalidateCache(path string) {
	removeCacheEntry(path)
	removeOverviewSnapshots(path)
}

// invalidateCacheTree invalidates the cache for path and all its direct
// child directories so that a rescan does not reuse stale subdirectory
// sizes. See #812.
func invalidateCacheTree(path string) {
	paths := []string{path}
	if children, err := os.ReadDir(path); err == nil {
		for _, child := range children {
			if child.IsDir() {
				paths = append(paths, filepath.Join(path, child.Name()))
			}
		}
	}
	for _, target := range paths {
		removeCacheEntry(target)
	}
	// One snapshot save for the whole tree: dropping them one at a time
	// rewrote the entire overview store once per child directory.
	removeOverviewSnapshots(paths...)
}

func removeOverviewSnapshots(paths ...string) {
	if len(paths) == 0 {
		return
	}
	overviewSnapshotMu.Lock()
	defer overviewSnapshotMu.Unlock()
	if err := ensureOverviewSnapshotCacheLocked(); err != nil {
		return
	}
	if overviewSnapshotCache == nil {
		return
	}
	removed := false
	for _, path := range paths {
		if path == "" {
			continue
		}
		if _, ok := overviewSnapshotCache[path]; ok {
			delete(overviewSnapshotCache, path)
			removed = true
		}
	}
	if removed {
		_ = persistOverviewSnapshotLocked()
	}
}

// prefetchOverviewCache warms overview cache in background.
func prefetchOverviewCache(ctx context.Context) {
	entries := createOverviewEntries()

	var needScan []string
	for _, entry := range entries {
		if size, err := loadStoredOverviewSize(entry.Path); err == nil && size > 0 {
			continue
		}
		needScan = append(needScan, entry.Path)
	}

	if len(needScan) == 0 {
		return
	}

	sem := make(chan struct{}, maxConcurrentOverview)
	var wg sync.WaitGroup
	for _, path := range needScan {
		select {
		case <-ctx.Done():
			wg.Wait()
			return
		default:
		}

		wg.Go(func() {
			select {
			case sem <- struct{}{}:
				defer func() { <-sem }()
			case <-ctx.Done():
				return
			}

			size, err := measureOverviewSize(path)
			if err == nil && size > 0 {
				_ = storeOverviewSize(path, size)
			}
		})
	}
	wg.Wait()
}
