package main

import (
	"os"
	"path/filepath"
	"testing"
)

func TestParseMajorVersion(t *testing.T) {
	tests := []struct {
		name    string
		version string
		want    string
	}{
		{"semver", "15.17.2", "15"},
		{"major only", "18", "18"},
		{"with v prefix", "v20.11.1", "20"},
		{"empty", "", ""},
		{"psql format", "psql (PostgreSQL) 15.17", "15"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseMajorVersion(tt.version)
			if got != tt.want {
				t.Errorf("parseMajorVersion(%q) = %q, want %q", tt.version, got, tt.want)
			}
		})
	}
}

func TestFindDuplicateExtensions(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, "publisher.ext-1.0.0"), 0755)
	os.Mkdir(filepath.Join(dir, "publisher.ext-2.0.0"), 0755)
	os.Mkdir(filepath.Join(dir, "other.thing-1.0.0"), 0755)

	dups := findDuplicateExtensions(dir)
	if len(dups) != 1 {
		t.Errorf("findDuplicateExtensions() found %d duplicates, want 1", len(dups))
	}
	if len(dups) > 0 && dups[0] != "publisher.ext" {
		t.Errorf("findDuplicateExtensions() = %v, want [publisher.ext]", dups)
	}
}

func TestFindDuplicateExtensions_NoDups(t *testing.T) {
	dir := t.TempDir()
	os.Mkdir(filepath.Join(dir, "publisher.ext-1.0.0"), 0755)
	os.Mkdir(filepath.Join(dir, "other.thing-1.0.0"), 0755)

	dups := findDuplicateExtensions(dir)
	if len(dups) != 0 {
		t.Errorf("findDuplicateExtensions() found %d duplicates, want 0", len(dups))
	}
}

func TestFindDuplicateExtensions_EmptyDir(t *testing.T) {
	dups := findDuplicateExtensions("/nonexistent/path")
	if len(dups) != 0 {
		t.Errorf("findDuplicateExtensions(nonexistent) found %d, want 0", len(dups))
	}
}
