//go:build windows

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"testing"
)

func TestReadDirWithIdentitiesMatchesOSReadDir(t *testing.T) {
	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, "report.bin"), 4096)
	writeTestFile(t, filepath.Join(dir, "notes.txt"), 11)
	// A surrogate pair proves the name decoder matches os.ReadDir.
	writeTestFile(t, filepath.Join(dir, "\U0001F680 rocket.bin"), 5)
	if err := os.Mkdir(filepath.Join(dir, "child"), 0o755); err != nil {
		t.Fatalf("mkdir child: %v", err)
	}

	entries, hasIdentities, err := readDirWithIdentities(dir)
	if err != nil {
		t.Fatalf("readDirWithIdentities: %v", err)
	}
	if !hasIdentities {
		t.Skip("this volume does not report file IDs")
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

func TestReadDirWithIdentitiesReportsEmptyDirectory(t *testing.T) {
	entries, _, err := readDirWithIdentities(t.TempDir())
	if err != nil {
		t.Fatalf("readDirWithIdentities: %v", err)
	}
	if len(entries) != 0 {
		t.Fatalf("empty directory listed %d entries", len(entries))
	}
}

func TestReadDirWithIdentitiesSpansSeveralBuffers(t *testing.T) {
	dir := t.TempDir()
	name := strings.Repeat("n", 150)
	const fileCount = 800 // about 264 KB of names, past the 64 KiB buffer
	for index := 0; index < fileCount; index++ {
		writeTestFile(t, filepath.Join(dir, fmt.Sprintf("%s%03d", name, index)), 1)
	}

	entries, hasIdentities, err := readDirWithIdentities(dir)
	if err != nil {
		t.Fatalf("readDirWithIdentities: %v", err)
	}
	if !hasIdentities {
		t.Skip("this volume does not report file IDs")
	}
	if len(entries) != fileCount {
		t.Fatalf("listed %d entries, want %d", len(entries), fileCount)
	}
}

func writeTestFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
