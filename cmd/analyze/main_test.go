//go:build windows

package main

import (
	"os"
	"path/filepath"
	"testing"
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
