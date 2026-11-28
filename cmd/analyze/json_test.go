//go:build darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"slices"
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
	root := t.TempDir()
	home := filepath.Join(root, "home")
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	library := filepath.Join(home, "Library")
	docker := filepath.Join(library, "Containers", "com.docker.docker", "Data")
	projectLibrary := filepath.Join(home, "Project", "Library")
	independent := filepath.Join(root, "home-backup")
	const dockerSize = 2 << 20
	writeFileWithSize(t, filepath.Join(docker, "payload"), dockerSize)
	writeFileWithSize(t, filepath.Join(library, "other"), 128<<10)
	writeFileWithSize(t, filepath.Join(projectLibrary, "payload"), 256<<10)
	writeFileWithSize(t, filepath.Join(independent, "payload"), 512<<10)

	insights := createInsightEntries()
	if len(insights) != 1 || insights[0].Name != "Docker Data" || insights[0].Path != docker {
		t.Fatalf("expected the real Docker insight, got %#v", insights)
	}
	rows := slices.DeleteFunc(createOverviewEntriesWithInsights(insights), func(row dirEntry) bool {
		return row.Path != home && row.Path != library && row.Path != docker
	})
	rows = append(rows,
		dirEntry{Name: "Project Library", Path: projectLibrary, IsDir: true},
		dirEntry{Name: "Independent", Path: independent, IsDir: true},
	)

	for _, source := range []string{"fresh", "cached"} {
		t.Run(source, func(t *testing.T) {
			// The second pass reads the first pass's measurements from disk.
			resetOverviewSnapshotForTest()
			result := performOverviewScanForJSONWithEntries("/", insights, rows)
			if result.ScanStatus != scanComplete || len(result.Entries) != len(rows) {
				t.Fatalf("expected every row to remain complete, got %#v", result)
			}
			homeRow := requireJSONOverviewEntry(t, result, home)
			libraryRow := requireJSONOverviewEntry(t, result, library)
			dockerRow := requireJSONOverviewEntry(t, result, docker)
			projectRow := requireJSONOverviewEntry(t, result, projectLibrary)
			independentRow := requireJSONOverviewEntry(t, result, independent)
			if !dockerRow.Insight || dockerRow.Size < dockerSize || libraryRow.Size <= dockerRow.Size {
				t.Fatalf("Docker's bytes must be measured in both rows: Library=%+v Docker=%+v", libraryRow, dockerRow)
			}
			if projectRow.Size < 256<<10 || homeRow.Size < projectRow.Size || homeRow.Size >= dockerSize || independentRow.Size < 512<<10 {
				t.Fatalf("expected Home to cover Project Library, with separate User Library and sibling: %#v", result.Entries)
			}
			want := homeRow.Size + libraryRow.Size + independentRow.Size
			if result.TotalSize != want {
				t.Fatalf("total_size = %d, want %d (Home=%d, User Library=%d, independent=%d)", result.TotalSize, want, homeRow.Size, libraryRow.Size, independentRow.Size)
			}
		})
	}
}

func TestOverviewJSONTotalUsesCompleteParentForSparseOldDownload(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	downloads := filepath.Join(home, "Downloads")
	oldPath := filepath.Join(downloads, "old.img")
	writeFileWithSize(t, oldPath, 4096)
	const logicalSize = 32 << 20
	if err := os.Truncate(oldPath, logicalSize); err != nil {
		t.Fatal(err)
	}
	oldTime := time.Now().AddDate(0, 0, -100)
	if err := os.Chtimes(oldPath, oldTime, oldTime); err != nil {
		t.Fatal(err)
	}

	insights := createInsightEntries()
	if len(insights) != 1 || insights[0].Path != downloads {
		t.Fatalf("expected the Old Downloads insight, got %+v", insights)
	}
	rows := append([]dirEntry{{Name: "Home", Path: home, IsDir: true}}, insights...)
	result := performOverviewScanForJSONWithEntries("/", insights, rows)
	homeRow := requireJSONOverviewEntry(t, result, home)
	oldDownloads := requireJSONOverviewEntry(t, result, downloads)
	if result.ScanStatus != scanComplete || homeRow.Size <= 0 || homeRow.Size >= logicalSize || oldDownloads.Size != logicalSize {
		t.Fatalf("expected a complete disk measurement and a larger apparent file size, got %+v", result.Entries)
	}
	if result.TotalSize != homeRow.Size {
		t.Fatalf("total_size = %d, want the complete Home measurement (%d)", result.TotalSize, homeRow.Size)
	}
	standalone := performOverviewScanForJSONWithEntries("/", insights, insights)
	if standalone.TotalSize != 4096 || len(standalone.Entries) != 1 || standalone.Entries[0].Size != logicalSize {
		t.Fatalf("standalone Old Downloads should keep its detail and contribute only allocated bytes: %+v", standalone)
	}
}

func TestOverviewJSONTotalKeepsSeparateVolume(t *testing.T) {
	fx := newCrossMountFixture(t)
	t.Setenv("HOME", fx.root)
	nested := filepath.Dir(fx.mountedBig)
	rows := []dirEntry{
		{Name: "Home", Path: fx.root, IsDir: true},
		{Name: "Volume", Path: fx.mountPoint, IsDir: true},
		{Name: "Nested", Path: nested, IsDir: true},
	}
	result := performOverviewScanForJSONWithEntries("/", nil, rows)
	if result.ScanStatus != scanComplete || len(result.Entries) != len(rows) {
		t.Fatalf("expected three complete measurements, got %#v", result)
	}
	home := requireJSONOverviewEntry(t, result, fx.root)
	volume := requireJSONOverviewEntry(t, result, fx.mountPoint)
	child := requireJSONOverviewEntry(t, result, nested)
	if home.Size <= 0 || home.Size >= 1<<20 || child.Size < 1<<20 || volume.Size < child.Size {
		t.Fatalf("expected Home to skip the simulated mount and Volume to cover its child: %#v", result.Entries)
	}
	if want := home.Size + volume.Size; result.TotalSize != want {
		t.Fatalf("total_size = %d, want %d (Home=%d, Volume=%d)", result.TotalSize, want, home.Size, volume.Size)
	}
}

func TestOverviewJSONTotalKeepsDataBeyondSymlink(t *testing.T) {
	root := t.TempDir()
	t.Setenv("HOME", root)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	library := filepath.Join(root, "Library")
	external := filepath.Join(root, "external")
	writeFileWithSize(t, filepath.Join(library, "local"), 128<<10)
	writeFileWithSize(t, filepath.Join(external, "uv", "payload"), 2<<20)
	linked := filepath.Join(library, "Caches")
	if err := os.Symlink(external, linked); err != nil {
		t.Fatal(err)
	}

	uv := filepath.Join(linked, "uv")
	rows := []dirEntry{{Name: "User Library", Path: library, IsDir: true}, {Name: "uv Cache", Path: uv, IsDir: true}}
	result := performOverviewScanForJSONWithEntries("/", rows[1:], rows)
	parent := requireJSONOverviewEntry(t, result, library)
	child := requireJSONOverviewEntry(t, result, uv)
	if result.ScanStatus != scanComplete || parent.Size < 128<<10 || parent.Size >= 2<<20 || child.Size < 2<<20 {
		t.Fatalf("expected the parent walk to stop at its symlink: %+v", result.Entries)
	}
	if want := parent.Size + child.Size; result.TotalSize != want {
		t.Fatalf("total_size = %d, want both separately measured sizes (%d)", result.TotalSize, want)
	}
}

func TestOverviewJSONTotalWithIncompleteParent(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission fixture requires an unprivileged user")
	}
	for _, tc := range []struct {
		name        string
		restrict    string
		mode        os.FileMode
		parentState scanState
		wantDocker  bool
	}{
		{"partial parent saw Docker", "blocked", 0o000, scanPartial, false},
		{"partial parent missed Docker", "Containers", 0o111, scanPartial, true},
		{"unavailable parent", ".", 0o111, scanUnavailable, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			library := filepath.Join(home, "Library")
			docker := filepath.Join(library, "Containers", "com.docker.docker", "Data")
			writeFileWithSize(t, filepath.Join(docker, "payload"), 2<<20)
			writeFileWithSize(t, filepath.Join(library, "other"), 128<<10)
			writeFileWithSize(t, filepath.Join(library, "blocked", "payload"), 64<<10)
			restricted := filepath.Join(library, tc.restrict)
			if err := os.Chmod(restricted, tc.mode); err != nil {
				t.Fatal(err)
			}
			t.Cleanup(func() { _ = os.Chmod(restricted, 0o755) })

			insight := dirEntry{Name: "Docker Data", Path: docker, IsDir: true}
			rows := []dirEntry{{Name: "User Library", Path: library, IsDir: true}, insight}
			result := performOverviewScanForJSONWithEntries("/", []dirEntry{insight}, rows)
			parent := requireJSONOverviewEntry(t, result, library)
			child := requireJSONOverviewEntry(t, result, docker)
			if result.ScanStatus != scanPartial || parent.ScanStatus != tc.parentState ||
				child.ScanStatus != scanComplete || child.Size < 2<<20 || !child.Insight {
				t.Fatalf("expected an incomplete overview with a measurable Docker row, got %#v", result)
			}
			want := parent.Size
			if tc.wantDocker {
				want = child.Size
			}
			if (parent.Size < child.Size) != tc.wantDocker || (parent.Size > 0) != (tc.parentState == scanPartial) {
				t.Fatalf("parent and child sizes do not exercise %s: Library=%d Docker=%d", tc.name, parent.Size, child.Size)
			}
			if tc.restrict == "Containers" {
				want += parent.Size
			}
			if result.TotalSize != want {
				t.Fatalf("total_size = %d, want %d (partial Library=%d, Docker=%d)", result.TotalSize, want, parent.Size, child.Size)
			}
		})
	}
}

func TestOverviewJSONTotalWithHomeDirectoryCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	library := filepath.Join(home, "Library")
	writeFileWithSize(t, filepath.Join(library, "payload"), 2<<20)
	writeFileWithSize(t, filepath.Join(home, "personal"), 128<<10)
	var files, dirs, bytes int64
	result, err := scanPathConcurrentWithOptions(t.Context(), home, &files, &dirs, &bytes, nil, false, 0)
	if err != nil || result.State != scanComplete || result.TotalSize < 2<<20 {
		t.Fatalf("expected a complete directory scan including Library, got %#v, %v", result, err)
	}
	if err := saveCacheToDisk(home, result); err != nil {
		t.Fatal(err)
	}
	// Previous releases also saved Home snapshots without their scope.
	if err := storeOverviewSize(home, result.TotalSize); err != nil {
		t.Fatal(err)
	}
	rows := []dirEntry{{Name: "Home", Path: home, IsDir: true}, {Name: "User Library", Path: library, IsDir: true}}
	overview := performOverviewScanForJSONWithEntries("/", nil, rows)
	homeRow := requireJSONOverviewEntry(t, overview, home)
	libraryRow := requireJSONOverviewEntry(t, overview, library)
	if overview.ScanStatus != scanComplete || homeRow.Size < 128<<10 || homeRow.Size >= 2<<20 || libraryRow.Size < 2<<20 {
		t.Fatalf("expected Home to exclude Library despite the whole-folder cache, got %#v", overview)
	}
	if want := homeRow.Size + libraryRow.Size; overview.TotalSize != want {
		t.Fatalf("total_size = %d, want %d (scoped Home + Library)", overview.TotalSize, want)
	}
}

func TestOverviewJSONTotalUsesLargestCoveredMeasurementForPartialParent(t *testing.T) {
	root := t.TempDir()
	docker := filepath.Join(root, "Docker")
	logs := filepath.Join(root, "Logs")
	for _, path := range []string{docker, logs} {
		if err := os.Mkdir(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	rows := []jsonOverviewMeasurement{
		{dirEntry: dirEntry{Path: root, Size: 6, State: scanPartial}},
		{dirEntry: dirEntry{Path: docker, Size: 4, State: scanComplete}},
		{dirEntry: dirEntry{Path: logs, Size: 4, State: scanComplete}},
	}
	if got := overviewTotalSize(rows); got != 6 {
		t.Fatalf("total_size = %d, want the larger measured scope (6)", got)
	}
}

func TestOverviewJSONTotalRefreshesCachedParentWhenChildAppears(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	library := filepath.Join(home, "Library")
	writeFileWithSize(t, filepath.Join(library, "existing"), 128<<10)
	rows := []dirEntry{{Name: "User Library", Path: library, IsDir: true}}
	before := performOverviewScanForJSONWithEntries("/", nil, rows)
	if before.ScanStatus != scanComplete || before.TotalSize < 128<<10 {
		t.Fatalf("expected to cache the initial Library, got %+v", before)
	}

	docker := filepath.Join(library, "Containers", "com.docker.docker", "Data")
	writeFileWithSize(t, filepath.Join(docker, "payload"), 2<<20)
	insights := createInsightEntries()
	resetOverviewSnapshotForTest()
	after := performOverviewScanForJSONWithEntries("/", insights, append(rows, insights...))
	libraryRow := requireJSONOverviewEntry(t, after, library)
	dockerRow := requireJSONOverviewEntry(t, after, docker)
	if after.ScanStatus != scanComplete || dockerRow.Size < 2<<20 || libraryRow.Size < before.TotalSize+dockerRow.Size ||
		after.TotalSize != libraryRow.Size {
		t.Fatalf("expected a refreshed Library measurement covering Docker, got %+v", after)
	}
}

func TestOverviewJSONTotalKeepsScopedHomeAfterWholeDirectoryWrite(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	library := filepath.Join(home, "Library")
	writeFileWithSize(t, filepath.Join(home, "personal"), 128<<10)
	writeFileWithSize(t, filepath.Join(library, "payload"), 2<<20)
	rows := []dirEntry{{Name: "Home", Path: home, IsDir: true}, {Name: "User Library", Path: library, IsDir: true}}
	overview := performOverviewScanForJSONWithEntries("/", nil, rows)
	homeRow := requireJSONOverviewEntry(t, overview, home)
	if err := storeOverviewSize(home, overview.TotalSize); err != nil {
		t.Fatal(err)
	}

	resetOverviewSnapshotForTest()
	snapshot, err := loadStoredOverviewSnapshot(home)
	if err != nil || snapshot.Size != homeRow.Size || snapshot.ExcludedPath != library {
		t.Fatalf("expected the scoped Home snapshot after a full-directory write, got %+v, %v", snapshot, err)
	}
}

func TestOverviewJSONTotalRefreshesAfterMountBoundaryChanges(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	mount := filepath.Join(home, "volume")
	writeFileWithSize(t, filepath.Join(home, "personal"), 128<<10)
	writeFileWithSize(t, filepath.Join(mount, "payload"), 2<<20)
	rows := []dirEntry{{Name: "Home", Path: home, IsDir: true}, {Name: "Volume", Path: mount, IsDir: true}}

	before := performOverviewScanForJSONWithEntries("/", nil, rows)
	beforeHome := requireJSONOverviewEntry(t, before, home)
	if before.ScanStatus != scanComplete || before.TotalSize != beforeHome.Size || beforeHome.Size < 2<<20 {
		t.Fatalf("expected the initial Home size to cover the local directory, got %+v", before)
	}

	useMountedDirectoryStub(t, mount)
	resetOverviewSnapshotForTest()
	after := performOverviewScanForJSONWithEntries("/", nil, rows)
	afterHome := requireJSONOverviewEntry(t, after, home)
	afterVolume := requireJSONOverviewEntry(t, after, mount)
	if after.ScanStatus != scanComplete || afterHome.Size >= 2<<20 || afterVolume.Size < 2<<20 ||
		after.TotalSize != afterHome.Size+afterVolume.Size {
		t.Fatalf("expected Home to refresh and the volume to count separately, got %+v", after)
	}
}

func requireJSONOverviewEntry(t *testing.T, result jsonOutput, path string) jsonEntry {
	t.Helper()
	for _, entry := range result.Entries {
		if entry.Path == path {
			return entry
		}
	}
	t.Fatalf("overview row for %q missing from %#v", path, result.Entries)
	return jsonEntry{}
}
