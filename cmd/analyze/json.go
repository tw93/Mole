//go:build darwin

package main

import (
	"encoding/json"
	"fmt"
	"os"
	"sync/atomic"
)

type jsonOutput struct {
	Path       string      `json:"path"`
	Entries    []jsonEntry `json:"entries"`
	TotalSize  int64       `json:"total_size"`
	TotalFiles int64       `json:"total_files"`
}

type jsonEntry struct {
	Name  string `json:"name"`
	Path  string `json:"path"`
	Size  int64  `json:"size"`
	IsDir bool   `json:"is_dir"`
}

func runJSONMode(path string, isOverview bool) {
	result := performScanForJSON(path)

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(result); err != nil {
		fmt.Fprintln(os.Stderr, ftr("failed to encode JSON: %v", err))
		os.Exit(1)
	}
}

func performScanForJSON(path string) jsonOutput {
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	items, err := os.ReadDir(path)
	if err != nil {
		fmt.Fprintln(os.Stderr, ftr("failed to read directory: %v", err))
		os.Exit(1)
	}

	var entries []jsonEntry
	var totalSize int64

	for _, item := range items {
		fullPath := path + "/" + item.Name()
		var size int64

		if item.IsDir() {
			size = calculateDirSizeFast(fullPath, &filesScanned, &dirsScanned, &bytesScanned, currentPath)
		} else {
			info, err := item.Info()
			if err == nil {
				size = info.Size()
				atomic.AddInt64(&filesScanned, 1)
				atomic.AddInt64(&bytesScanned, size)
			}
		}

		totalSize += size
		entries = append(entries, jsonEntry{
			Name:  item.Name(),
			Path:  fullPath,
			Size:  size,
			IsDir: item.IsDir(),
		})
	}

	return jsonOutput{
		Path:       path,
		Entries:    entries,
		TotalSize:  totalSize,
		TotalFiles: atomic.LoadInt64(&filesScanned),
	}
}
