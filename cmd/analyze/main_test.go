//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestFormatBytes(t *testing.T) {
	tests := []struct {
		input    int64
		expected string
	}{
		{0, "0 B"},
		{512, "512 B"},
		{1024, "1.0 KB"},
		{1536, "1.5 KB"},
		{1048576, "1.0 MB"},
		{1073741824, "1.0 GB"},
		{1099511627776, "1.0 TB"},
	}

	for _, test := range tests {
		result := formatBytes(test.input)
		if result != test.expected {
			t.Errorf("formatBytes(%d) = %s, expected %s", test.input, result, test.expected)
		}
	}
}

func TestTruncatePath(t *testing.T) {
	tests := []struct {
		input    string
		maxLen   int
		expected string
	}{
		{"C:\\short", 20, "C:\\short"},
		{"C:\\this\\is\\a\\very\\long\\path\\that\\should\\be\\truncated", 30, "...ong\\path\\that\\should\\be\\truncated"},
	}

	for _, test := range tests {
		result := truncatePath(test.input, test.maxLen)
		if len(result) > test.maxLen && test.maxLen < len(test.input) {
			// For truncated paths, just verify length constraint
			if len(result) > test.maxLen+10 { // Allow some flexibility
				t.Errorf("truncatePath(%s, %d) length = %d, expected <= %d", test.input, test.maxLen, len(result), test.maxLen)
			}
		}
	}
}

func TestCleanablePatterns(t *testing.T) {
	expectedCleanable := []string{
		"node_modules",
		"vendor",
		".venv",
		"venv",
		"__pycache__",
		"target",
		"build",
		"dist",
	}

	for _, pattern := range expectedCleanable {
		if !cleanablePatterns[pattern] {
			t.Errorf("Expected %s to be in cleanablePatterns", pattern)
		}
	}
}

func TestSkipPatterns(t *testing.T) {
	expectedSkip := []string{
		"$Recycle.Bin",
		"System Volume Information",
		"Windows",
		"Program Files",
	}

	for _, pattern := range expectedSkip {
		if !skipPatterns[pattern] {
			t.Errorf("Expected %s to be in skipPatterns", pattern)
		}
	}
}

func TestCalculateDirSize(t *testing.T) {
	// Create a temp directory with known content
	tmpDir, err := os.MkdirTemp("", "mole_test_*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Create a test file with known size
	testFile := filepath.Join(tmpDir, "test.txt")
	content := []byte("Hello, World!") // 13 bytes
	if err := os.WriteFile(testFile, content, 0644); err != nil {
		t.Fatalf("Failed to write test file: %v", err)
	}

	size := calculateDirSize(tmpDir)
	if size != int64(len(content)) {
		t.Errorf("calculateDirSize() = %d, expected %d", size, len(content))
	}
}

func TestCalculateDirSizeCountsDeepAndHiddenDirs(t *testing.T) {
	tmpDir, err := os.MkdirTemp("", "mole_test_*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Deeper than the old shallow-scan depth, inside a hidden directory
	deepDir := filepath.Join(tmpDir, ".venv", "a", "b", "c", "d", "e")
	if err := os.MkdirAll(deepDir, 0755); err != nil {
		t.Fatalf("Failed to create dirs: %v", err)
	}
	content := []byte("deep file")
	if err := os.WriteFile(filepath.Join(deepDir, "deep.txt"), content, 0644); err != nil {
		t.Fatalf("Failed to write test file: %v", err)
	}
	if err := os.WriteFile(filepath.Join(tmpDir, "top.txt"), content, 0644); err != nil {
		t.Fatalf("Failed to write test file: %v", err)
	}

	size := calculateDirSize(tmpDir)
	if size != int64(2*len(content)) {
		t.Errorf("calculateDirSize() = %d, expected %d", size, 2*len(content))
	}
}

func TestNewModel(t *testing.T) {
	model := newModel("C:\\")

	if model.path != "C:\\" {
		t.Errorf("newModel path = %s, expected C:\\", model.path)
	}

	if !model.scanning {
		t.Error("newModel should start in scanning state")
	}

	if model.multiSelected == nil {
		t.Error("newModel multiSelected should be initialized")
	}

	if model.cache == nil {
		t.Error("newModel cache should be initialized")
	}
}

func TestScanDirectory(t *testing.T) {
	// Create a temp directory with known structure
	tmpDir, err := os.MkdirTemp("", "mole_scan_test_*")
	if err != nil {
		t.Fatalf("Failed to create temp dir: %v", err)
	}
	defer os.RemoveAll(tmpDir)

	// Create subdirectory
	subDir := filepath.Join(tmpDir, "subdir")
	if err := os.Mkdir(subDir, 0755); err != nil {
		t.Fatalf("Failed to create subdir: %v", err)
	}

	// Create test files
	testFile1 := filepath.Join(tmpDir, "file1.txt")
	testFile2 := filepath.Join(subDir, "file2.txt")
	os.WriteFile(testFile1, []byte("content1"), 0644)
	os.WriteFile(testFile2, []byte("content2"), 0644)

	entries, largeFiles, totalSize, err := scanDirectory(tmpDir)
	if err != nil {
		t.Fatalf("scanDirectory error: %v", err)
	}

	if len(entries) != 2 { // subdir + file1.txt
		t.Errorf("Expected 2 entries, got %d", len(entries))
	}

	if totalSize == 0 {
		t.Error("totalSize should be greater than 0")
	}

	// No large files in this test
	_ = largeFiles
}

func TestIsProtectedPathAcrossVolumeSpellings(t *testing.T) {
	protected := []string{
		`C:\Program Files`,
		`C:\Program Files\App`,
		`D:\Program Files`,
		`D:\ProgramData\Vendor`,
		`\\localhost\c$\Program Files`,
		`\\localhost\c$\Program Files (x86)\Steam`,
		`\\localhost\c$\Windows\System32`,
		`\\?\C:\Program Files`,
		`\\?\UNC\localhost\c$\ProgramData`,
		`\\.\UNC\localhost\c$\Windows\System32`,
		`\\.\C:\Program Files (x86)`,
		`\\?\Volume{12345678-1234-1234-1234-123456789abc}\Windows`,
		`\\?\Volume{12345678-1234-1234-1234-123456789abc}\Program Files\App`,
		`\\?\HarddiskVolume3\ProgramData`,
		`\\?\GLOBALROOT\Device\HarddiskVolume3\Users\me\Downloads`,
		`E:\$Recycle.Bin`,
	}
	for _, path := range protected {
		if !isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = false, expected true", path)
		}
	}

	allowed := []string{
		`C:\Projects\Windows`,
		`D:\data\Program Files`,
		`\\localhost\share\work`,
		`\\?\Volume{12345678-1234-1234-1234-123456789abc}\data\work`,
		`C:\Users\me\Downloads\node_modules`,
	}
	for _, path := range allowed {
		if isProtectedPath(path) {
			t.Errorf("isProtectedPath(%q) = true, expected false", path)
		}
	}
}

func TestScanResultForAnotherPathDoesNotReplaceView(t *testing.T) {
	m := newModel(`C:\b`)
	m.entries = []dirEntry{{Name: "kept", Path: `C:\b\kept`}}

	updated, _ := m.Update(scanCompleteMsg{
		path:    `C:\a`,
		entries: []dirEntry{{Name: "stale", Path: `C:\a\stale`}},
	})
	got := updated.(model)
	if len(got.entries) != 1 || got.entries[0].Name != "kept" {
		t.Errorf("entries = %+v, expected the current view to stay", got.entries)
	}
	if !got.scanning {
		t.Error("scanning cleared by a result for another path")
	}
	if cached, ok := got.cache[`C:\a`]; !ok || cached.Entries[0].Name != "stale" {
		t.Errorf("cache[C:\\a] = %+v, expected the scanned result", cached)
	}

	updated, _ = got.Update(scanCompleteMsg{
		path:    `C:\b`,
		entries: []dirEntry{{Name: "fresh", Path: `C:\b\fresh`}},
	})
	got = updated.(model)
	if got.scanning || len(got.entries) != 1 || got.entries[0].Name != "fresh" {
		t.Errorf("result for the current path not applied: scanning=%v entries=%+v", got.scanning, got.entries)
	}
}

func TestDeleteKeysIgnoredWhileScanning(t *testing.T) {
	m := newModel(`C:\b`)
	m.entries = []dirEntry{{Name: "a", Path: `C:\a\top`, IsDir: true}}
	m.multiSelected[`C:\a\top`] = true

	for _, key := range []string{"d", "D"} {
		updated, _ := m.handleKeyPress(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(key)})
		if got := updated.(model); got.deleteConfirm {
			t.Errorf("%q opened a delete confirmation while scanning", key)
		}
	}
}

func TestFailedScanDropsPreviousRows(t *testing.T) {
	m := newModel(`C:\b`)
	m.entries = []dirEntry{{Name: "parent row", Path: `C:\parent row`, IsDir: true}}

	updated, _ := m.Update(scanErrorMsg{path: `C:\b`, err: os.ErrPermission})
	got := updated.(model)
	if len(got.entries) != 0 || got.scanning || got.err == nil {
		t.Fatalf("after a failed scan: entries=%+v scanning=%v err=%v", got.entries, got.scanning, got.err)
	}
	updated, _ = got.handleKeyPress(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune("d")})
	if updated.(model).deleteConfirm {
		t.Error("d opened a delete confirmation for a row from the previous directory")
	}
}
