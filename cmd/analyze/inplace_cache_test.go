//go:build darwin

package main

import (
	"bytes"
	"context"
	"encoding/gob"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func TestInPlaceFileChangesInvalidateDiskCache(t *testing.T) {
	for _, mode := range []string{"unchanged_control", "reopen_after_growth", "parent_after_growth", "reopen_after_shrink", "parent_after_shrink", "ancestor_after_growth", "ancestor_after_shrink"} {
		t.Run(mode, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			root := filepath.Join(home, "fixture")
			middle := filepath.Join(root, "middle")
			child := filepath.Join(middle, "child")
			file := filepath.Join(child, "data.bin")
			if err := os.MkdirAll(child, 0755); err != nil {
				t.Fatal(err)
			}
			if err := os.WriteFile(file, bytes.Repeat([]byte("x"), 4096), 0644); err != nil {
				t.Fatal(err)
			}
			scan := func(path string) scanResult {
				var f, d, b int64
				current := &atomic.Value{}
				current.Store("")
				r, err := scanPathConcurrent(context.Background(), path, &f, &d, &b, current)
				if err != nil {
					t.Fatal(err)
				}
				return r
			}
			if strings.Contains(mode, "shrink") {
				initialSize := 1 << 20
				if err := os.WriteFile(file, bytes.Repeat([]byte("x"), initialSize), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			original := scan(child)
			if err := saveCacheToDisk(child, original); err != nil {
				t.Fatal(err)
			}
			if err := saveCacheToDisk(middle, scan(middle)); err != nil {
				t.Fatal(err)
			}
			parent := scan(root)
			if err := saveCacheToDisk(root, parent); err != nil {
				t.Fatal(err)
			}
			stat := func(path string) os.FileInfo {
				t.Helper()
				info, err := os.Stat(path)
				if err != nil {
					t.Fatal(err)
				}
				return info
			}
			beforeChild, beforeRoot := stat(child), stat(root)
			if mode != "unchanged_control" {
				changedSize := 1 << 20
				if strings.Contains(mode, "shrink") {
					changedSize = 4096
				}
				if err := os.WriteFile(file, bytes.Repeat([]byte("y"), changedSize), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			afterChild, afterRoot := stat(child), stat(root)
			if !beforeChild.ModTime().Equal(afterChild.ModTime()) || !beforeRoot.ModTime().Equal(afterRoot.ModTime()) {
				t.Fatal("fixture directory mtime changed")
			}
			info, err := os.Stat(file)
			if err != nil {
				t.Fatal(err)
			}
			want := getActualFileSize(file, info)
			if strings.HasPrefix(mode, "parent_after_") {
				got := scan(root)
				if got.TotalSize != want {
					t.Fatalf("fresh parent scan total=%d, want current=%d (old=%d)", got.TotalSize, want, original.TotalSize)
				}
				return
			}
			target := child
			if strings.HasPrefix(mode, "ancestor_after_") {
				target = root
			}
			m := newModel(target, false)
			msg := m.scanCmd(target)()
			got, ok := msg.(scanResultMsg)
			if !ok {
				t.Fatalf("cached first paint missed: %T", msg)
			}
			if mode == "unchanged_control" {
				if got.stale || got.result.TotalSize != want {
					t.Fatalf("unchanged result stale=%v size=%d want=%d", got.stale, got.result.TotalSize, want)
				}
				return
			}
			if !got.stale {
				t.Fatalf("changed tree cache marked current: size=%d want=%d", got.result.TotalSize, want)
			}
			if got.result.TotalSize != original.TotalSize {
				t.Fatalf("lost cached first paint: got=%d original=%d", got.result.TotalSize, original.TotalSize)
			}
			updated, cmd := m.Update(got)
			m = updated.(model)
			if cmd == nil || !m.scanning {
				t.Fatal("stale cache did not schedule refresh")
			}
			refreshed := runScanResultCmd(t, cmd)
			if refreshed.err != nil || refreshed.result.TotalSize != want {
				t.Fatalf("refresh total=%d want=%d err=%v", refreshed.result.TotalSize, want, refreshed.err)
			}
		})
	}
}

func TestUnverifiableFileCacheIsOnlyFirstPaint(t *testing.T) {
	for _, mode := range []string{"shortened", "omitted_empty_directory", "unreadable"} {
		t.Run(mode, func(t *testing.T) {
			if mode == "unreadable" && os.Geteuid() == 0 {
				t.Skip("permission fixture requires an unprivileged user")
			}
			t.Setenv("HOME", t.TempDir())
			root := t.TempDir()
			count := 1
			if mode == "shortened" {
				count = maxEntries + 1
			}
			if mode == "omitted_empty_directory" {
				count = maxEntries
				if err := os.Mkdir(filepath.Join(root, "empty"), 0o755); err != nil {
					t.Fatal(err)
				}
			}
			for i := range count {
				if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("file-%d", i)), []byte("data"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			current := &atomic.Value{}
			current.Store("")
			var f, d, b int64
			result, err := scanPathConcurrent(context.Background(), root, &f, &d, &b, current)
			if err != nil {
				t.Fatal(err)
			}
			if err := saveCacheToDisk(root, result); err != nil {
				t.Fatal(err)
			}
			if mode == "unreadable" {
				if err := os.Chmod(root, 0); err != nil {
					t.Fatal(err)
				}
				t.Cleanup(func() { _ = os.Chmod(root, 0o755) })
			}
			cached, err := loadCacheFromDisk(root)
			if err != nil || !cached.NeedsRefresh {
				t.Fatalf("unverifiable cache did not require refresh: err=%v", err)
			}
			if _, ok := loadCachedSubdirResult(context.Background(), root, make(chan fileEntry, maxLargeFiles)); ok {
				t.Fatal("unverifiable subtree total reused")
			}
			m := newModel(root, false)
			msg, ok := m.scanCmd(root)().(scanResultMsg)
			if !ok || !msg.stale || msg.result.TotalSize != result.TotalSize {
				t.Fatalf("cached first paint was lost: %+v", msg)
			}
		})
	}
}

func TestLiveDiskSnapshotKeepsZeroSizeChildren(t *testing.T) {
	for _, directory := range []bool{true, false} {
		t.Run(fmt.Sprintf("directory=%t", directory), func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			resetOverviewSnapshotForTest()
			t.Cleanup(resetOverviewSnapshotForTest)
			root := t.TempDir()
			writeFileWithSize(t, filepath.Join(root, "data"), 4096)
			empty := filepath.Join(root, "empty")
			if directory {
				if err := os.Mkdir(empty, 0o700); err != nil {
					t.Fatal(err)
				}
			} else if err := os.WriteFile(empty, nil, 0o600); err != nil {
				t.Fatal(err)
			}
			m := newModel(root, false)
			defer m.cancelBackgroundCacheWrites(nil)
			result := runScanResultCmd(t, m.scanBypassingCacheCmd(root)).result
			m.finishLiveScan(result)
			waitForTestCondition(t, "live snapshot to reach disk", func() bool {
				_, err := loadRawCacheFromDisk(root)
				return err == nil
			})
			raw, err := loadRawCacheFromDisk(root)
			if err != nil || len(raw.Entries) != 2 {
				t.Fatalf("disk snapshot lost a zero-size child: entry=%+v err=%v", raw, err)
			}
			if len(m.entries) != 1 || len(m.cache[root].Entries) != 1 {
				t.Fatal("zero-size child leaked into the existing UI/history view")
			}
			cached, err := loadCacheFromDisk(root)
			if err != nil || cached.NeedsRefresh != directory {
				t.Fatalf("unchanged snapshot verification: directory=%t cached=%+v err=%v", directory, cached, err)
			}
			before, err := os.Stat(root)
			if err != nil {
				t.Fatal(err)
			}
			changed := empty
			if directory {
				changed = filepath.Join(empty, "new-data")
			}
			writeFileWithSize(t, changed, 8192)
			after, err := os.Stat(root)
			if err != nil || !before.ModTime().Equal(after.ModTime()) {
				t.Fatalf("fixture changed the root directory mtime: %v", err)
			}
			if _, ok := loadCachedSubdirResult(context.Background(), root, make(chan fileEntry, maxLargeFiles)); ok {
				t.Fatal("changed zero-size child retained an authoritative subtree total")
			}
			reopened := newModel(root, false)
			defer reopened.cancelLiveScan()
			stale, ok := reopened.scanCmd(root)().(scanResultMsg)
			if !ok || !stale.stale {
				t.Fatalf("changed snapshot was not retained as stale first paint: %+v", stale)
			}
			next, refresh := reopened.Update(stale)
			reopened = next.(model)
			fresh := runScanResultCmd(t, refresh)
			if fresh.err != nil || fresh.result.TotalSize <= result.TotalSize {
				t.Fatalf("stale refresh failed to find added contents: %+v", fresh)
			}
		})
	}
}

func TestFilteredSchema10CacheIsRefused(t *testing.T) {
	for _, stale := range []bool{false, true} {
		t.Run(fmt.Sprintf("stale=%t", stale), func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			root := t.TempDir()
			path, err := getCachePath(root)
			if err != nil {
				t.Fatal(err)
			}
			info, err := os.Stat(root)
			if err != nil {
				t.Fatal(err)
			}
			file, err := os.Create(path)
			if err != nil {
				t.Fatal(err)
			}
			err = gob.NewEncoder(file).Encode(cacheEntry{SchemaVersion: 10, ScanTime: time.Now(), ModTime: info.ModTime()})
			closeErr := file.Close()
			if err != nil || closeErr != nil {
				t.Fatalf("write old cache: %v / %v", err, closeErr)
			}
			loader := loadCacheFromDisk
			if stale {
				loader = loadStaleCacheFromDisk
			}
			if _, err := loader(root); err == nil {
				t.Fatal("schema 10 snapshot may have omitted empty directories and must be refused")
			}
		})
	}
}

func TestStaleHomeRefreshBypassesLibraryOverviewSnapshot(t *testing.T) {
	for _, route := range []string{"initial", "history_return", "memory_reentry"} {
		t.Run(route, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			library := filepath.Join(home, "Library")
			if err := os.MkdirAll(library, 0o755); err != nil {
				t.Fatal(err)
			}
			file := filepath.Join(library, "live.bin")
			writeFileWithSize(t, file, 8192)
			info, err := os.Stat(file)
			if err != nil {
				t.Fatal(err)
			}
			want := getActualFileSize(file, info)
			old := scanResult{Entries: []dirEntry{{Name: "Library", Path: library, Size: 1, IsDir: true}}, TotalSize: 1, TotalFiles: 1}
			if err := saveCacheToDisk(home, old); err != nil {
				t.Fatal(err)
			}
			if err := storeOverviewSize(library, 1); err != nil {
				t.Fatal(err)
			}
			m := newModel(filepath.Dir(home), false)
			m.entries = []dirEntry{{Name: filepath.Base(home), Path: home, Size: 1, IsDir: true}}
			m.entriesAll = m.entries
			next, enter := m.enterSelectedDir()
			m = next.(model)
			msg := runScanResultCmd(t, enter)
			if !msg.stale || msg.result.TotalSize != 1 {
				t.Fatalf("expected the old first paint: %+v", msg)
			}
			next, refresh := m.Update(msg)
			m = next.(model)
			switch route {
			case "history_return":
				next, _ = m.enterSelectedDir()
				m = next.(model)
				next, refresh = m.goBack()
				m = next.(model)
			case "memory_reentry":
				next, _ = m.goBack()
				m = next.(model)
				next, refresh = m.enterSelectedDir()
				m = next.(model)
			}
			defer m.cancelLiveScan()
			fresh := runScanResultCmd(t, refresh)
			if fresh.err != nil {
				t.Fatal(fresh.err)
			}
			for _, entry := range fresh.result.Entries {
				if entry.Path == library {
					if entry.Size != want {
						t.Fatalf("stale refresh reused the old Library overview measurement: got=%d want=%d", entry.Size, want)
					}
					return
				}
			}
			t.Fatal("Library missing from the refreshed home scan")
		})
	}
}

func BenchmarkCachedFirstPaint(b *testing.B) {
	b.Setenv("HOME", b.TempDir())
	root := b.TempDir()
	var entries []dirEntry
	for i := range maxEntries - 1 {
		path := filepath.Join(root, fmt.Sprintf("file-%d", i))
		if err := os.WriteFile(path, []byte("data"), 0o644); err != nil {
			b.Fatal(err)
		}
		info, err := os.Stat(path)
		if err != nil {
			b.Fatal(err)
		}
		entries = append(entries, dirEntry{Path: path, Name: info.Name(), Size: getActualFileSize(path, info)})
	}
	var total int64
	for _, entry := range entries {
		total += entry.Size
	}
	if err := saveCacheToDisk(root, scanResult{Entries: entries, TotalFiles: maxEntries - 1, TotalSize: total}); err != nil {
		b.Fatal(err)
	}
	for b.Loop() {
		m := newModel(root, false)
		msg, ok := m.scanCmd(root)().(scanResultMsg)
		m.cancelLiveScan()
		if !ok || msg.stale || msg.result.TotalSize != total {
			b.Fatalf("unchanged cache was not current: %+v", msg)
		}
	}
}
