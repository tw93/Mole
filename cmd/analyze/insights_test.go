package main

import (
	"context"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func isolateInsightHost(t *testing.T) string {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	t.Setenv("XDG_DATA_HOME", "")
	pacmanCachePath = filepath.Join(home, "no-pacman")
	insightSystemRoot = filepath.Join(home, "no-system-root")
	t.Cleanup(func() {
		pacmanCachePath = "/var/cache/pacman/pkg"
		insightSystemRoot = "/"
	})
	return home
}

func TestCreateInsightEntriesListsAppStoresAndReadableSystemStores(t *testing.T) {
	home := isolateInsightHost(t)
	system := filepath.Join(home, "sysroot")
	insightSystemRoot = system

	want := map[string]string{
		"Flatpak (user)":   filepath.Join(home, ".local", "share", "flatpak"),
		"Steam":            filepath.Join(home, ".local", "share", "Steam"),
		"Podman Storage":   filepath.Join(home, ".local", "share", "containers"),
		"Flatpak (system)": filepath.Join(system, "var/lib/flatpak"),
		"systemd Journal":  filepath.Join(system, "var/log/journal"),
		"Core Dumps":       filepath.Join(system, "var/lib/systemd/coredump"),
	}
	for _, path := range want {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	// Root-only Docker storage: present but unreadable, so not listed.
	docker := filepath.Join(system, "var/lib/docker")
	if err := os.MkdirAll(docker, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(docker, 0o000); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(docker, 0o755) })

	got := map[string]string{}
	for _, entry := range createInsightEntries() {
		got[entry.Name] = entry.Path
	}
	for name, path := range want {
		if got[name] != path {
			t.Errorf("insight %q path = %q, want %q", name, got[name], path)
		}
	}
	if _, listed := got["Docker Data"]; listed && os.Geteuid() != 0 {
		t.Error("unreadable /var/lib/docker must not be listed")
	}

	if err := os.Chmod(docker, 0o755); err != nil {
		t.Fatal(err)
	}
	found := false
	for _, entry := range createInsightEntries() {
		found = found || (entry.Name == "Docker Data" && entry.Path == docker)
	}
	if !found {
		t.Error("readable /var/lib/docker must be listed")
	}
}

func TestCreateInsightEntries(t *testing.T) {
	home := isolateInsightHost(t)
	if entries := createInsightEntries(); len(entries) != 0 {
		t.Fatalf("empty home returned %d insight entries", len(entries))
	}
	downloads := filepath.Join(home, "Downloads")
	if err := os.Mkdir(downloads, 0755); err != nil {
		t.Fatal(err)
	}
	entries := createInsightEntries()
	if len(entries) != 1 || entries[0].Name != "Old Downloads (90d+)" || entries[0].Path != downloads {
		t.Fatalf("expected only the fixture Downloads insight, got %+v", entries)
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

func TestCreateInsightEntriesListsLinuxCacheStores(t *testing.T) {
	home := isolateInsightHost(t)
	pacmanCachePath = filepath.Join(home, "pacman-pkg")

	want := map[string]string{
		"Trash":                  filepath.Join(home, ".local", "share", "Trash"),
		"Pacman Package Cache":   pacmanCachePath,
		"yay Cache":              filepath.Join(home, ".cache", "yay"),
		"paru Cache":             filepath.Join(home, ".cache", "paru"),
		"npm Cache":              filepath.Join(home, ".npm", "_cacache"),
		"pip Cache":              filepath.Join(home, ".cache", "pip"),
		"Go Build Cache":         filepath.Join(home, ".cache", "go-build"),
		"Go Modules":             filepath.Join(home, "go", "pkg", "mod"),
		"Cargo Registry":         filepath.Join(home, ".cargo", "registry"),
		"Rust Toolchains":        filepath.Join(home, ".rustup", "toolchains"),
		"mise Installs":          filepath.Join(home, ".local", "share", "mise"),
		"mise Cache":             filepath.Join(home, ".cache", "mise"),
		"Gradle Cache":           filepath.Join(home, ".gradle", "caches"),
		"JetBrains Cache":        filepath.Join(home, ".cache", "JetBrains"),
		"Docker Data (rootless)": filepath.Join(home, ".local", "share", "docker"),
		"Ollama Models":          filepath.Join(home, ".ollama"),
		"Hugging Face Cache":     filepath.Join(home, ".cache", "huggingface"),
	}
	for _, path := range want {
		if err := os.MkdirAll(path, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	got := map[string]string{}
	for _, entry := range createInsightEntries() {
		got[entry.Name] = entry.Path
	}
	for name, path := range want {
		if got[name] != path {
			t.Errorf("insight %q path = %q, want %q", name, got[name], path)
		}
	}
}

func TestCreateInsightEntriesHonorsXDGDataHome(t *testing.T) {
	home := isolateInsightHost(t)
	data := filepath.Join(home, "xdg-data")
	t.Setenv("XDG_DATA_HOME", data)
	if err := os.MkdirAll(filepath.Join(data, "Trash"), 0o755); err != nil {
		t.Fatal(err)
	}
	for _, entry := range createInsightEntries() {
		if entry.Name == "Trash" && entry.Path == filepath.Join(data, "Trash") {
			return
		}
	}
	t.Fatal("Trash under XDG_DATA_HOME not listed")
}

func TestCreateInsightEntriesIncludesUvCache(t *testing.T) {
	home := isolateInsightHost(t)

	uvCache := filepath.Join(home, ".cache", "uv")
	if err := os.MkdirAll(uvCache, 0755); err != nil {
		t.Fatal(err)
	}

	entries := createInsightEntries()
	for _, entry := range entries {
		if entry.Name == "uv Cache" {
			if entry.Path != uvCache {
				t.Fatalf("uv Cache path = %q, want %q", entry.Path, uvCache)
			}
			return
		}
	}
	t.Fatal("uv Cache insight not found")
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

	size, err := measureOldDownloads(context.Background(), dir, 90)
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

	size, err := measureInsightSize(context.Background(), dir)
	if err != nil {
		t.Fatalf("measureInsightSize: %v", err)
	}
	if size == 0 {
		t.Error("expected non-zero size")
	}
}
