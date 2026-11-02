package main

import (
	"context"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// userProfileDir is the Windows home folder (%USERPROFILE%).
func userProfileDir() string {
	if home := os.Getenv("USERPROFILE"); home != "" {
		return home
	}
	home, _ := os.UserHomeDir()
	return home
}

func createOverviewEntries() []dirEntry {
	var entries []dirEntry
	addDir := func(name, path string) {
		if path == "" {
			return
		}
		if info, err := os.Stat(path); err == nil && info.IsDir() {
			entries = append(entries, dirEntry{Name: name, Path: path, IsDir: true, Size: -1})
		}
	}

	// Home and AppData are separate rows so AppData is not counted twice,
	// the way the macOS overview splits Home and ~/Library.
	home := userProfileDir()
	if home != "" {
		addDir("Home", home)
		addDir("User AppData", filepath.Join(home, "AppData"))
	}

	addDir("Program Files", os.Getenv("ProgramFiles"))
	if x86 := os.Getenv("ProgramFiles(x86)"); x86 != "" && !strings.EqualFold(x86, os.Getenv("ProgramFiles")) {
		addDir("Program Files (x86)", x86)
	}
	addDir("ProgramData", os.Getenv("ProgramData"))

	entries = append(entries, createInsightEntries()...)

	for _, drive := range fixedDrives() {
		entries = append(entries, dirEntry{Name: drive.name, Path: drive.root, IsDir: true, Size: -1})
	}
	return entries
}

// createInsightEntries returns paths that silently accumulate disk usage.
// Each one is shown only when it exists.
func createInsightEntries() []dirEntry {
	home := userProfileDir()
	if home == "" {
		return nil
	}
	localAppData := os.Getenv("LOCALAPPDATA")
	if localAppData == "" {
		localAppData = filepath.Join(home, "AppData", "Local")
	}

	candidates := []struct {
		name string
		path string
	}{
		{"Old Downloads (90d+)", filepath.Join(home, "Downloads")},
		{"Temp Files", os.Getenv("TEMP")},
		{"npm Cache", filepath.Join(localAppData, "npm-cache")},
		{"pip Cache", filepath.Join(localAppData, "pip", "Cache")},
		{"uv Cache", filepath.Join(localAppData, "uv", "cache")},
		{"Gradle Cache", filepath.Join(home, ".gradle", "caches")},
		{"JetBrains Cache", filepath.Join(localAppData, "JetBrains")},
		{"Docker Data", filepath.Join(localAppData, "Docker", "wsl")},
	}

	var entries []dirEntry
	for _, c := range candidates {
		if c.path == "" {
			continue
		}
		if info, err := os.Stat(c.path); err == nil && info.IsDir() {
			entries = append(entries, dirEntry{Name: c.name, Path: c.path, IsDir: true, Size: -1})
		}
	}
	return entries
}

// measureInsightSize measures one overview row. Old Downloads counts only
// entries not modified in the last 90 days.
func measureInsightSize(ctx context.Context, path string) (int64, error) {
	if home := userProfileDir(); home != "" && strings.EqualFold(path, filepath.Join(home, "Downloads")) {
		return measureOldDownloads(ctx, path, 90)
	}
	return measureOverviewSize(ctx, path)
}

// measureOldDownloads totals the files and folders in dir that have not been
// modified in the given number of days.
func measureOldDownloads(ctx context.Context, dir string, daysOld int) (int64, error) {
	ctx, cancel := context.WithTimeout(ctx, overviewWalkTimeout)
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
		if strings.HasPrefix(entry.Name(), ".") || isLinkEntry(entry) {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			failures.record(err)
			continue
		}
		if !info.ModTime().Before(cutoff) {
			continue
		}
		if entry.IsDir() {
			size, err := calculateDirSizeFast(ctx, filepath.Join(dir, entry.Name()), nil, nil, nil, nil, nil)
			failures.record(err)
			total += size
		} else {
			total += diskSize(filepath.Join(dir, entry.Name()), info)
		}
	}

	return total, failures.err()
}
