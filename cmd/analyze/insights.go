//go:build darwin

package main

import (
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

// Stable keys for insight rows (icon sizing, special size rules).
const (
	insightKindNone           = ""
	insightKindIOSBackups     = "ios_backups"
	insightKindOldDownloads   = "old_downloads"
	insightKindSystemLogs     = "system_logs"
	insightKindHomebrewCache  = "homebrew_cache"
	insightKindXcodeDerived   = "xcode_derived"
	insightKindXcodeSims      = "xcode_sims"
	insightKindXcodeArchives  = "xcode_archives"
	insightKindSpotifyCache   = "spotify_cache"
	insightKindJetBrainsCache = "jetbrains_cache"
	insightKindDockerData     = "docker_data"
	insightKindPipCache       = "pip_cache"
	insightKindGradleCache    = "gradle_cache"
	insightKindCocoaPodsCache = "cocoapods_cache"
)

// createInsightEntries returns the list of hidden-space insight entries
// to show in the overview screen alongside the standard directory entries.
func createInsightEntries() []dirEntry {
	home := os.Getenv("HOME")
	if home == "" {
		return nil
	}

	var entries []dirEntry

	// iOS Backups — ~/Library/Application Support/MobileSync/Backup
	backupPath := filepath.Join(home, "Library", "Application Support", "MobileSync", "Backup")
	if info, err := os.Stat(backupPath); err == nil && info.IsDir() {
		entries = append(entries, dirEntry{
			Name:        t("iOS Backups", "iOS Yedekleri"),
			Path:        backupPath,
			IsDir:       true,
			Size:        -1,
			InsightKind: insightKindIOSBackups,
		})
	}

	// Old Downloads — ~/Downloads (files older than 90 days)
	downloadsPath := filepath.Join(home, "Downloads")
	if info, err := os.Stat(downloadsPath); err == nil && info.IsDir() {
		entries = append(entries, dirEntry{
			Name:        t("Old Downloads (90d+)", "Eski İndirilenler (90g+)"),
			Path:        downloadsPath,
			IsDir:       true,
			Size:        -1,
			InsightKind: insightKindOldDownloads,
		})
	}

	// Cleanable paths — things mo clean can remove or the user can safely delete.
	// System Caches (~Library/Caches) is intentionally omitted here because the
	// specific cache subdirectories below are already its children; listing both
	// would double-count the same bytes.
	cleanablePaths := []struct {
		kind string
		en   string
		tr   string
		path string
	}{
		// Universal (everyone has these)
		{insightKindSystemLogs, "System Logs", "Sistem Günlükleri", filepath.Join(home, "Library", "Logs")},
		{insightKindHomebrewCache, "Homebrew Cache", "Homebrew Önbelleği", filepath.Join(home, "Library", "Caches", "Homebrew")},

		// Developer-specific (only shown if path exists)
		{insightKindXcodeDerived, "Xcode DerivedData", "Xcode DerivedData", filepath.Join(home, "Library", "Developer", "Xcode", "DerivedData")},
		{insightKindXcodeSims, "Xcode Simulators", "Xcode Simülatörleri", filepath.Join(home, "Library", "Developer", "CoreSimulator", "Devices")},
		{insightKindXcodeArchives, "Xcode Archives", "Xcode Arşivleri", filepath.Join(home, "Library", "Developer", "Xcode", "Archives")},
		{insightKindSpotifyCache, "Spotify Cache", "Spotify Önbelleği", filepath.Join(home, "Library", "Application Support", "Spotify", "PersistentCache")},
		{insightKindJetBrainsCache, "JetBrains Cache", "JetBrains Önbelleği", filepath.Join(home, "Library", "Caches", "JetBrains")},
		{insightKindDockerData, "Docker Data", "Docker Verisi", filepath.Join(home, "Library", "Containers", "com.docker.docker", "Data")},
		{insightKindPipCache, "pip Cache", "pip Önbelleği", filepath.Join(home, "Library", "Caches", "pip")},
		{insightKindGradleCache, "Gradle Cache", "Gradle Önbelleği", filepath.Join(home, ".gradle", "caches")},
		{insightKindCocoaPodsCache, "CocoaPods Cache", "CocoaPods Önbelleği", filepath.Join(home, "Library", "Caches", "CocoaPods")},
	}
	for _, c := range cleanablePaths {
		if info, err := os.Stat(c.path); err == nil && info.IsDir() {
			entries = append(entries, dirEntry{
				Name:        t(c.en, c.tr),
				Path:        c.path,
				IsDir:       true,
				Size:        -1,
				InsightKind: c.kind,
			})
		}
	}

	return entries
}

// measureInsightSize measures the size of a path.
// Old Downloads is treated specially: only files older than 90 days are counted.
func measureInsightSize(path string) (int64, error) {
	home := os.Getenv("HOME")

	if home != "" && path == filepath.Join(home, "Downloads") {
		return measureOldDownloads(path, 90)
	}

	return measureOverviewSize(path)
}

// measureOldDownloads calculates total size of files in a directory
// that haven't been modified in the given number of days.
func measureOldDownloads(dir string, daysOld int) (int64, error) {
	cutoff := time.Now().AddDate(0, 0, -daysOld)
	var total int64

	entries, err := os.ReadDir(dir)
	if err != nil {
		return 0, err
	}

	for _, entry := range entries {
		// Skip hidden files.
		if strings.HasPrefix(entry.Name(), ".") {
			continue
		}

		info, err := entry.Info()
		if err != nil {
			continue
		}

		if info.ModTime().Before(cutoff) {
			if entry.IsDir() {
				// Use du for directories.
				if size, err := getDirSizeFast(filepath.Join(dir, entry.Name())); err == nil {
					total += size
				}
			} else {
				total += info.Size()
			}
		}
	}

	return total, nil
}

// insightIcon returns an appropriate icon for an overview entry.
func insightIcon(entry dirEntry) string {
	switch entry.InsightKind {
	case insightKindIOSBackups:
		return "📱"
	case insightKindOldDownloads:
		return "📥"
	case insightKindHomebrewCache, insightKindPipCache, insightKindCocoaPodsCache, insightKindGradleCache, insightKindSpotifyCache, insightKindJetBrainsCache:
		return "💾"
	case insightKindSystemLogs:
		return "📋"
	case insightKindXcodeDerived, insightKindXcodeArchives:
		return "🔨"
	case insightKindXcodeSims:
		return "📲"
	case insightKindDockerData:
		return "🐳"
	default:
		return "📁"
	}
}

// getDirSizeFast measures directory size using du.
func getDirSizeFast(path string) (int64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	cmd := exec.CommandContext(ctx, "du", "-sk", path)
	output, err := cmd.Output()
	if err != nil {
		return 0, err
	}

	fields := strings.Fields(string(output))
	if len(fields) == 0 {
		return 0, nil
	}

	kb, err := strconv.ParseInt(fields[0], 10, 64)
	if err != nil {
		return 0, err
	}
	return kb * 1024, nil
}

