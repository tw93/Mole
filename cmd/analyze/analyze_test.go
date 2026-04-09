//go:build darwin

package main

import (
	"encoding/gob"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func resetOverviewSnapshotForTest() {
	overviewSnapshotMu.Lock()
	overviewSnapshotCache = nil
	overviewSnapshotLoaded = false
	overviewSnapshotMu.Unlock()
}

func runScanResultCmd(t *testing.T, cmd tea.Cmd) scanResultMsg {
	t.Helper()

	msg := cmd()
	switch typed := msg.(type) {
	case scanResultMsg:
		return typed
	case tea.BatchMsg:
		for _, batchCmd := range typed {
			if batchCmd == nil {
				continue
			}
			if scanMsg, ok := batchCmd().(scanResultMsg); ok {
				return scanMsg
			}
		}
		t.Fatalf("expected tea.BatchMsg to contain a scanResultMsg, got %T", msg)
	default:
		t.Fatalf("expected scanResultMsg or tea.BatchMsg, got %T", msg)
	}

	return scanResultMsg{}
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

func TestPerformScanForJSONCountsTopLevelFiles(t *testing.T) {
	root := t.TempDir()

	rootFile := filepath.Join(root, "root.txt")
	if err := os.WriteFile(rootFile, []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root file: %v", err)
	}

	nested := filepath.Join(root, "nested")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("create nested dir: %v", err)
	}

	nestedFile := filepath.Join(nested, "nested.txt")
	if err := os.WriteFile(nestedFile, []byte("nested-data"), 0o644); err != nil {
		t.Fatalf("write nested file: %v", err)
	}

	result := performScanForJSON(root, false)

	if result.TotalFiles != 2 {
		t.Fatalf("expected 2 files in JSON output, got %d", result.TotalFiles)
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

func TestUpdateKeyEscGoesBackFromDirectoryView(t *testing.T) {
	m := model{
		path: "/tmp/child",
		history: []historyEntry{
			{
				Path:        "/tmp",
				Entries:     []dirEntry{{Name: "child", Path: "/tmp/child", Size: 1, IsDir: true}},
				TotalSize:   1,
				Selected:    0,
				EntryOffset: 0,
			},
		},
		entries: []dirEntry{{Name: "file.txt", Path: "/tmp/child/file.txt", Size: 1}},
	}

	updated, cmd := m.updateKey(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd != nil {
		t.Fatalf("expected no command when returning from cached history, got %v", cmd)
	}

	got, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	if got.path != "/tmp" {
		t.Fatalf("expected path /tmp after Esc, got %s", got.path)
	}
	if got.status == "" {
		t.Fatalf("expected status to be updated after Esc navigation")
	}
}

func TestUpdateKeyCtrlCQuits(t *testing.T) {
	m := model{}

	_, cmd := m.updateKey(tea.KeyMsg{Type: tea.KeyCtrlC})
	if cmd == nil {
		t.Fatalf("expected quit command for Ctrl+C")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatalf("expected tea.QuitMsg from quit command")
	}
}

func TestViewShowsEscBackAndCtrlCQuitHints(t *testing.T) {
	m := model{
		path:       "/tmp/project",
		history:    []historyEntry{{Path: "/tmp"}},
		entries:    []dirEntry{{Name: "cache", Path: "/tmp/project/cache", Size: 1, IsDir: true}},
		largeFiles: []fileEntry{{Name: "large.bin", Path: "/tmp/project/large.bin", Size: 1024}},
		totalSize:  1024,
	}

	view := m.View()
	if !strings.Contains(view, "Esc Back") {
		t.Fatalf("expected Esc Back hint in view, got:\n%s", view)
	}
	if !strings.Contains(view, "Ctrl+C Quit") {
		t.Fatalf("expected Ctrl+C Quit hint in view, got:\n%s", view)
	}
}

func TestOverviewViewShowsFreeSpaceLabel(t *testing.T) {
	m := model{
		path:       "/",
		isOverview: true,
		diskFree:   123_400_000,
		entries:    []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	view := m.View()
	want := fmt.Sprintf("(%s free)", humanizeBytes(m.diskFree))
	if !strings.Contains(view, want) {
		t.Fatalf("expected free-space label %q in overview view, got:\n%s", want, view)
	}
}

func TestOverviewViewOmitsFreeSpaceLabelWhenUnknown(t *testing.T) {
	m := model{
		path:       "/",
		isOverview: true,
		diskFree:   0,
		entries:    []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	view := m.View()
	if strings.Contains(view, "free)") {
		t.Fatalf("expected overview view to omit free-space label when unavailable, got:\n%s", view)
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

func TestScanPathConcurrentWarmsChildDirectoryCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "root.txt"), []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root data: %v", err)
	}
	if err := os.WriteFile(filepath.Join(child, "data.bin"), []byte(strings.Repeat("x", 4096)), 0o644); err != nil {
		t.Fatalf("write child data: %v", err)
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	if _, err := scanPathConcurrent(root, &filesScanned, &dirsScanned, &bytesScanned, current); err != nil {
		t.Fatalf("scanPathConcurrent(root): %v", err)
	}

	cached, err := loadCacheFromDisk(child)
	if err != nil {
		t.Fatalf("expected warmed child cache, got error: %v", err)
	}
	if cached.TotalSize <= 0 {
		t.Fatalf("expected positive cached child size, got %d", cached.TotalSize)
	}
	if len(cached.Entries) == 0 {
		t.Fatalf("expected cached child entries to be populated")
	}
	if cached.TotalFiles != 1 {
		t.Fatalf("expected warmed child cache to track local file count 1, got %d", cached.TotalFiles)
	}
	if !cached.NeedsRefresh {
		t.Fatalf("expected warmed child cache to be marked for refresh")
	}
}

func TestScanPathConcurrentUsesChildCacheLargeFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	largeFile := filepath.Join(child, "large.bin")
	if err := os.WriteFile(largeFile, []byte(strings.Repeat("x", 2<<20)), 0o644); err != nil {
		t.Fatalf("write large file: %v", err)
	}

	var childFiles, childDirs, childBytes int64
	childCurrent := &atomic.Value{}
	childCurrent.Store("")
	childResult, err := scanPathConcurrent(child, &childFiles, &childDirs, &childBytes, childCurrent)
	if err != nil {
		t.Fatalf("scanPathConcurrent(child): %v", err)
	}
	if err := saveCacheToDisk(child, childResult); err != nil {
		t.Fatalf("saveCacheToDisk(child): %v", err)
	}

	if err := os.Chmod(child, 0o000); err != nil {
		t.Fatalf("chmod child unreadable: %v", err)
	}
	defer func() {
		_ = os.Chmod(child, 0o755)
	}()

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	result, err := scanPathConcurrent(root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent(root): %v", err)
	}

	foundChild := false
	for _, entry := range result.Entries {
		if entry.Path == child {
			foundChild = true
			if entry.Size != childResult.TotalSize {
				t.Fatalf("cached child size mismatch: want %d, got %d", childResult.TotalSize, entry.Size)
			}
			break
		}
	}
	if !foundChild {
		t.Fatalf("expected cached child directory in root entries")
	}

	foundLargeFile := false
	for _, file := range result.LargeFiles {
		if file.Path == largeFile {
			foundLargeFile = true
			break
		}
	}
	if !foundLargeFile {
		t.Fatalf("expected root large files to include cached child large file")
	}
}

func TestScanPathConcurrentWarmsChildCachesWithoutRecursiveSpotlight(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	childOne := filepath.Join(root, "child-one")
	childTwo := filepath.Join(root, "child-two")
	for _, dir := range []string{childOne, childTwo} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("create dir %s: %v", dir, err)
		}
		if err := os.WriteFile(filepath.Join(dir, "data.bin"), []byte(strings.Repeat("x", 4096)), 0o644); err != nil {
			t.Fatalf("write data in %s: %v", dir, err)
		}
	}

	logPath := filepath.Join(home, "mdfind.log")
	stubDir := filepath.Join(home, "bin")
	if err := os.MkdirAll(stubDir, 0o755); err != nil {
		t.Fatalf("create stub dir: %v", err)
	}
	stubPath := filepath.Join(stubDir, "mdfind")
	stubScript := fmt.Sprintf("#!/bin/sh\necho \"$*\" >> %s\nexit 0\n", strconv.Quote(logPath))
	if err := os.WriteFile(stubPath, []byte(stubScript), 0o755); err != nil {
		t.Fatalf("write mdfind stub: %v", err)
	}
	t.Setenv("PATH", stubDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	if _, err := scanPathConcurrent(root, &filesScanned, &dirsScanned, &bytesScanned, current); err != nil {
		t.Fatalf("scanPathConcurrent(root): %v", err)
	}

	data, err := os.ReadFile(logPath)
	if err != nil {
		t.Fatalf("read mdfind log: %v", err)
	}
	lines := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(lines) != 1 {
		t.Fatalf("expected only root spotlight invocation, got %d lines: %q", len(lines), string(data))
	}
}

func TestScanCmdTreatsWarmedCacheAsStale(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{
		Entries:    []dirEntry{{Name: "child", Path: filepath.Join(target, "child"), Size: 1, IsDir: true}},
		LargeFiles: []fileEntry{{Name: "big.bin", Path: filepath.Join(target, "big.bin"), Size: 2 << 20}},
		TotalSize:  42,
		TotalFiles: 1,
	}
	if err := saveCacheToDiskWithOptions(target, result, true); err != nil {
		t.Fatalf("saveCacheToDiskWithOptions: %v", err)
	}

	m := newModel(target, false)
	msg := m.scanCmd(target)()
	scanMsg, ok := msg.(scanResultMsg)
	if !ok {
		t.Fatalf("expected scanResultMsg, got %T", msg)
	}
	if !scanMsg.stale {
		t.Fatalf("expected warmed cache to trigger stale refresh path")
	}
	if scanMsg.result.TotalFiles != result.TotalFiles {
		t.Fatalf("expected cached result to survive stale load, got %d", scanMsg.result.TotalFiles)
	}
}

func TestEnterSelectedDirRefreshesStaleInMemoryCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	parent := filepath.Join(home, "parent")
	child := filepath.Join(parent, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	freshPath := filepath.Join(child, "fresh.bin")
	if err := os.WriteFile(freshPath, []byte("fresh-data"), 0o644); err != nil {
		t.Fatalf("write fresh file: %v", err)
	}
	freshInfo, err := os.Stat(freshPath)
	if err != nil {
		t.Fatalf("stat fresh file: %v", err)
	}
	freshSize := getActualFileSize(freshPath, freshInfo)

	warmed := scanResult{
		Entries:    []dirEntry{{Name: "stale.bin", Path: filepath.Join(child, "stale.bin"), Size: 1}},
		TotalSize:  1,
		TotalFiles: 1,
	}
	if err := saveCacheToDiskWithOptions(child, warmed, true); err != nil {
		t.Fatalf("saveCacheToDiskWithOptions: %v", err)
	}

	m := newModel(parent, false)
	m.entries = []dirEntry{{Name: "child", Path: child, Size: 9, IsDir: true}}
	m.cache[child] = historyEntry{
		Path:         child,
		Entries:      []dirEntry{{Name: "stale.bin", Path: filepath.Join(child, "stale.bin"), Size: 1}},
		TotalSize:    1,
		TotalFiles:   1,
		NeedsRefresh: true,
	}

	updated, cmd := m.enterSelectedDir()
	if cmd == nil {
		t.Fatalf("expected stale in-memory child cache to trigger a refresh")
	}

	got := updated.(model)
	if got.path != child {
		t.Fatalf("expected path %s, got %s", child, got.path)
	}
	if !got.scanning {
		t.Fatalf("expected directory to remain scanning while refreshing stale cache")
	}
	if got.totalSize != 1 {
		t.Fatalf("expected stale cache contents to be shown immediately, got %d", got.totalSize)
	}

	scanMsg := runScanResultCmd(t, cmd)
	if scanMsg.stale {
		t.Fatalf("expected stale cached navigation to force a fresh scan")
	}
	if scanMsg.result.TotalSize != freshSize {
		t.Fatalf("expected fresh rescan total size %d, got %d", freshSize, scanMsg.result.TotalSize)
	}
	if scanMsg.result.Entries[0].Name != "fresh.bin" {
		t.Fatalf("expected rescan to surface live filesystem contents, got %+v", scanMsg.result.Entries)
	}
}

func TestGoBackRefreshesHistoryEntryNeedingRefresh(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	child := filepath.Join(home, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	freshPath := filepath.Join(child, "fresh.bin")
	if err := os.WriteFile(freshPath, []byte("fresh-data-2"), 0o644); err != nil {
		t.Fatalf("write fresh file: %v", err)
	}
	freshInfo, err := os.Stat(freshPath)
	if err != nil {
		t.Fatalf("stat fresh file: %v", err)
	}
	freshSize := getActualFileSize(freshPath, freshInfo)

	warmed := scanResult{
		Entries:    []dirEntry{{Name: "stale.bin", Path: filepath.Join(child, "stale.bin"), Size: 2}},
		TotalSize:  2,
		TotalFiles: 1,
	}
	if err := saveCacheToDiskWithOptions(child, warmed, true); err != nil {
		t.Fatalf("saveCacheToDiskWithOptions: %v", err)
	}

	m := newModel(filepath.Join(child, "grandchild"), false)
	m.history = []historyEntry{{
		Path:         child,
		Entries:      []dirEntry{{Name: "stale.bin", Path: filepath.Join(child, "stale.bin"), Size: 2}},
		TotalSize:    2,
		TotalFiles:   1,
		NeedsRefresh: true,
	}}

	updated, cmd := m.goBack()
	if cmd == nil {
		t.Fatalf("expected stale history entry to trigger a refresh")
	}

	got := updated.(model)
	if got.path != child {
		t.Fatalf("expected path %s after goBack, got %s", child, got.path)
	}
	if !got.scanning {
		t.Fatalf("expected goBack to keep scanning while refreshing stale history entry")
	}
	if got.totalSize != 2 {
		t.Fatalf("expected stale history snapshot to be restored immediately, got %d", got.totalSize)
	}

	scanMsg := runScanResultCmd(t, cmd)
	if scanMsg.stale {
		t.Fatalf("expected stale history navigation to force a fresh scan")
	}
	if scanMsg.result.TotalSize != freshSize {
		t.Fatalf("expected fresh rescan total size %d, got %d", freshSize, scanMsg.result.TotalSize)
	}
	if scanMsg.result.Entries[0].Name != "fresh.bin" {
		t.Fatalf("expected rescan to surface live filesystem contents, got %+v", scanMsg.result.Entries)
	}
}

func TestScanPathConcurrentWarmsChildCacheWithLiveProgress(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	const dirCount = 32
	const filesPerDir = 256
	for i := range dirCount {
		dir := filepath.Join(child, fmt.Sprintf("dir-%02d", i))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("create nested dir %s: %v", dir, err)
		}
		for j := range filesPerDir {
			file := filepath.Join(dir, fmt.Sprintf("file-%03d.bin", j))
			if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
				t.Fatalf("write %s: %v", file, err)
			}
		}
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	done := make(chan struct{})
	errCh := make(chan error, 1)
	go func() {
		_, err := scanPathConcurrent(root, &filesScanned, &dirsScanned, &bytesScanned, current)
		errCh <- err
		close(done)
	}()

	deadline := time.Now().Add(5 * time.Second)
	sawLiveProgress := false
	for time.Now().Before(deadline) {
		if atomic.LoadInt64(&filesScanned) > 0 {
			select {
			case <-done:
			default:
				sawLiveProgress = true
			}
			if sawLiveProgress {
				break
			}
		}
		select {
		case <-done:
			if !sawLiveProgress {
				t.Fatalf("expected live progress before child warm scan completed, final files=%d", atomic.LoadInt64(&filesScanned))
			}
		default:
		}
		time.Sleep(2 * time.Millisecond)
	}

	if !sawLiveProgress {
		t.Fatalf("expected filesScanned to advance before warm child scan finished")
	}

	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("scanPathConcurrent(root): %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("scan did not complete")
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
