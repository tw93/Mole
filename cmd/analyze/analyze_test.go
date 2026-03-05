package main

import (
	"encoding/gob"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func resetOverviewSnapshotForTest() {
	overviewSnapshotMu.Lock()
	overviewSnapshotCache = nil
	overviewSnapshotLoaded = false
	overviewSnapshotMu.Unlock()
}

func TestScanPathConcurrentBasic(t *testing.T) {
	root := t.TempDir()

	rootFile := filepath.Join(root, "root.txt")
	if err := os.WriteFile(rootFile, []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root file: %v", err)
	}

	nested := filepath.Join(root, "nested")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("create nested dir: %v", err)
	}

	fileOne := filepath.Join(nested, "a.bin")
	if err := os.WriteFile(fileOne, []byte("alpha"), 0o644); err != nil {
		t.Fatalf("write file one: %v", err)
	}
	fileTwo := filepath.Join(nested, "b.bin")
	if err := os.WriteFile(fileTwo, []byte(strings.Repeat("b", 32)), 0o644); err != nil {
		t.Fatalf("write file two: %v", err)
	}

	linkPath := filepath.Join(root, "link-to-a")
	if err := os.Symlink(fileOne, linkPath); err != nil {
		t.Fatalf("create symlink: %v", err)
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	result, err := scanPathConcurrent(root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent returned error: %v", err)
	}

	linkInfo, err := os.Lstat(linkPath)
	if err != nil {
		t.Fatalf("stat symlink: %v", err)
	}

	expectedDirSize := int64(len("alpha") + len(strings.Repeat("b", 32)))
	expectedRootFileSize := int64(len("root-data"))
	expectedLinkSize := getActualFileSize(linkPath, linkInfo)
	expectedTotal := expectedDirSize + expectedRootFileSize + expectedLinkSize

	if result.TotalSize != expectedTotal {
		t.Fatalf("expected total size %d, got %d", expectedTotal, result.TotalSize)
	}

	if got := atomic.LoadInt64(&filesScanned); got != 3 {
		t.Fatalf("expected 3 files scanned, got %d", got)
	}
	if dirs := atomic.LoadInt64(&dirsScanned); dirs == 0 {
		t.Fatalf("expected directory scan count to increase")
	}
	if bytes := atomic.LoadInt64(&bytesScanned); bytes == 0 {
		t.Fatalf("expected byte counter to increase")
	}
	foundSymlink := false
	for _, entry := range result.Entries {
		if strings.HasSuffix(entry.Name, " →") {
			foundSymlink = true
			if entry.IsDir {
				t.Fatalf("symlink entry should not be marked as directory")
			}
		}
	}
	if !foundSymlink {
		t.Fatalf("expected symlink entry to be present in scan result")
	}
}

func TestDeletePathWithProgress(t *testing.T) {
	skipIfFinderUnavailable(t)

	parent := t.TempDir()
	target := filepath.Join(parent, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	files := []string{
		filepath.Join(target, "one.txt"),
		filepath.Join(target, "two.txt"),
	}
	for _, f := range files {
		if err := os.WriteFile(f, []byte("content"), 0o644); err != nil {
			t.Fatalf("write %s: %v", f, err)
		}
	}

	var counter int64
	count, err := trashPathWithProgress(target, &counter)
	if err != nil {
		t.Fatalf("trashPathWithProgress returned error: %v", err)
	}
	if count != int64(len(files)) {
		t.Fatalf("expected %d files trashed, got %d", len(files), count)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("expected target to be moved to Trash, stat err=%v", err)
	}
}

func TestOverviewStoreAndLoad(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	path := filepath.Join(home, "project")
	want := int64(123456)

	if err := storeOverviewSize(path, want); err != nil {
		t.Fatalf("storeOverviewSize: %v", err)
	}

	got, err := loadStoredOverviewSize(path)
	if err != nil {
		t.Fatalf("loadStoredOverviewSize: %v", err)
	}
	if got != want {
		t.Fatalf("snapshot mismatch: want %d, got %d", want, got)
	}

	// Reload from disk and ensure value persists.
	resetOverviewSnapshotForTest()
	got, err = loadStoredOverviewSize(path)
	if err != nil {
		t.Fatalf("loadStoredOverviewSize after reset: %v", err)
	}
	if got != want {
		t.Fatalf("snapshot mismatch after reset: want %d, got %d", want, got)
	}
}

func TestCacheSaveLoadRoundTrip(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "cache-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target dir: %v", err)
	}

	result := scanResult{
		Entries: []dirEntry{
			{Name: "alpha", Path: filepath.Join(target, "alpha"), Size: 10, IsDir: true},
		},
		LargeFiles: []fileEntry{
			{Name: "big.bin", Path: filepath.Join(target, "big.bin"), Size: 2048},
		},
		TotalSize: 42,
	}

	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cache, err := loadCacheFromDisk(target)
	if err != nil {
		t.Fatalf("loadCacheFromDisk: %v", err)
	}
	if cache.TotalSize != result.TotalSize {
		t.Fatalf("total size mismatch: want %d, got %d", result.TotalSize, cache.TotalSize)
	}
	if len(cache.Entries) != len(result.Entries) {
		t.Fatalf("entry count mismatch: want %d, got %d", len(result.Entries), len(cache.Entries))
	}
	if len(cache.LargeFiles) != len(result.LargeFiles) {
		t.Fatalf("large file count mismatch: want %d, got %d", len(result.LargeFiles), len(cache.LargeFiles))
	}
}

func TestMeasureOverviewSize(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	target := filepath.Join(home, "measure")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	content := []byte(strings.Repeat("x", 4096))
	if err := os.WriteFile(filepath.Join(target, "data.bin"), content, 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	size, err := measureOverviewSize(target)
	if err != nil {
		t.Fatalf("measureOverviewSize: %v", err)
	}
	if size <= 0 {
		t.Fatalf("expected positive size, got %d", size)
	}

	// Ensure snapshot stored.
	cached, err := loadStoredOverviewSize(target)
	if err != nil {
		t.Fatalf("loadStoredOverviewSize: %v", err)
	}
	if cached != size {
		t.Fatalf("snapshot mismatch: want %d, got %d", size, cached)
	}

	// Ensure measureOverviewSize does not use cache
	// APFS block size is 4KB, 4097 bytes should use more blocks
	content = []byte(strings.Repeat("x", 4097))
	if err := os.WriteFile(filepath.Join(target, "data2.bin"), content, 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	size2, err := measureOverviewSize(target)
	if err != nil {
		t.Fatalf("measureOverviewSize: %v", err)
	}
	if size2 == size {
		t.Fatalf("measureOverwiewSize used cache")
	}
}

func TestIsHandledByMoClean(t *testing.T) {
	tests := []struct {
		name string
		path string
		want bool
	}{
		// Paths mo clean handles.
		{"user caches", "/Users/test/Library/Caches/com.example", true},
		{"user logs", "/Users/test/Library/Logs/DiagnosticReports", true},
		{"saved app state", "/Users/test/Library/Saved Application State/com.example", true},
		{"user trash", "/Users/test/.Trash/deleted-file", true},
		{"diagnostic reports", "/Users/test/Library/DiagnosticReports/crash.log", true},

		// Paths mo clean does NOT handle.
		{"project node_modules", "/Users/test/project/node_modules", false},
		{"project build", "/Users/test/project/build", false},
		{"home directory", "/Users/test", false},
		{"random path", "/some/random/path", false},
		{"empty string", "", false},

		// Partial matches should not trigger (case sensitive).
		{"lowercase caches", "/users/test/library/caches/foo", false},
		{"different trash path", "/Users/test/Trash/file", false}, // Missing dot prefix
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isHandledByMoClean(tt.path)
			if got != tt.want {
				t.Errorf("isHandledByMoClean(%q) = %v, want %v", tt.path, got, tt.want)
			}
		})
	}
}

func TestIsCleanableDir(t *testing.T) {
	tests := []struct {
		name string
		path string
		want bool
	}{
		// Empty path.
		{"empty string", "", false},

		// Project dependencies (should be cleanable).
		{"node_modules", "/Users/test/project/node_modules", true},
		{"nested node_modules", "/Users/test/project/packages/app/node_modules", true},
		{"venv", "/Users/test/project/venv", true},
		{"dot venv", "/Users/test/project/.venv", true},
		{"pycache", "/Users/test/project/src/__pycache__", true},
		{"build dir", "/Users/test/project/build", true},
		{"dist dir", "/Users/test/project/dist", true},
		{"target dir", "/Users/test/project/target", true},
		{"next.js cache", "/Users/test/project/.next", true},
		{"DerivedData", "/Users/test/Library/Developer/Xcode/DerivedData", true},
		{"Pods", "/Users/test/project/ios/Pods", true},
		{"gradle cache", "/Users/test/project/.gradle", true},
		{"coverage", "/Users/test/project/coverage", true},
		{"terraform", "/Users/test/infra/.terraform", true},

		// Paths handled by mo clean (should NOT be cleanable).
		{"user caches", "/Users/test/Library/Caches/com.example", false},
		{"user logs", "/Users/test/Library/Logs/app.log", false},
		{"trash", "/Users/test/.Trash/deleted", false},

		// Not in projectDependencyDirs.
		{"src dir", "/Users/test/project/src", false},
		{"random dir", "/Users/test/project/random", false},
		{"home dir", "/Users/test", false},
		{".git dir", "/Users/test/project/.git", false},

		// Edge cases.
		{"just basename node_modules", "node_modules", true},
		{"root path", "/", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isCleanableDir(tt.path)
			if got != tt.want {
				t.Errorf("isCleanableDir(%q) = %v, want %v", tt.path, got, tt.want)
			}
		})
	}
}

func TestLoadCacheExpiresWhenDirectoryChanges(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "change-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 5}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	// Advance mtime beyond grace period.
	time.Sleep(time.Millisecond * 10)
	if err := os.Chtimes(target, time.Now(), time.Now()); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	// Simulate older cache entry to exceed grace window.
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	if _, err := os.Stat(cachePath); err != nil {
		t.Fatalf("stat cache: %v", err)
	}
	oldTime := time.Now().Add(-cacheModTimeGrace - time.Minute)
	if err := os.Chtimes(cachePath, oldTime, oldTime); err != nil {
		t.Fatalf("chtimes cache: %v", err)
	}

	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	entry.ScanTime = time.Now().Add(-8 * 24 * time.Hour)

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected cache load to fail after stale scan time")
	}
}

func TestLoadCacheReusesRecentEntryAfterDirectoryChanges(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "recent-change-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 5, TotalFiles: 1}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}

	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	// Make cache entry look recently scanned, but older than mod time grace.
	entry.ModTime = time.Now().Add(-2 * time.Hour)
	entry.ScanTime = time.Now().Add(-1 * time.Hour)

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if err := os.Chtimes(target, time.Now(), time.Now()); err != nil {
		t.Fatalf("chtimes target: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err != nil {
		t.Fatalf("expected recent cache to be reused, got error: %v", err)
	}
}

func TestLoadCacheExpiresWhenModifiedAndReuseWindowPassed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "reuse-window-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 5, TotalFiles: 1}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}

	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	// Within overall 7-day TTL but beyond reuse window.
	entry.ModTime = time.Now().Add(-48 * time.Hour)
	entry.ScanTime = time.Now().Add(-(cacheReuseWindow + time.Hour))

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if err := os.Chtimes(target, time.Now(), time.Now()); err != nil {
		t.Fatalf("chtimes target: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected cache load to fail after reuse window passes")
	}
}

func TestLoadStaleCacheFromDiskAllowsRecentExpiredCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "stale-cache-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 7, TotalFiles: 2}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	// Expired for normal cache validation but still inside stale fallback window.
	entry.ModTime = time.Now().Add(-48 * time.Hour)
	entry.ScanTime = time.Now().Add(-48 * time.Hour)

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if err := os.Chtimes(target, time.Now(), time.Now()); err != nil {
		t.Fatalf("chtimes target: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected normal cache load to fail")
	}
	if _, err := loadStaleCacheFromDisk(target); err != nil {
		t.Fatalf("expected stale cache load to succeed, got error: %v", err)
	}
}

func TestLoadStaleCacheFromDiskExpiresByStaleTTL(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "stale-cache-expired-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 9, TotalFiles: 3}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	entry.ScanTime = time.Now().Add(-(staleCacheTTL + time.Hour))

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if _, err := loadStaleCacheFromDisk(target); err == nil {
		t.Fatalf("expected stale cache load to fail after stale TTL")
	}
}

func TestScanPathPermissionError(t *testing.T) {
	root := t.TempDir()
	lockedDir := filepath.Join(root, "locked")
	if err := os.Mkdir(lockedDir, 0o755); err != nil {
		t.Fatalf("create locked dir: %v", err)
	}

	// Create a file before locking.
	if err := os.WriteFile(filepath.Join(lockedDir, "secret.txt"), []byte("shh"), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}

	// Remove permissions.
	if err := os.Chmod(lockedDir, 0o000); err != nil {
		t.Fatalf("chmod 000: %v", err)
	}
	defer func() {
		// Restore permissions for cleanup.
		_ = os.Chmod(lockedDir, 0o755)
	}()

	var files, dirs, bytes int64
	current := &atomic.Value{}
	current.Store("")

	// Scanning the locked dir itself should fail.
	_, err := scanPathConcurrent(lockedDir, &files, &dirs, &bytes, current)
	if err == nil {
		t.Fatalf("expected error scanning locked directory, got nil")
	}
	if !os.IsPermission(err) {
		t.Logf("unexpected error type: %v", err)
	}
}

func TestCalculateDirSizeFastHighFanoutCompletes(t *testing.T) {
	root := t.TempDir()

	// Reproduce high fan-out nested directory pattern that previously risked semaphore deadlock.
	const fanout = 256
	for i := range fanout {
		nested := filepath.Join(root, fmt.Sprintf("dir-%03d", i), "nested")
		if err := os.MkdirAll(nested, 0o755); err != nil {
			t.Fatalf("create nested dir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(nested, "data.bin"), []byte("x"), 0o644); err != nil {
			t.Fatalf("write nested file: %v", err)
		}
	}

	var files, dirs, bytes int64
	current := &atomic.Value{}
	current.Store("")

	done := make(chan int64, 1)
	go func() {
		done <- calculateDirSizeFast(root, &files, &dirs, &bytes, current)
	}()

	select {
	case total := <-done:
		if total <= 0 {
			t.Fatalf("expected positive total size, got %d", total)
		}
		if got := atomic.LoadInt64(&files); got < fanout {
			t.Fatalf("expected at least %d files scanned, got %d", fanout, got)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("calculateDirSizeFast did not complete under high fan-out")
	}
}
