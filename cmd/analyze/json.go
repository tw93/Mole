//go:build darwin

package main

import (
	"context"
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"os"
	"sort"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

type jsonOutput struct {
	ScanStatus scanState       `json:"scan_status"`
	Path       string          `json:"path"`
	Overview   bool            `json:"overview"`
	Entries    []jsonEntry     `json:"entries"`
	LargeFiles []jsonFileEntry `json:"large_files,omitempty"`
	TotalSize  int64           `json:"total_size"`
	TotalFiles int64           `json:"total_files,omitempty"`
}

type jsonEntry struct {
	ScanStatus scanState `json:"scan_status"`
	Name       string    `json:"name"`
	Path       string    `json:"path"`
	Size       int64     `json:"size"`
	IsDir      bool      `json:"is_dir"`
	Insight    bool      `json:"insight,omitempty"`
	Cleanable  bool      `json:"cleanable,omitempty"`
	LastAccess string    `json:"last_access,omitempty"`
}

type jsonFileEntry struct {
	Name string `json:"name"`
	Path string `json:"path"`
	Size int64  `json:"size"`
}

func runJSONMode(path string, isOverview bool) {
	result := performScanForJSON(path, isOverview)

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintf(os.Stderr, "failed to encode JSON: %v\n", err)
		os.Exit(1)
	}
}

func performScanForJSON(path string, isOverview bool) jsonOutput {
	if isOverview {
		return performOverviewScanForJSON(path)
	}
	return performDirectoryScanForJSON(path)
}

func performDirectoryScanForJSON(path string) jsonOutput {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	result, err := scanPathConcurrentAllEntries(context.Background(), path, &filesScanned, &dirsScanned, &bytesScanned, currentPath)
	if err != nil {
		fmt.Fprintf(os.Stderr, "failed to scan directory: %v\n", err)
		os.Exit(1)
	}

	return jsonOutput{
		Path:       path,
		ScanStatus: result.State,
		Overview:   false,
		Entries:    jsonEntriesFromDirEntries(result.Entries, false, nil),
		LargeFiles: jsonFileEntriesFromFileEntries(result.LargeFiles),
		TotalSize:  result.TotalSize,
		TotalFiles: result.TotalFiles,
	}
}

func performOverviewScanForJSON(path string) jsonOutput {
	insightEntries := createInsightEntries()
	overviewEntries := createOverviewEntriesWithInsights(insightEntries)
	return performOverviewScanForJSONWithEntries(path, insightEntries, overviewEntries)
}

func performOverviewScanForJSONWithEntries(path string, insightEntries, overviewEntries []dirEntry) jsonOutput {
	insightPaths := make(map[string]bool, len(insightEntries))
	for _, insight := range insightEntries {
		insightPaths[insight.Path] = true
	}

	measured := measureOverviewEntriesForJSON(overviewEntries, insightPaths)
	entries := make([]dirEntry, 0, len(overviewEntries))
	for _, row := range measured {
		// Match the TUI: omit scanned insight/tool entries that ended up empty.
		if row.Size == 0 && row.State == scanComplete {
			continue
		}
		entries = append(entries, row.dirEntry)
	}
	sortDirEntriesBySize(entries)

	return jsonOutput{
		Path:       path,
		ScanStatus: entryScanState(entries),
		Overview:   true,
		Entries:    jsonEntriesFromDirEntries(entries, true, insightPaths),
		TotalSize:  overviewTotalSize(measured),
	}
}

type jsonOverviewMeasurement struct {
	dirEntry
	excludedPath  string
	coveragePath  string
	coverageKey   string
	ageFiltered   bool
	allocatedSize int64
}

func pathInJSONOverviewScope(root, path string) bool {
	return root != "" && (root == path || strings.HasPrefix(path, strings.TrimSuffix(root, "/")+"/"))
}

// Cache overlap decisions only while the listed roots and their boundaries
// still match. Ordinary directory changes beneath them retain the normal TTL.
func jsonOverviewCoverageKey(rows []jsonOverviewMeasurement, index int) string {
	parent := rows[index]
	var scope []string
	for childIndex, child := range rows {
		if childIndex == index || (!pathInJSONOverviewScope(parent.Path, child.Path) &&
			!pathInJSONOverviewScope(parent.coveragePath, child.coveragePath)) {
			continue
		}
		scope = append(scope, fmt.Sprintf("%q %q %t %t %s",
			child.Path, child.coveragePath, child.ageFiltered, overviewRowCovers(parent, child), jsonOverviewPathStamp(child.coveragePath)))
	}
	if len(scope) == 0 {
		return ""
	}
	sort.Strings(scope)
	scope = append(scope, jsonOverviewPathStamp(parent.coveragePath))
	return fmt.Sprintf("%x", sha256.Sum256([]byte(strings.Join(scope, "\n"))))
}

func jsonOverviewPathStamp(path string) string {
	info, err := os.Lstat(path)
	if err != nil {
		return "unavailable"
	}
	device, _ := fileDevice(path, info)
	stat, _ := info.Sys().(*syscall.Stat_t)
	var inode uint64
	if stat != nil {
		inode = stat.Ino
	}
	return fmt.Sprintf("%d %d %d %d", device, inode, info.ModTime().UnixNano(), info.Mode())
}

func measureOverviewEntriesForJSON(overviewEntries []dirEntry, insightPaths map[string]bool) []jsonOverviewMeasurement {
	if len(overviewEntries) == 0 {
		return nil
	}

	measured := make([]jsonOverviewMeasurement, len(overviewEntries))
	for index, item := range overviewEntries {
		row := jsonOverviewMeasurement{
			dirEntry:     item,
			excludedPath: overviewExcludedPath(item.Path),
			ageFiltered:  insightPaths[item.Path] && isOldDownloadsOverviewPath(item.Path),
		}
		row.coveragePath = overviewCoveragePath(row)
		measured[index] = row
	}
	for index := range measured {
		if !measured[index].ageFiltered {
			measured[index].coverageKey = jsonOverviewCoverageKey(measured, index)
		}
	}
	sem := make(chan struct{}, maxConcurrentOverview)

	var wg sync.WaitGroup
	for index, row := range measured {
		wg.Go(func() {
			sem <- struct{}{}
			defer func() { <-sem }()

			measured[index] = measureOverviewEntryForJSON(row)
		})
	}

	wg.Wait()
	return measured
}

func measureOverviewEntryForJSON(row jsonOverviewMeasurement) jsonOverviewMeasurement {
	if !row.ageFiltered {
		snapshot, err := loadStoredOverviewSnapshot(row.Path)
		if err == nil && snapshot.ExcludedPath == row.excludedPath && snapshot.CoverageKey == row.coverageKey {
			row.Size, row.State = snapshot.Size, snapshot.state()
			return row
		}
		if err != nil && row.excludedPath == "" && row.coverageKey == "" {
			if cached, state, err := loadOverviewCachedMeasurement(row.Path); err == nil && cached > 0 {
				row.Size, row.State = cached, state
				return row
			}
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), duTimeout)
	defer cancel()
	var err error
	if row.ageFiltered {
		var size oldDownloadsSize
		size, err = measureOldDownloadsWithAllocation(ctx, row.Path, 90)
		row.Size = size.reported
		row.allocatedSize = size.allocated
	} else {
		row.Size, err = measureOverviewSizeWithCoverage(ctx, row.Path, nil, row.coverageKey)
	}
	row.State = measurementState(row.Size, err)
	return row
}

func jsonEntriesFromDirEntries(entries []dirEntry, isOverview bool, insightPaths map[string]bool) []jsonEntry {
	output := make([]jsonEntry, 0, len(entries))
	for _, entry := range entries {
		item := jsonEntry{
			Name:       entry.Name,
			ScanStatus: entry.State,
			Path:       entry.Path,
			Size:       entry.Size,
			IsDir:      entry.IsDir,
			Cleanable:  entry.IsDir && isCleanableDir(entry.Path),
		}

		if isOverview {
			item.Insight = insightPaths[entry.Path]
		}

		if !entry.LastAccess.IsZero() {
			item.LastAccess = entry.LastAccess.UTC().Format(time.RFC3339)
		}

		output = append(output, item)
	}
	return output
}

func jsonFileEntriesFromFileEntries(files []fileEntry) []jsonFileEntry {
	output := make([]jsonFileEntry, 0, len(files))
	for _, f := range files {
		output = append(output, jsonFileEntry(f))
	}
	return output
}
