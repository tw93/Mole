package main

import (
	"fmt"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestPerformScanForJSONIncludesAllEntriesAndLargeFiles(t *testing.T) {
	root := t.TempDir()

	totalFiles := maxEntries + 6
	for i := 0; i < totalFiles-1; i++ {
		path := filepath.Join(root, fmt.Sprintf("small-%02d.txt", i))
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatalf("write small file %d: %v", i, err)
		}
	}

	hugeFile := filepath.Join(root, "huge.bin")
	if err := os.WriteFile(hugeFile, make([]byte, 2<<20), 0o644); err != nil {
		t.Fatalf("write huge file: %v", err)
	}

	result := performScanForJSON(root, false)

	if result.Overview {
		t.Fatalf("expected non-overview JSON result")
	}
	if got := len(result.Entries); got != totalFiles {
		t.Fatalf("expected %d entries, got %d", totalFiles, got)
	}
	if result.TotalFiles != int64(totalFiles) {
		t.Fatalf("expected %d total files, got %d", totalFiles, result.TotalFiles)
	}
	if len(result.LargeFiles) == 0 {
		t.Fatalf("expected large_files to include the large file")
	}

	foundHuge := false
	for _, file := range result.LargeFiles {
		if file.Name == "huge.bin" && file.Path == hugeFile {
			foundHuge = true
			break
		}
	}
	if !foundHuge {
		t.Fatalf("expected huge.bin in large_files, got %#v", result.LargeFiles)
	}
}

func TestJSONEntriesFromDirEntriesIncludesMetadata(t *testing.T) {
	oldAccess := time.Now().AddDate(0, 0, -120)

	entries := jsonEntriesFromDirEntries([]dirEntry{
		{
			Name:       "old.bin",
			Path:       "/tmp/old.bin",
			Size:       42,
			IsDir:      false,
			LastAccess: oldAccess,
		},
		{
			Name:  "node_modules",
			Path:  "/tmp/project/node_modules",
			Size:  128,
			IsDir: true,
		},
	}, false, nil)

	if entries[0].LastAccess == "" {
		t.Fatalf("expected last_access to be populated")
	}
	if entries[1].Cleanable != true {
		t.Fatalf("expected node_modules entry to be marked cleanable")
	}
}

func TestJSONEntriesFromDirEntriesMarksOverviewInsights(t *testing.T) {
	entry := dirEntry{
		Name:  "Old Downloads (90d+)",
		Path:  "/tmp/test-home/Downloads",
		Size:  256,
		IsDir: true,
	}

	entries := jsonEntriesFromDirEntries([]dirEntry{entry}, true, map[string]bool{
		entry.Path: true,
	})

	if len(entries) != 1 {
		t.Fatalf("expected one entry, got %d", len(entries))
	}
	if !entries[0].Insight {
		t.Fatalf("expected entry to be marked as insight")
	}
}

func TestPerformOverviewScanForJSONSchemaWithInjectedEntries(t *testing.T) {
	root := t.TempDir()
	payload := filepath.Join(root, "payload")
	if err := os.WriteFile(payload, []byte("overview"), 0o644); err != nil {
		t.Fatalf("write overview payload: %v", err)
	}

	result := performOverviewScanForJSONWithEntries("/", nil, []dirEntry{{
		Name:  "Fixture",
		Path:  root,
		IsDir: true,
		Size:  -1,
	}})

	if result.Path != "/" || !result.Overview {
		t.Fatalf("unexpected overview identity: path=%q overview=%v", result.Path, result.Overview)
	}
	if result.Entries == nil {
		t.Fatal("overview entries must be a JSON list, not nil")
	}
	if result.TotalSize <= 0 {
		t.Fatalf("expected measured overview size, got %d", result.TotalSize)
	}
}

func TestOverviewJSONTotalCountsCoveredRowsOnce(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	cache := filepath.Join(home, homeCacheDirName)
	disk := filepath.Join(home, "mnt", "disk")
	useMountTable(t, newMountTable(parseMountInfo("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:50 / "+disk+" rw - nfs4 nas:/export rw\n")))

	rows := []dirEntry{
		{Name: "Home", Path: home, IsDir: true, Size: 300},
		{Name: "User Cache", Path: cache, IsDir: true, Size: 200},
		{Name: "Hugging Face Cache", Path: filepath.Join(cache, "huggingface"), IsDir: true, Size: 50},
		{Name: "Steam", Path: filepath.Join(home, ".local", "share", "Steam"), IsDir: true, Size: 40},
		{Name: "Disk", Path: disk, IsDir: true, Size: 30},
		{Name: "Sibling", Path: home + "-archive", IsDir: true, Size: 20},
	}
	// Home 300 (Steam inside it), User Cache 200 (Hugging Face inside it), the
	// network share below Home that du leaves out 30 and the sibling 20.
	if got := overviewTotalSize(rows); got != 550 {
		t.Fatalf("expected each covered row once, total 550, got %d", got)
	}
	// With no User Cache row the Hugging Face row is the only measurement of
	// that folder, since Home leaves ~/.cache out.
	if got := overviewTotalSize([]dirEntry{rows[0], rows[2]}); got != 350 {
		t.Fatalf("expected the cache insight to count beside Home, got %d", got)
	}
	// A parent that was not measured covers nothing.
	unmeasured := []dirEntry{{Name: "Home", Path: home, IsDir: true, Size: -1}, rows[3]}
	if got := overviewTotalSize(unmeasured); got != 40 {
		t.Fatalf("expected the insight to count under an unmeasured Home, got %d", got)
	}
}

func TestOverviewJSONTotalKeepsAShareBelowALinkedHome(t *testing.T) {
	base := t.TempDir()
	realHome := filepath.Join(base, "real")
	if err := os.MkdirAll(realHome, 0o755); err != nil {
		t.Fatal(err)
	}
	home := filepath.Join(base, "home")
	if err := os.Symlink(realHome, home); err != nil {
		t.Fatal(err)
	}
	t.Setenv("HOME", home)
	share := filepath.Join(realHome, "nas")
	useMountTable(t, newMountTable(parseMountInfo("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 0:50 / "+share+" rw - nfs4 nas:/export rw\n")))

	rows := []dirEntry{
		{Name: "Home", Path: home, IsDir: true, Size: 300},
		{Name: "NAS", Path: filepath.Join(home, "nas"), IsDir: true, Size: 30},
		{Name: "Steam", Path: filepath.Join(home, ".local", "share", "Steam"), IsDir: true, Size: 40},
	}
	if got := overviewTotalSize(rows); got != 330 {
		t.Fatalf("expected Home plus the share du left out, total 330, got %d", got)
	}
}
