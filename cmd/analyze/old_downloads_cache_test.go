package main

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"testing"
	"time"
)

func TestOldDownloadsOverviewIgnoresWholeDirectoryCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	downloads := filepath.Join(home, "Downloads")
	if err := os.Mkdir(downloads, 0o755); err != nil {
		t.Fatal(err)
	}
	const oldSize, recentSize = 4096, 1 << 20
	oldPath := filepath.Join(downloads, "old.bin")
	if err := os.WriteFile(oldPath, make([]byte, oldSize), 0o644); err != nil {
		t.Fatal(err)
	}
	oldTime := time.Now().AddDate(0, 0, -100)
	if err := os.Chtimes(oldPath, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(downloads, "recent.bin"), make([]byte, recentSize), 0o644); err != nil {
		t.Fatal(err)
	}

	// Linux also lists the system stores this machine has (the journal, core
	// dumps); the case is about the Downloads row alone.
	all := createInsightEntries()
	row := slices.IndexFunc(all, func(entry dirEntry) bool { return entry.Path == downloads })
	if row < 0 || all[row].Name != "Old Downloads (90d+)" {
		t.Fatalf("expected the Old Downloads insight, got %+v", all)
	}
	insights := all[row : row+1]
	checkJSON := func(t *testing.T) {
		t.Helper()
		result := performOverviewScanForJSONWithEntries("/", insights, insights)
		if len(result.Entries) != 1 || result.Entries[0].Size != oldSize || result.Entries[0].ScanStatus != scanComplete {
			t.Errorf("JSON Old Downloads row = %+v, want %d bytes (complete)", result.Entries, oldSize)
		}
	}
	t.Run("cold JSON", checkJSON)

	whole := performDirectoryScanForJSON(downloads)
	if whole.ScanStatus != scanComplete || whole.TotalFiles != 2 || whole.TotalSize != oldSize+recentSize {
		t.Fatalf("whole Downloads folder = %d bytes, %d files (%s)", whole.TotalSize, whole.TotalFiles, whole.ScanStatus)
	}
	if err := storeOverviewSize(downloads, whole.TotalSize); err != nil {
		t.Fatal(err)
	}
	resetOverviewSnapshotForTest()
	if size, state, err := loadStoredOverviewMeasurement(downloads); err != nil || size != whole.TotalSize || state != scanComplete {
		t.Fatalf("persisted whole-folder cache = %d, %s, %v", size, state, err)
	}
	t.Run("warm JSON", checkJSON)

	for _, cached := range []struct {
		name  string
		sizes map[string]int64
	}{
		{name: "warm TUI disk cache"},
		{name: "warm TUI memory cache", sizes: map[string]int64{downloads: whole.TotalSize}},
	} {
		t.Run(cached.name, func(t *testing.T) {
			m := model{overviewSizeCache: cached.sizes}
			m.hydrateOverviewEntries()
			index := slices.IndexFunc(m.entries, func(entry dirEntry) bool { return entry.Path == downloads })
			if index < 0 {
				t.Fatal("Old Downloads row missing from the TUI")
			}
			if size := m.entries[index].Size; size != -1 {
				t.Errorf("hydrated Old Downloads size = %d, want pending", size)
			}
			measured := scanOverviewPathCmd(downloads, index, newScanPublication(context.Background(), nil))().(overviewSizeMsg)
			if measured.Err != nil || measured.Size != oldSize {
				t.Errorf("fresh TUI measurement = %d bytes, %v, want %d bytes", measured.Size, measured.Err, oldSize)
			}
		})
	}
}

func TestOverviewPrefetchSkipsOldDownloads(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	downloads := filepath.Join(home, "Downloads")
	if err := os.Mkdir(downloads, 0o755); err != nil {
		t.Fatal(err)
	}

	// Register the actual jobs without letting the workers scan system roots.
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	var m model
	m.startOverviewPrefetch(ctx)
	if m.cachePublications[home] == nil {
		t.Fatal("ordinary overview prefetch was not scheduled")
	}
	if m.cachePublications[downloads] != nil {
		t.Error("Old Downloads was scheduled for a whole-folder prefetch")
	}
}
