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
	if result.State != scanComplete || result.TotalSize != 4096 || result.TotalFiles != 3 || !result.containsDedupedHardlink {
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
	if sum != result.TotalSize || zeroRows != 2 || !result.reusable() {
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
		if !result.containsDedupedHardlink {
			t.Fatalf("run %d: duplicate state lost", run)
		}
	}
}

func TestLiveFoldedDirectoryWithCrossDirectoryHardLinksCountsTheLinkOnce(t *testing.T) {
	root := t.TempDir()
	folded := filepath.Join(root, "node_modules")
	if err := os.Mkdir(folded, 0o755); err != nil {
		t.Fatal(err)
	}
	original := filepath.Join(root, "shared.bin")
	if err := os.WriteFile(original, make([]byte, 1024), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(original, filepath.Join(folded, "shared-link.bin")); err != nil {
		t.Skipf("the test volume cannot create hard links: %v", err)
	}

	limiter := newScanLimiter(0)
	initial, targets, err := readLiveScanInitialEntriesWithLimiter(root, limiter)
	if err != nil || initial.TotalSize != 1024 || len(targets) != 1 {
		t.Fatalf("initial scan = %+v, targets %+v, error %v", initial, targets, err)
	}
	if targets[0].kind != liveScanTargetFoldedDirectory {
		t.Fatalf("target kind = %v, want folded directory", targets[0].kind)
	}
	ctx := context.Background()
	stream := newLiveScanEventStream(newScanPublication(ctx, nil), len(targets))
	runLiveScan(ctx, 1, root, initial, targets, limiter, new(int64), new(int64), new(int64), nil, stream)
	var foldedResult, finalResult scanResult
	var sawFolded, sawComplete bool
	for len(stream.events) > 0 {
		event := <-stream.events
		if event.kind == liveScanChildDone {
			foldedResult = event.result
			sawFolded = true
		}
		if event.kind == liveScanComplete {
			finalResult = event.result
			sawComplete = true
		}
	}
	if !sawFolded || foldedResult.TotalSize != 0 || !foldedResult.containsDedupedHardlink {
		t.Fatalf("folded result = %+v, received %v", foldedResult, sawFolded)
	}
	if !sawComplete || finalResult.TotalSize != 1024 || len(filterNonEmptyEntries(finalResult.Entries)) != 2 {
		t.Fatalf("final result = %+v, received %v", finalResult, sawComplete)
	}
}

func TestUnrelatedEmptyDirectoriesStayHiddenAfterHardlinkDedup(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"left", "right", "empty-a", "empty-b", "normal"} {
		if err := os.Mkdir(filepath.Join(root, name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	original := filepath.Join(root, "left", "shared.bin")
	if err := os.WriteFile(original, make([]byte, 1024), 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Link(original, filepath.Join(root, "right", "shared-link.bin")); err != nil {
		t.Skipf("the test volume cannot create hard links: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "normal", "unique.bin"), make([]byte, 512), 0o644); err != nil {
		t.Fatal(err)
	}

	result, err := scanPathConcurrentAllEntries(context.Background(), root, new(int64), new(int64), new(int64), nil)
	if err != nil || result.TotalSize != 1536 || !result.containsDedupedHardlink {
		t.Fatalf("scan = %+v, error %v", result, err)
	}
	visible := filterNonEmptyEntries(result.Entries)
	if len(visible) != 3 {
		t.Fatalf("visible entries = %+v, want left, right, and normal", visible)
	}
	for _, entry := range visible {
		if entry.Name == "empty-a" || entry.Name == "empty-b" {
			t.Fatalf("unrelated empty directory remains visible: %+v", entry)
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
	if err != nil || result.TotalSize != 3072 || result.TotalFiles != 2 || result.containsDedupedHardlink {
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
