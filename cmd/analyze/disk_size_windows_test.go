//go:build windows

package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"unsafe"

	"golang.org/x/sys/windows"
)

// A sparse file of 64 MB length with no data written occupies almost nothing;
// the directory total must follow the allocation, not the length.
func TestDirectorySizeUsesSparseAllocation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "image.vhdx")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	var returned uint32
	if err := windows.DeviceIoControl(windows.Handle(f.Fd()), windows.FSCTL_SET_SPARSE, nil, 0, nil, 0, &returned, nil); err != nil {
		f.Close()
		t.Skipf("volume does not support sparse files: %v", err)
	}
	const length = 64 << 20
	if err := f.Truncate(length); err != nil {
		f.Close()
		t.Fatal(err)
	}
	f.Close()

	size, err := calculateDirSizeFast(context.Background(), dir, nil, nil, nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if size >= length/2 {
		t.Fatalf("sparse file counted at %d bytes, length is %d", size, length)
	}
}

// An NTFS-compressed file of zeros occupies a fraction of its length.
func TestDirectorySizeUsesCompressedAllocation(t *testing.T) {
	dir := t.TempDir()
	path := filepath.Join(dir, "log.txt")
	f, err := os.Create(path)
	if err != nil {
		t.Fatal(err)
	}
	format := uint16(1) // COMPRESSION_FORMAT_DEFAULT
	var returned uint32
	if err := windows.DeviceIoControl(windows.Handle(f.Fd()), fsctlSetCompression, (*byte)(unsafe.Pointer(&format)), 2, nil, 0, &returned, nil); err != nil {
		f.Close()
		t.Skipf("volume does not support compression: %v", err)
	}
	const length = 16 << 20
	if _, err := f.Write(make([]byte, length)); err != nil {
		f.Close()
		t.Fatal(err)
	}
	if err := f.Sync(); err != nil {
		f.Close()
		t.Fatal(err)
	}
	f.Close()

	size, err := calculateDirSizeFast(context.Background(), dir, nil, nil, nil, nil, nil)
	if err != nil {
		t.Fatal(err)
	}
	if size >= length/2 {
		t.Fatalf("compressed file counted at %d bytes, length is %d", size, length)
	}
}

const fsctlSetCompression = 0x9C040
