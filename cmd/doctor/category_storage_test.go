package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestExpandHome(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("cannot determine home directory")
	}

	tests := []struct {
		name string
		path string
		want string
	}{
		{"tilde prefix", "~/Library/Caches", home + "/Library/Caches"},
		{"tilde only", "~/", home + "/"},
		{"no tilde", "/usr/local/bin", "/usr/local/bin"},
		{"tilde not prefix", "/home/~/test", "/home/~/test"},
		{"empty", "", ""},
		{"relative path", "Library/Caches", "Library/Caches"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := expandHome(tt.path)
			if got != tt.want {
				t.Errorf("expandHome(%q) = %q, want %q", tt.path, got, tt.want)
			}
		})
	}
}

func TestExpandHomeContainsHome(t *testing.T) {
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("cannot determine home directory")
	}

	got := expandHome("~/test")
	if !strings.HasPrefix(got, home) {
		t.Errorf("expandHome(\"~/test\") = %q, should start with %q", got, home)
	}
}

func TestDirSizeBytes(t *testing.T) {
	dir := t.TempDir()
	f, err := os.Create(filepath.Join(dir, "testfile"))
	if err != nil {
		t.Fatal(err)
	}
	data := make([]byte, 4096)
	f.Write(data)
	f.Close()

	size := dirSizeBytes(dir)
	if size < 4096 {
		t.Errorf("dirSizeBytes() = %d, want >= 4096", size)
	}
}

func TestDirSizeBytes_NonExistent(t *testing.T) {
	size := dirSizeBytes("/nonexistent/path/that/does/not/exist")
	if size != 0 {
		t.Errorf("dirSizeBytes(nonexistent) = %d, want 0", size)
	}
}
