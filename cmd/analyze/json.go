package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"path/filepath"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unicode/utf16"
)

// The JSON output follows the macOS CLI's `mo analyze --json` contract field
// for field, so one agent skill can read both.
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

// MarshalText gives the JSON boundary the same typed coverage state the TUI
// uses, and refuses a value outside the three known states.
func (s scanState) MarshalText() ([]byte, error) {
	if s > scanUnavailable {
		return nil, fmt.Errorf("invalid scan state: %d", s)
	}
	return []byte(s.String()), nil
}

// runJSONMode scans once and writes one indented JSON object. It is read-only:
// it never opens the TUI, deletes, or writes the operations log.
func runJSONMode(w io.Writer, path string, isOverview bool) error {
	var result jsonOutput
	if isOverview {
		result = performOverviewScanForJSON()
	} else {
		var err error
		result, err = performDirectoryScanForJSON(path)
		if err != nil {
			return fmt.Errorf("failed to scan directory: %w", err)
		}
	}

	var encoded bytes.Buffer
	encoder := json.NewEncoder(&encoded)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		return fmt.Errorf("failed to encode JSON: %w", err)
	}
	if _, err := w.Write(escapeNonASCII(encoded.Bytes())); err != nil {
		return fmt.Errorf("failed to write JSON: %w", err)
	}
	return nil
}

// escapeNonASCII writes every non-ASCII character of encoded JSON as a \u
// escape, astral ones as a surrogate pair, the way `mo uninstall --list` does.
// Windows PowerShell 5.1 decodes a native command's stdout with the console
// code page, so raw UTF-8 would garble a non-ASCII path before ConvertFrom-Json
// reads it. JSON syntax is ASCII, so only string contents change.
func escapeNonASCII(encoded []byte) []byte {
	var out bytes.Buffer
	out.Grow(len(encoded))
	for _, r := range string(encoded) {
		if r < 0x80 {
			out.WriteByte(byte(r))
			continue
		}
		for _, unit := range utf16.Encode([]rune{r}) {
			fmt.Fprintf(&out, `\u%04x`, unit)
		}
	}
	return out.Bytes()
}

func performDirectoryScanForJSON(path string) (jsonOutput, error) {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	result, err := scanPathConcurrentAllEntries(context.Background(), path, &filesScanned, &dirsScanned, &bytesScanned, currentPath)
	if err != nil {
		return jsonOutput{}, err
	}

	return jsonOutput{
		ScanStatus: result.State,
		Path:       path,
		Overview:   false,
		Entries:    jsonEntriesFromDirEntries(result.Entries, false, nil),
		LargeFiles: jsonFileEntriesFromFileEntries(result.LargeFiles),
		TotalSize:  result.TotalSize,
		TotalFiles: result.TotalFiles,
	}, nil
}

// performOverviewScanForJSON measures the rows the overview screen shows:
// Home, User AppData, Program Files, ProgramData, the insight folders and the
// fixed drives. Windows has no single root above them, so path is empty.
func performOverviewScanForJSON() jsonOutput {
	return performOverviewScanForJSONWithEntries(createInsightEntries(), createOverviewEntries(), measureInsightSize)
}

func performOverviewScanForJSONWithEntries(insightEntries, overviewEntries []dirEntry, measure func(context.Context, string) (int64, error)) jsonOutput {
	insightPaths := make(map[string]bool, len(insightEntries))
	for _, insight := range insightEntries {
		insightPaths[insight.Path] = true
	}

	entries := make([]dirEntry, 0, len(overviewEntries))
	for _, entry := range measureOverviewEntriesForJSON(overviewEntries, measure) {
		// Match the TUI: omit rows that were measured completely and are empty.
		if entry.Size == 0 && entry.State == scanComplete {
			continue
		}
		entries = append(entries, entry)
	}

	sortDirEntriesBySize(entries)
	totalSize := overviewTotalSize(entries)

	return jsonOutput{
		ScanStatus: entryScanState(entries),
		Path:       "",
		Overview:   true,
		Entries:    jsonEntriesFromDirEntries(entries, true, insightPaths),
		TotalSize:  totalSize,
	}
}

// overviewTotalSize adds each row once: a row that lies inside another row with
// measured bytes is already part of that row. Every folder row sits on a drive
// the overview also lists, so on Windows the total is the drives' used bytes.
// Home is measured without AppData, so AppData is not inside it.
func overviewTotalSize(entries []dirEntry) int64 {
	var total int64
	for _, entry := range entries {
		covered := false
		for _, other := range entries {
			if other.Path != entry.Path && other.Size > 0 && overviewRowCovers(other.Path, entry.Path) {
				covered = true
				break
			}
		}
		if !covered {
			total += max(entry.Size, 0)
		}
	}
	return total
}

// overviewRowCovers reports whether the measurement of parent includes child.
func overviewRowCovers(parent, child string) bool {
	if !pathWithin(parent, child) {
		return false
	}
	if home := userProfileDir(); home != "" && pathEqual(parent, home) {
		return !pathWithin(filepath.Join(home, "AppData"), child)
	}
	return true
}

// pathWithin reports whether child is parent or below it, ignoring case as
// Windows paths do.
func pathWithin(parent, child string) bool {
	parent = strings.ToLower(filepath.Clean(parent))
	child = strings.ToLower(filepath.Clean(child))
	if parent == child {
		return true
	}
	if !strings.HasSuffix(parent, string(filepath.Separator)) {
		parent += string(filepath.Separator)
	}
	return strings.HasPrefix(child, parent)
}

func pathEqual(a, b string) bool {
	return strings.EqualFold(filepath.Clean(a), filepath.Clean(b))
}

// measureOverviewEntriesForJSON measures every row with the TUI's own
// measurement, each row held to jsonWalkTimeout, at most maxConcurrentOverview at a time. A
// failed or timed-out measurement keeps the bytes it reached and is marked
// partial, or unavailable when it reached none; it is never a complete zero.
func measureOverviewEntriesForJSON(overviewEntries []dirEntry, measure func(context.Context, string) (int64, error)) []dirEntry {
	measured := make([]dirEntry, len(overviewEntries))
	sem := make(chan struct{}, maxConcurrentOverview)

	var wg sync.WaitGroup
	for index, item := range overviewEntries {
		wg.Add(1)
		go func(index int, item dirEntry) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			ctx, cancel := context.WithTimeout(context.Background(), jsonWalkTimeout)
			defer cancel()
			size, err := measure(ctx, item.Path)
			item.Size = size
			item.State = measurementState(size, err)
			measured[index] = item
		}(index, item)
	}
	wg.Wait()
	return measured
}

func jsonEntriesFromDirEntries(entries []dirEntry, isOverview bool, insightPaths map[string]bool) []jsonEntry {
	output := make([]jsonEntry, 0, len(entries))
	for _, entry := range entries {
		item := jsonEntry{
			ScanStatus: entry.State,
			Name:       entry.Name,
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
