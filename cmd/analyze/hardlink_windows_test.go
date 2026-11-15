//go:build windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestScanCountsCrossDirectoryHardLinksOnce(t *testing.T) {
	root := t.TempDir()
	store := filepath.Join(root, "store")
	left := filepath.Join(root, "left")
	right := filepath.Join(root, "right")
	for _, dir := range []string{store, left, right} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	original := filepath.Join(store, "blob.bin")
	if err := os.WriteFile(original, make([]byte, 4096), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, link := range []string{filepath.Join(left, "first.bin"), filepath.Join(right, "second.bin")} {
		if err := os.Link(original, link); err != nil {
			t.Skipf("the test volume cannot create hard links: %v", err)
		}
	}

	result, err := scanPathConcurrentAllEntries(context.Background(), root, new(int64), new(int64), new(int64), nil)
	if err != nil {
		t.Fatal(err)
	}
	if result.State != scanComplete || result.TotalSize != 4096 || result.TotalFiles != 3 || !result.dedupedHardlink {
		t.Fatalf("scan = %+v; want one 4096-byte file across three entries", result)
	}
	var sum int64
	var zeroRows int
	for _, entry := range result.Entries {
		sum += entry.Size
		if entry.Size == 0 {
			zeroRows++
		}
	}
	if sum != result.TotalSize || zeroRows != 2 || result.reusable() {
		t.Fatalf("rows sum to %d with %d zero rows; total %d, reusable %v", sum, zeroRows, result.TotalSize, result.reusable())
	}
	if len(filterNonEmptyEntries(result.Entries)) != 3 {
		t.Fatalf("scan hid a directory with duplicate hard links: %+v", result.Entries)
	}

	jsonResult, err := performDirectoryScanForJSON(root)
	if err != nil || jsonResult.TotalSize != 4096 || jsonResult.TotalFiles != 3 {
		t.Fatalf("JSON scan = %+v, %v", jsonResult, err)
	}
	fastSize, err := calculateDirSizeFast(context.Background(), root, nil, nil, nil, nil, nil)
	if err != nil || fastSize != 4096 {
		t.Fatalf("fast scan = %d, %v", fastSize, err)
	}
}

func TestLiveInitialScanStartsWithFreshFileIdentities(t *testing.T) {
	root := t.TempDir()
	original := filepath.Join(root, "first.bin")
	if err := os.WriteFile(original, make([]byte, 1024), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(original, filepath.Join(root, "second.bin")); err != nil {
		t.Skipf("the test volume cannot create hard links: %v", err)
	}
	for run := 0; run < 2; run++ {
		result, targets, err := readLiveScanInitialEntries(root)
		if err != nil || len(targets) != 0 || result.TotalSize != 1024 || result.TotalFiles != 2 {
			t.Fatalf("run %d: result %+v, targets %+v, error %v", run, result, targets, err)
		}
		if !result.dedupedHardlink || result.reusable() {
			t.Fatalf("run %d: duplicate state lost", run)
		}
	}
}

func TestScanWithoutHardLinksKeepsFileSizes(t *testing.T) {
	root := t.TempDir()
	for index, name := range []string{"one.bin", "two.bin"} {
		if err := os.WriteFile(filepath.Join(root, name), make([]byte, (index+1)*1024), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	result, err := scanPathConcurrentAllEntries(context.Background(), root, new(int64), new(int64), new(int64), nil)
	if err != nil || result.TotalSize != 3072 || result.TotalFiles != 2 || result.dedupedHardlink {
		t.Fatalf("scan = %+v, %v; want 3072 bytes and no duplicates", result, err)
	}
	if len(result.Entries) != 2 || len(filterNonEmptyEntries(result.Entries)) != 2 {
		t.Fatalf("scan lost ordinary files: %+v", result.Entries)
	}
}

func TestOldDownloadsCountsCrossDirectoryHardLinksOnce(t *testing.T) {
	root := t.TempDir()
	left := filepath.Join(root, "left")
	right := filepath.Join(root, "right")
	for _, dir := range []string{left, right} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	original := filepath.Join(left, "blob.bin")
	if err := os.WriteFile(original, make([]byte, 2048), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(original, filepath.Join(right, "link.bin")); err != nil {
		t.Skipf("the test volume cannot create hard links: %v", err)
	}
	old := time.Now().AddDate(0, 0, -120)
	for _, path := range []string{original, left, right} {
		if err := os.Chtimes(path, old, old); err != nil {
			t.Fatal(err)
		}
	}
	size, err := measureOldDownloads(context.Background(), root, 90)
	if err != nil || size != 2048 {
		t.Fatalf("old downloads = %d, %v; want 2048", size, err)
	}
}
