package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"syscall"
	"time"
)

// pacmanCachePath is a var so tests can point it away from the host.
var pacmanCachePath = "/var/cache/pacman/pkg"

// insightSystemRoot prefixes the system-wide insight paths (/var/lib/...), so
// tests can point it at a fixture tree.
var insightSystemRoot = "/"

// readableDir reports a directory this user can list. System stores such as
// /var/lib/docker are root-only on most machines; a row that can only ever
// read "unknown" is left out.
func readableDir(path string) bool {
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() {
		return false
	}
	return syscall.Access(path, 0x4|0x1) == nil // R_OK|X_OK
}

// createInsightEntries returns the list of hidden-space insight entries
// to show in the overview screen alongside the standard directory entries.
func createInsightEntries() []dirEntry {
	home := os.Getenv("HOME")
	if home == "" {
		return nil
	}

	dataHome := os.Getenv("XDG_DATA_HOME")
	if !filepath.IsAbs(dataHome) {
		dataHome = filepath.Join(home, ".local", "share")
	}

	var entries []dirEntry

	// Old Downloads: ~/Downloads (files older than 90 days)
	downloadsPath := filepath.Join(home, "Downloads")
	if info, err := os.Stat(downloadsPath); err == nil && info.IsDir() {
		entries = append(entries, dirEntry{
			Name:  "Old Downloads (90d+)",
			Path:  downloadsPath,
			IsDir: true,
			Size:  -1,
		})
	}

	// Cleanable paths: things mo clean can remove or the user can safely delete.
	// Report-only: nothing here is ever selected for the user. ~/.cache is its
	// own overview row, so the cache children below are listed only for the
	// stores worth naming; each is a child of that row, as on every platform.
	cleanablePaths := []struct {
		name string
		path string
	}{
		// Universal (everyone has these)
		{"Trash", filepath.Join(dataHome, "Trash")},
		{"Pacman Package Cache", pacmanCachePath},
		{"yay Cache", filepath.Join(home, ".cache", "yay")},
		{"paru Cache", filepath.Join(home, ".cache", "paru")},

		// Developer-specific (only shown if path exists)
		{"npm Cache", filepath.Join(home, ".npm", "_cacache")},
		{"pip Cache", filepath.Join(home, ".cache", "pip")},
		{"uv Cache", filepath.Join(home, ".cache", "uv")},
		{"Go Build Cache", filepath.Join(home, ".cache", "go-build")},
		{"Go Modules", filepath.Join(home, "go", "pkg", "mod")},
		{"Cargo Registry", filepath.Join(home, ".cargo", "registry")},
		{"Rust Toolchains", filepath.Join(home, ".rustup", "toolchains")},
		{"mise Installs", filepath.Join(dataHome, "mise")},
		{"mise Cache", filepath.Join(home, ".cache", "mise")},
		{"Gradle Cache", filepath.Join(home, ".gradle", "caches")},
		{"JetBrains Cache", filepath.Join(home, ".cache", "JetBrains")},
		{"Docker Data (rootless)", filepath.Join(dataHome, "docker")},
		{"Ollama Models", filepath.Join(home, ".ollama")},
		{"Hugging Face Cache", filepath.Join(home, ".cache", "huggingface")},

		// Apps and runtimes that grow quietly.
		{"Flatpak (user)", filepath.Join(dataHome, "flatpak")},
		{"Steam", filepath.Join(dataHome, "Steam")},
		{"Podman Storage", filepath.Join(dataHome, "containers")},
	}
	for _, c := range cleanablePaths {
		if info, err := os.Stat(c.path); err == nil && info.IsDir() {
			entries = append(entries, dirEntry{
				Name:  c.name,
				Path:  c.path,
				IsDir: true,
				Size:  -1,
			})
		}
	}

	// System stores, listed only when this user can read them.
	systemPaths := []struct {
		name string
		path string
	}{
		{"Flatpak (system)", "var/lib/flatpak"},
		{"systemd Journal", "var/log/journal"},
		{"Docker Data", "var/lib/docker"},
		{"Core Dumps", "var/lib/systemd/coredump"},
	}
	for _, c := range systemPaths {
		path := filepath.Join(insightSystemRoot, c.path)
		if readableDir(path) {
			entries = append(entries, dirEntry{Name: c.name, Path: path, IsDir: true, Size: -1})
		}
	}

	return entries
}

// measureInsightSize measures the size of a path.
// Old Downloads is treated specially: only files older than 90 days are counted.
func measureInsightSize(ctx context.Context, path string) (int64, error) {
	return measureInsightSizeWithPublication(ctx, path, nil)
}

func measureInsightSizeWithPublication(ctx context.Context, path string, publication *scanPublication) (int64, error) {
	home := os.Getenv("HOME")

	if home != "" && path == filepath.Join(home, "Downloads") {
		return measureOldDownloads(ctx, path, 90)
	}

	return measureOverviewSizeWithPublication(ctx, path, publication)
}

// measureOldDownloads calculates total size of files in a directory
// that haven't been modified in the given number of days.
func measureOldDownloads(ctx context.Context, dir string, daysOld int) (int64, error) {
	ctx, cancel := context.WithTimeout(ctx, duTimeout)
	defer cancel()
	var failures scanFailures
	cutoff := time.Now().AddDate(0, 0, -daysOld)
	var total int64

	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}

	for _, entry := range entries {
		if ctx.Err() != nil {
			failures.record(ctx.Err())
			break
		}
		// Skip hidden files.
		if strings.HasPrefix(entry.Name(), ".") {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			failures.record(err)
			continue
		}

		if info.ModTime().Before(cutoff) {
			if entry.IsDir() {
				// Use du for directories.
				size, err := getDirectorySizeFromDu(ctx, filepath.Join(dir, entry.Name()))
				failures.record(err)
				total += size
			} else {
				total += info.Size()
			}
		}
	}

	return total, failures.first
}
