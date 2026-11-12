//go:build darwin

package main

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

// crossMountFixture builds a scan root holding a local file, a local
// directory and a directory that the stubbed fileDevice reports as another
// file system, the way an attached disk image or network share looks to stat.
type crossMountFixture struct {
	root       string
	mountPoint string
	localSize  int64
	mountedBig string
}

func newCrossMountFixture(t *testing.T) crossMountFixture {
	t.Helper()
	root := t.TempDir()

	local := filepath.Join(root, "local")
	if err := os.MkdirAll(local, 0o755); err != nil {
		t.Fatalf("create local dir: %v", err)
	}
	rootFile := filepath.Join(root, "root.txt")
	localFile := filepath.Join(local, "data.bin")
	if err := os.WriteFile(rootFile, []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root file: %v", err)
	}
	if err := os.WriteFile(localFile, []byte(strings.Repeat("l", 64)), 0o644); err != nil {
		t.Fatalf("write local file: %v", err)
	}

	mountPoint := filepath.Join(root, "mnt")
	nested := filepath.Join(mountPoint, "nested")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("create mount point: %v", err)
	}
	mountedBig := filepath.Join(nested, "runtime.bin")
	if err := os.WriteFile(mountedBig, make([]byte, 1<<20), 0o644); err != nil {
		t.Fatalf("write mounted file: %v", err)
	}

	var localSize int64
	for _, path := range []string{rootFile, localFile} {
		info, err := os.Lstat(path)
		if err != nil {
			t.Fatalf("stat %s: %v", path, err)
		}
		localSize += getActualFileSize(path, info)
	}

	useMountedDirectoryStub(t, mountPoint)
	return crossMountFixture{root: root, mountPoint: mountPoint, localSize: localSize, mountedBig: mountedBig}
}

// useMountedDirectoryStub makes mountPoint and everything below it report a
// device other than the real one, so traversal sees a file system boundary.
func useMountedDirectoryStub(t *testing.T, mountPoint string) {
	t.Helper()
	previous := fileDevice
	fileDevice = func(path string, info fs.FileInfo) (uint64, bool) {
		dev, ok := previous(path, info)
		if path == mountPoint || strings.HasPrefix(path, mountPoint+string(filepath.Separator)) {
			return dev + 1, ok
		}
		return dev, ok
	}
	t.Cleanup(func() { fileDevice = previous })
}

func TestScanPathConcurrentStopsAtMountPoints(t *testing.T) {
	fx := newCrossMountFixture(t)

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")
	result, err := scanPathConcurrent(context.Background(), fx.root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent returned error: %v", err)
	}

	if result.TotalSize != fx.localSize {
		t.Fatalf("total size = %d, want %d (contents of the mounted volume must not count)", result.TotalSize, fx.localSize)
	}
	if result.State != scanComplete {
		t.Fatalf("state = %v, want complete: stopping at a mount point is not a failure", result.State)
	}

	// The mount point stays a browsable row, sized as the parent sees it.
	var mountRow *dirEntry
	for i := range result.Entries {
		if result.Entries[i].Path == fx.mountPoint {
			mountRow = &result.Entries[i]
		}
	}
	if mountRow == nil {
		t.Fatalf("mount point row missing from entries: %+v", result.Entries)
	}
	if !mountRow.IsDir || mountRow.Size != 0 {
		t.Fatalf("mount point row = %+v, want a directory of size 0", *mountRow)
	}

	for _, file := range result.LargeFiles {
		if file.Path == fx.mountedBig {
			t.Fatalf("large files list includes %s from the mounted volume", file.Path)
		}
	}
}

func TestScanPathConcurrentMeasuresMountedVolumeAsRoot(t *testing.T) {
	fx := newCrossMountFixture(t)

	// Opening the mount point itself scans that volume normally.
	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")
	result, err := scanPathConcurrent(context.Background(), fx.mountPoint, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent returned error: %v", err)
	}
	if result.TotalSize < 1<<20 {
		t.Fatalf("total size = %d, want the mounted contents (>= 1 MiB) when the mount point is the root", result.TotalSize)
	}
}

func TestCalculateDirSizeFastStopsAtMountPoints(t *testing.T) {
	fx := newCrossMountFixture(t)

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")
	size, err := calculateDirSizeFast(context.Background(), fx.root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("calculateDirSizeFast returned error: %v", err)
	}
	if size != fx.localSize {
		t.Fatalf("size = %d, want %d (contents of the mounted volume must not count)", size, fx.localSize)
	}
}

func TestGetDirectoryLogicalSizeStopsAtMountPoints(t *testing.T) {
	fx := newCrossMountFixture(t)

	size, err := getDirectoryLogicalSizeWithExclude(context.Background(), fx.root, "", nil)
	if err != nil {
		t.Fatalf("getDirectoryLogicalSizeWithExclude returned error: %v", err)
	}
	if size != fx.localSize {
		t.Fatalf("size = %d, want %d (contents of the mounted volume must not count)", size, fx.localSize)
	}
}

func findEntry(entries []dirEntry, path string) (dirEntry, bool) {
	for _, entry := range entries {
		if entry.Path == path {
			return entry, true
		}
	}
	return dirEntry{}, false
}

// The interactive TUI discovers children through the live scan, which queues
// each directory as its own scan root. A mount point queued that way would be
// measured from its own device, so it must be caught before it is queued.
func TestLiveScanStopsAtMountPoints(t *testing.T) {
	t.Setenv("HOME", scanHome(t))
	fx := newCrossMountFixture(t)

	m := newModel(fx.root, false)
	start := m.scanBypassingCacheCmd(fx.root)().(liveScanStartMsg)
	defer cancelAndDrainLiveScan(start)
	msg := drainLiveScanToResultMsg(t, start)
	if msg.err != nil {
		t.Fatalf("live scan returned error: %v", msg.err)
	}
	if msg.result.TotalSize != fx.localSize {
		t.Fatalf("live total = %d, want %d (contents of the mounted volume must not count)", msg.result.TotalSize, fx.localSize)
	}
	row, ok := findEntry(msg.result.Entries, fx.mountPoint)
	if !ok || !row.IsMount || row.Size != 0 {
		t.Fatalf("mount point row = %+v (found %v), want a size-0 mount row", row, ok)
	}

	// Completing the scan in the model keeps the row browsable.
	m.finishLiveScan(msg.result)
	if _, ok := findEntry(m.entries, fx.mountPoint); !ok {
		t.Fatalf("finishLiveScan dropped the mount point row: %+v", m.entries)
	}
}

// Mount rows read 0 bytes on purpose; the empty-entry filter that every
// completion and cached-history path applies must not drop them.
func TestFinishLiveScanKeepsMountRows(t *testing.T) {
	fx := newCrossMountFixture(t)

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")
	result, err := scanPathConcurrent(context.Background(), fx.root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent returned error: %v", err)
	}
	empty := dirEntry{Name: "empty", Path: filepath.Join(fx.root, "empty"), IsDir: true, State: scanComplete}
	result.Entries = append(result.Entries, empty)

	m := model{path: fx.root, width: 80, height: 24, cache: make(map[string]historyEntry), overviewSizeCache: map[string]int64{}}
	m.finishLiveScan(result)

	row, ok := findEntry(m.entries, fx.mountPoint)
	if !ok || !row.IsMount {
		t.Fatalf("mount point row missing after finishLiveScan: %+v", m.entries)
	}
	// Positive control: an ordinary empty directory is still filtered out.
	if _, ok := findEntry(m.entries, empty.Path); ok {
		t.Fatalf("empty non-mount row survived the filter: %+v", m.entries)
	}
}

// Cursor movement skips zero-size rows; a mount row must still be reachable.
func TestCursorStopsOnMountRows(t *testing.T) {
	root := t.TempDir()
	entries := []dirEntry{
		{Name: "big", Path: filepath.Join(root, "big"), Size: 4096, IsDir: true},
		{Name: "mnt", Path: filepath.Join(root, "mnt"), IsDir: true, IsMount: true},
		{Name: "pending", Path: filepath.Join(root, "pending"), IsDir: true},
	}
	m := model{path: root, width: 80, height: 24, entries: entries, entriesAll: entries, cache: make(map[string]historyEntry)}

	updated, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyDown})
	m = updated.(model)
	if m.selected != 1 {
		t.Fatalf("down from first row selected %d, want 1 (the mount row)", m.selected)
	}
	m.selected = 2
	updated, _ = m.updateKey(tea.KeyMsg{Type: tea.KeyUp})
	m = updated.(model)
	if m.selected != 1 {
		t.Fatalf("up from last row selected %d, want 1 (the mount row)", m.selected)
	}
}

// mdfind -onlyin descends into mounted volumes, so Spotlight candidates need
// the same device boundary as the walk before they can replace its list.
func TestSpotlightLargeFilesStopAtMountPoints(t *testing.T) {
	fx := newCrossMountFixture(t)
	localBig := filepath.Join(fx.root, "local", "data.bin")
	if isInFoldedDir(localBig) {
		// Spotlight drops candidates under folded names such as "tmp", so the
		// positive control cannot run when TMPDIR sits below one.
		t.Skipf("temp dir %s is below a folded directory", fx.root)
	}

	originalRunner := spotlightQueryRunner
	t.Cleanup(func() { spotlightQueryRunner = originalRunner })
	spotlightPaths := func(path string) []string {
		t.Helper()
		spotlightQueryRunner = func(_ context.Context, _, _ string) ([]byte, error) {
			return []byte(path + "\n"), nil
		}
		files, err := findLargeFilesWithSpotlight(context.Background(), fx.root, 1)
		if err != nil {
			t.Fatalf("findLargeFilesWithSpotlight(%s) returned error: %v", path, err)
		}
		paths := make([]string, 0, len(files))
		for _, file := range files {
			paths = append(paths, file.Path)
		}
		return paths
	}

	// Positive control: a local candidate is kept.
	if got := spotlightPaths(localBig); len(got) != 1 || got[0] != localBig {
		t.Fatalf("Spotlight large files = %q, want [%s]", got, localBig)
	}
	if got := spotlightPaths(fx.mountedBig); len(got) != 0 {
		t.Fatalf("Spotlight large files = %q, want none from the mounted volume", got)
	}
}
