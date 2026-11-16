//go:build windows

package main

import (
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestReadDirIdentityRecordsMatchesOSReadDir(t *testing.T) {
	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, "report.bin"), 4096)
	writeTestFile(t, filepath.Join(dir, "notes.txt"), 11)
	// A surrogate pair proves the name decoder matches os.ReadDir.
	writeTestFile(t, filepath.Join(dir, "\U0001F680 rocket.bin"), 5)
	if err := os.Mkdir(filepath.Join(dir, "child"), 0o755); err != nil {
		t.Fatalf("mkdir child: %v", err)
	}

	entries, err := readDirIdentityRecords(dir)
	if errors.Is(err, errIdentitiesUnavailable) {
		t.Skip("this volume does not report file IDs")
	}
	if err != nil {
		t.Fatalf("readDirIdentityRecords: %v", err)
	}
	if len(entries) != 4 {
		t.Fatalf("listed %d entries, want 4", len(entries))
	}

	byName := make(map[string]idBothDirEntry, len(entries))
	for _, entry := range entries {
		if entry.FileID == 0 {
			t.Errorf("%s has no file ID", entry.Name)
		}
		byName[entry.Name] = entry
	}

	osEntries, err := os.ReadDir(dir)
	if err != nil {
		t.Fatalf("os.ReadDir: %v", err)
	}
	for _, osEntry := range osEntries {
		entry, ok := byName[osEntry.Name()]
		if !ok {
			t.Errorf("os.ReadDir listed %s, enumeration did not", osEntry.Name())
			continue
		}
		info, infoErr := osEntry.Info()
		if infoErr != nil {
			t.Fatalf("Info(%s): %v", osEntry.Name(), infoErr)
		}
		data, ok := info.Sys().(*syscall.Win32FileAttributeData)
		if !ok {
			t.Fatalf("Info(%s) lost its attribute data", osEntry.Name())
		}
		if entry.Size != info.Size() {
			t.Errorf("%s size = %d, want %d", osEntry.Name(), entry.Size, info.Size())
		}
		if entry.Attributes != data.FileAttributes {
			t.Errorf("%s attributes = %#x, want %#x", osEntry.Name(), entry.Attributes, data.FileAttributes)
		}
		if !filetimeToTime(entry.LastWriteTime).Equal(info.ModTime()) {
			t.Errorf("%s write time = %s, want %s", osEntry.Name(), filetimeToTime(entry.LastWriteTime), info.ModTime())
		}
	}
}

func TestReadDirIdentityRecordsReportsEmptyDirectory(t *testing.T) {
	entries, err := readScanEntries(t.TempDir())
	if err != nil {
		t.Fatalf("readScanEntries: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("empty directory listed %d entries", len(entries))
	}
}

func TestReadDirIdentityRecordsSpansSeveralBuffers(t *testing.T) {
	dir := t.TempDir()
	name := strings.Repeat("n", 150)
	const fileCount = 800 // about 264 KB of names, past the 64 KiB buffer
	for index := 0; index < fileCount; index++ {
		writeTestFile(t, filepath.Join(dir, fmt.Sprintf("%s%03d", name, index)), 1)
	}

	entries, err := readDirIdentityRecords(dir)
	if errors.Is(err, errIdentitiesUnavailable) {
		t.Skip("this volume does not report file IDs")
	}
	if err != nil {
		t.Fatalf("readDirIdentityRecords: %v", err)
	}
	if len(entries) != fileCount {
		t.Fatalf("listed %d entries, want %d", len(entries), fileCount)
	}
}

func TestReadScanEntriesFallsBackWhenRecordsCannotBeDecoded(t *testing.T) {
	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, "kept.bin"), 7)
	previous := readIdentityRecords
	t.Cleanup(func() { readIdentityRecords = previous })
	for name, failure := range map[string]error{
		"malformed":   &fs.PathError{Op: "readdir", Path: dir, Err: &malformedDirBufferError{reason: "test"}},
		"unavailable": fmt.Errorf("%w: %s", errIdentitiesUnavailable, dir),
	} {
		readIdentityRecords = func(string) ([]idBothDirEntry, error) { return nil, failure }
		entries, err := readScanEntries(dir)
		if err != nil || len(entries) != 1 || entries[0].Name() != "kept.bin" || entries[0].fallback == nil {
			t.Fatalf("%s: entries %+v, error %v; want the os.ReadDir listing", name, entries, err)
		}
	}
	other := &fs.PathError{Op: "readdir", Path: dir, Err: syscall.ERROR_ACCESS_DENIED}
	readIdentityRecords = func(string) ([]idBothDirEntry, error) { return nil, other }
	if _, err := readScanEntries(dir); !errors.Is(err, syscall.ERROR_ACCESS_DENIED) {
		t.Fatalf("an access failure must not be masked by the fallback, got %v", err)
	}
}

func writeTestFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
