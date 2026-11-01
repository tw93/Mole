package main

import (
	"os"
	"path/filepath"
	"testing"
)

func writeCacheDirTag(t testing.TB, dir string, content string) {
	t.Helper()
	if err := os.WriteFile(filepath.Join(dir, cacheDirTagFileName), []byte(content), 0o644); err != nil {
		t.Fatalf("write cache dir tag: %v", err)
	}
}

func TestIsCleanableDirAcceptsValidCacheDirTag(t *testing.T) {
	dir := t.TempDir()
	writeCacheDirTag(t, dir, cacheDirTagSignature+"\n# https://bford.info/cachedir/")

	if !isCleanableDir(dir) {
		t.Fatalf("expected valid CACHEDIR.TAG directory to be cleanable")
	}
}

func TestIsCleanableDirRejectsInvalidCacheDirTag(t *testing.T) {
	tests := map[string]string{
		"wrong signature": "Signature: invalid",
		"short file":      cacheDirTagSignature[:len(cacheDirTagSignature)-1],
	}

	for name, content := range tests {
		t.Run(name, func(t *testing.T) {
			dir := t.TempDir()
			writeCacheDirTag(t, dir, content)

			if isCleanableDir(dir) {
				t.Fatalf("expected invalid CACHEDIR.TAG directory to stay non-cleanable")
			}
		})
	}
}

func TestIsCleanableDirRejectsSymlinkCacheDirTag(t *testing.T) {
	dir := t.TempDir()
	realTag := filepath.Join(dir, "real-tag")
	if err := os.WriteFile(realTag, []byte(cacheDirTagSignature), 0o644); err != nil {
		t.Fatalf("write real tag: %v", err)
	}
	if err := os.Symlink(realTag, filepath.Join(dir, cacheDirTagFileName)); err != nil {
		t.Fatalf("symlink cache dir tag: %v", err)
	}

	if isCleanableDir(dir) {
		t.Fatalf("expected symlink CACHEDIR.TAG directory to stay non-cleanable")
	}
}
