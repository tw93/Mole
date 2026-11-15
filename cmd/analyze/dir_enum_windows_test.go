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

func TestDecodeDirNameMatchesPortableDecoder(t *testing.T) {
	units := []uint16{'a', 0xD83D, 0xDE80, 0x4E2D} // "a", surrogate pair, CJK
	if got, want := decodeDirName(units), portableUTF16ToString(units); got != want {
		t.Fatalf("decodeDirName = %q, portable decoder = %q", got, want)
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

func TestReadDirWithIdentitiesSharesFileIDAcrossHardLinks(t *testing.T) {
	dir := t.TempDir()
	original := filepath.Join(dir, "original.bin")
	link := filepath.Join(dir, "linked.bin")
	writeTestFile(t, original, 8192)
	if err := os.Link(original, link); err != nil {
		t.Skipf("this volume cannot create hard links: %v", err)
	}

	entries, hasIdentities, err := readDirWithIdentities(dir)
	if err != nil {
		t.Fatalf("readDirWithIdentities: %v", err)
	}
	if !hasIdentities {
		t.Skip("this volume does not report file IDs")
	}
	ids := make(map[string]uint64, len(entries))
	for _, entry := range entries {
		ids[entry.Name] = entry.FileID
	}
	if ids["original.bin"] == 0 || ids["original.bin"] != ids["linked.bin"] {
		t.Fatalf("hard links report file IDs %#x and %#x, want one shared non-zero ID",
			ids["original.bin"], ids["linked.bin"])
	}
	if len(ids) == 0 {
		t.Fatal("listed no entries")
	}
}

func TestReadDirWithIdentitiesKeepsDistinctFilesApart(t *testing.T) {
	dir := t.TempDir()
	writeTestFile(t, filepath.Join(dir, "one.bin"), 16)
	writeTestFile(t, filepath.Join(dir, "two.bin"), 16)

	entries, hasIdentities, err := readDirWithIdentities(dir)
	if err != nil {
		t.Fatalf("readDirWithIdentities: %v", err)
	}
	if !hasIdentities {
		t.Skip("this volume does not report file IDs")
	}
	if len(entries) != 2 || entries[0].FileID == entries[1].FileID {
		t.Fatalf("two distinct files report file IDs %#x and %#x", entries[0].FileID, entries[1].FileID)
	}
}

func writeTestFile(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
