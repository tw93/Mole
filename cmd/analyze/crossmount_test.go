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
