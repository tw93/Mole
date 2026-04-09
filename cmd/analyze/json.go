//go:build darwin

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"sync/atomic"
	"time"
)

type jsonOutput struct {
	Path       string          `json:"path"`
	Overview   bool            `json:"overview"`
	Entries    []jsonEntry     `json:"entries"`
	LargeFiles []jsonFileEntry `json:"large_files,omitempty"`
	TotalSize  int64           `json:"total_size"`
	TotalFiles int64           `json:"total_files"`
}

type jsonEntry struct {
	Name       string `json:"name"`
	Path       string `json:"path"`
	Size       int64  `json:"size"`
	IsDir      bool   `json:"is_dir"`
	Insight    bool   `json:"insight,omitempty"`
	Cleanable  bool   `json:"cleanable,omitempty"`
	LastAccess string `json:"last_access,omitempty"`
}

type jsonFileEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Size int64  `json:"size"`
}

func runJSONMode(path string, isOverview bool) {
	var result jsonOutput
	if isOverview {
		result = performOverviewScanForJSON(path)
	} else {
		result = performScanForJSON(path)
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "failed to encode JSON: %v\n", err)
		os.Exit(1)
	}
}

func performScanForJSON(path string) jsonOutput {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	result, err := scanPathConcurrentWithOptions(path, &filesScanned, &dirsScanned, &bytesScanned, currentPath, true, 0)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to scan directory: %v\n", err)
		os.Exit(1)
	}

	largeFiles := make([]jsonFileEntry, len(result.LargeFiles))
	for i, f := range result.LargeFiles {
		largeFiles[i] = jsonFileEntry(f)
	}

	return jsonOutput{
		Path:       path,
		Overview:   false,
		Entries:    jsonEntriesFromDirEntries(result.Entries, nil),
		LargeFiles: largeFiles,
		TotalSize:  result.TotalSize,
		TotalFiles: result.TotalFiles,
	}
}

func performOverviewScanForJSON(path string) jsonOutput {
	overviewEntries := createOverviewEntries()
	insightEntries := createInsightEntries()
	insightPaths := make(map[string]bool, len(insightEntries))
	for _, insight := range insightEntries {
		insightPaths[insight.Path] = true
	}

	var totalSize int64
	entries := make([]dirEntry, 0, len(overviewEntries))
	for _, entry := range overviewEntries {
		var (
			size int64
			err  error
		)

		if cached, cacheErr := loadOverviewCachedSize(entry.Path); cacheErr == nil && cached > 0 {
			size = cached
		} else if insightPaths[entry.Path] {
			size, err = measureInsightSize(entry.Path)
		} else {
			size, err = measureOverviewSize(entry.Path)
		}

		if err != nil {
			fmt.Fprintf(os.Stderr, "warn: measure %s: %v\n", entry.Path, err)
		} else {
			entry.Size = size
		}

		// Match the TUI: omit scanned insight/tool entries that ended up empty.
		if entry.Size == 0 {
			continue
		}
		totalSize += entry.Size
		entries = append(entries, entry)
	}

	sort.Slice(entries, func(i, j int) bool {
		return entries[i].Size > entries[j].Size
	})

	return jsonOutput{
		Path:      path,
		Overview:  true,
		Entries:   jsonEntriesFromDirEntries(entries, insightPaths),
		TotalSize: totalSize,
	}
}

func jsonEntriesFromDirEntries(entries []dirEntry, insightPaths map[string]bool) []jsonEntry {
	output := make([]jsonEntry, 0, len(entries))
	for _, entry := range entries {
		item := jsonEntry{
			Name:      entry.Name,
			Path:      entry.Path,
			Size:      entry.Size,
			IsDir:     entry.IsDir,
			Cleanable: entry.IsDir && isCleanableDir(entry.Path),
			Insight:   insightPaths[entry.Path],
		}
		if !entry.LastAccess.IsZero() {
			item.LastAccess = entry.LastAccess.UTC().Format(time.RFC3339)
		}
		output = append(output, item)
	}
	return output
}
