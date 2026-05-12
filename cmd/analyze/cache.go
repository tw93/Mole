//go:build darwin

package main

import (
	"context"
	"encoding/gob"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sync"
	"time"

	"github.com/cespare/xxhash/v2"
)

type overviewSizeSnapshot struct {
	Size    int64     `json:"size"`
	Updated time.Time `json:"updated"`
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
		NeedsRefresh:  m.viewNeedsRefresh,
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
		Dirty:         false,
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

func getCacheDir() (string, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return "", err
	}
	cacheDir := filepath.Join(home, ".cache", "roomy")
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
	hash := xxhash.Sum64String(path)
	filename := fmt.Sprintf("%x.cache", hash)
	return filepath.Join(cacheDir, filename), nil
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
		return nil, err
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
		return nil, err
	}

	scanAge := time.Since(entry.ScanTime)
	if scanAge > 7*24*time.Hour {
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
		return nil, err
	}

	if time.Since(entry.ScanTime) > staleCacheTTL {
		return nil, fmt.Errorf("stale cache expired")
	}

	return entry, nil
}

func saveCacheToDisk(path string, result scanResult) error {
	return saveCacheToDiskWithOptions(path, result, false)
}

func saveCacheToDiskWithOptions(path string, result scanResult, needsRefresh bool) error {
	cachePath, err := getCachePath(path)
	if err != nil {
		return err
	}

	info, err := os.Stat(path)
	if err != nil {
		return err
	}

	entry := cacheEntry{
		Entries:      result.Entries,
		LargeFiles:   result.LargeFiles,
		TotalSize:    result.TotalSize,
		TotalFiles:   result.TotalFiles,
		ModTime:      info.ModTime(),
		ScanTime:     time.Now(),
		NeedsRefresh: needsRefresh,
	}

	file, err := os.Create(cachePath)
	if err != nil {
		return err
	}
	defer file.Close() //nolint:errcheck

	encoder := gob.NewEncoder(file)
	return encoder.Encode(entry)
}

// peekCacheTotalFiles attempts to read the total file count from cache,
// ignoring expiration. Used for initial scan progress estimates.
func peekCacheTotalFiles(path string) (int64, error) {
	cachePath, err := getCachePath(path)
	if err != nil {
		return 0, err
	}

	file, err := os.Open(cachePath)
	if err != nil {
		return 0, err
	}
	defer file.Close() //nolint:errcheck

	var entry cacheEntry
	decoder := gob.NewDecoder(file)
	if err := decoder.Decode(&entry); err != nil {
		return 0, err
	}

	return entry.TotalFiles, nil
}

func invalidateCache(path string) {
	cachePath, err := getCachePath(path)
	if err == nil {
		_ = os.Remove(cachePath)
	}
	removeOverviewSnapshot(path)
}

// invalidateCacheTree invalidates the cache for path and all its direct
// child directories so that a rescan does not reuse stale subdirectory
// sizes. See #812.
func invalidateCacheTree(path string) {
	invalidateCache(path)
	children, err := os.ReadDir(path)
	if err != nil {
		return
	}
	for _, child := range children {
		if child.IsDir() {
			invalidateCache(filepath.Join(path, child.Name()))
		}
	}
}

func removeOverviewSnapshot(path string) {
	if path == "" {
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
	if _, ok := overviewSnapshotCache[path]; ok {
		delete(overviewSnapshotCache, path)
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

		wg.Add(1)
		go func(path string) {
			defer wg.Done()
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
		}(path)
	}
	wg.Wait()
}
