//go:build darwin

package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestCreateInsightEntries(t *testing.T) {
	entries := createInsightEntries()
	// Should return at least some entries on a real Mac.
	// iOS Backups may not exist, but Old Downloads and Mail Data likely do.
	if len(entries) == 0 {
		t.Log("No insight entries found (some paths may not exist on this machine)")
	}

	// Verify all entries have required fields.
	for _, e := range entries {
		if e.Name == "" {
			t.Error("insight entry has empty Name")
		}
		if e.Path == "" {
			t.Error("insight entry has empty Path")
		}
		if e.Size != -1 {
			t.Errorf("insight entry %q should have Size=-1 (pending), got %d", e.Name, e.Size)
		}
		if !e.IsDir {
			t.Errorf("insight entry %q should be a directory", e.Name)
		}
	}
}

func TestCreateInsightEntriesIncludesOrbStackData(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	orbstackData := filepath.Join(home, "Library", "Group Containers", "HUAQ24HBR6.dev.orbstack", "data")
	if err := os.MkdirAll(orbstackData, 0755); err != nil {
		t.Fatal(err)
	}

	entries := createInsightEntries()
	for _, entry := range entries {
		if entry.Name == "OrbStack Data" {
			if entry.Path != orbstackData {
				t.Fatalf("OrbStack path = %q, want %q", entry.Path, orbstackData)
			}
			return
		}
	}
	t.Fatal("OrbStack Data insight not found")
}

func TestInsightIcon(t *testing.T) {
	// Two-icon scheme: top-level directories use 📁, every insight row
	// uses 👀 (eyes; signals "peek here" without promising deletability).
	tests := []struct {
		name string
		want string
	}{
		// Top-level dirs.
		{"Home", "📁"},
		{"User Library", "📁"},
		{"App Library", "📁"}, // Legacy name retained for backwards compatibility.
		{"Applications", "📁"},
		{"System Library", "📁"},
		// Insights collapsed to a single eyes glyph.
		{"iOS Backups", "👀"},
		{"Old Downloads (90d+)", "👀"},
		{"Homebrew Cache", "👀"},
		{"System Logs", "👀"},
		{"Xcode DerivedData", "👀"},
		{"Xcode Simulators", "👀"},
		{"Xcode Archives", "👀"},
		{"Docker Data", "👀"},
		{"OrbStack Data", "👀"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := insightIcon(dirEntry{Name: tt.name})
			if got != tt.want {
				t.Errorf("insightIcon(%q) = %q, want %q", tt.name, got, tt.want)
			}
		})
	}
}

func TestMeasureOldDownloads(t *testing.T) {
	// Create a temp directory with old and new files.
	dir := t.TempDir()

	// Create an old file (set mtime to 100 days ago).
	oldFile := filepath.Join(dir, "old.txt")
	if err := os.WriteFile(oldFile, []byte("old content here"), 0644); err != nil {
		t.Fatal(err)
	}
	oldTime := time.Now().AddDate(0, 0, -100)
	os.Chtimes(oldFile, oldTime, oldTime)

	// Create a new file.
	newFile := filepath.Join(dir, "new.txt")
	if err := os.WriteFile(newFile, []byte("new content"), 0644); err != nil {
		t.Fatal(err)
	}

	size, err := measureOldDownloads(dir, 90)
	if err != nil {
		t.Fatalf("measureOldDownloads: %v", err)
	}

	if size == 0 {
		t.Error("expected non-zero size for old files")
	}

	// Size should be approximately the size of old.txt (16 bytes) but not new.txt.
	if size > 1024 {
		t.Errorf("size %d seems too large for a 16-byte file", size)
	}
}

func TestMeasureInsightSizeFallsBackToOverview(t *testing.T) {
	// For a non-Downloads path, measureInsightSize should use measureOverviewSize.
	dir := t.TempDir()
	testFile := filepath.Join(dir, "test.dat")
	if err := os.WriteFile(testFile, make([]byte, 4096), 0644); err != nil {
		t.Fatal(err)
	}

	size, err := measureInsightSize(dir)
	if err != nil {
		t.Fatalf("measureInsightSize: %v", err)
	}
	if size == 0 {
		t.Error("expected non-zero size")
	}
}
