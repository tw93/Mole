//go:build darwin

package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"reflect"
	"testing"
	"time"
)

func TestPerformScanForJSONIncludesAllEntriesAndLargeFiles(t *testing.T) {
	root := t.TempDir()

	totalFiles := maxEntries + 6
	for i := 0; i < totalFiles-1; i++ {
		path := filepath.Join(root, fmt.Sprintf("small-%02d.txt", i))
		if err := os.WriteFile(path, []byte("x"), 0o644); err != nil {
			t.Fatalf("write small file %d: %v", i, err)
		}
	}

	hugeFile := filepath.Join(root, "huge.bin")
	if err := os.WriteFile(hugeFile, make([]byte, 2<<20), 0o644); err != nil {
		t.Fatalf("write huge file: %v", err)
	}

	result := performScanForJSON(root, false)

	if result.Overview {
		t.Fatalf("expected non-overview JSON result")
	}
	if got := len(result.Entries); got != totalFiles {
		t.Fatalf("expected %d entries, got %d", totalFiles, got)
	}
	if result.SchemaVersion != 1 {
		t.Fatalf("expected schema version 1, got %d", result.SchemaVersion)
	}
	if result.EntriesTotal != totalFiles || result.EntriesReturned != totalFiles || result.EntriesTruncated {
		t.Fatalf("unexpected entry metadata: total=%d returned=%d truncated=%t",
			result.EntriesTotal, result.EntriesReturned, result.EntriesTruncated)
	}
	if result.TotalFiles != int64(totalFiles) {
		t.Fatalf("expected %d total files, got %d", totalFiles, result.TotalFiles)
	}
	if len(result.LargeFiles) == 0 {
		t.Fatalf("expected large_files to include the large file")
	}

	foundHuge := false
	for _, file := range result.LargeFiles {
		if file.Name == "huge.bin" && file.Path == hugeFile {
			foundHuge = true
			break
		}
	}
	if !foundHuge {
		t.Fatalf("expected huge.bin in large_files, got %#v", result.LargeFiles)
	}
}

func TestLimitJSONEntriesPreservesTotalsAndLargestEntries(t *testing.T) {
	result := jsonOutput{
		SchemaVersion:   1,
		Entries:         []jsonEntry{{Name: "large", Size: 300}, {Name: "medium", Size: 200}, {Name: "small", Size: 100}},
		EntriesTotal:    3,
		EntriesReturned: 3,
		TotalSize:       600,
		TotalFiles:      9,
	}

	limited := limitJSONEntries(result, 2)

	if len(limited.Entries) != 2 || limited.Entries[0].Name != "large" || limited.Entries[1].Name != "medium" {
		t.Fatalf("unexpected limited entries: %#v", limited.Entries)
	}
	if limited.EntriesTotal != 3 || limited.EntriesReturned != 2 || !limited.EntriesTruncated {
		t.Fatalf("unexpected entry metadata: total=%d returned=%d truncated=%t",
			limited.EntriesTotal, limited.EntriesReturned, limited.EntriesTruncated)
	}
	if limited.TotalSize != 600 || limited.TotalFiles != 9 {
		t.Fatalf("scan totals changed: size=%d files=%d", limited.TotalSize, limited.TotalFiles)
	}
}

func TestWriteJSONOutputCompactPreservesDocument(t *testing.T) {
	result := jsonOutput{
		SchemaVersion:   1,
		Path:            "/tmp/example",
		Entries:         []jsonEntry{{Name: "cache", Path: "/tmp/example/cache", Size: 42, IsDir: true}},
		EntriesTotal:    1,
		EntriesReturned: 1,
		TotalSize:       42,
	}

	var indented bytes.Buffer
	if err := writeJSONOutput(&indented, result, false); err != nil {
		t.Fatalf("write indented JSON: %v", err)
	}
	var compact bytes.Buffer
	if err := writeJSONOutput(&compact, result, true); err != nil {
		t.Fatalf("write compact JSON: %v", err)
	}

	var indentedDoc, compactDoc map[string]any
	if err := json.Unmarshal(indented.Bytes(), &indentedDoc); err != nil {
		t.Fatalf("decode indented JSON: %v", err)
	}
	if err := json.Unmarshal(compact.Bytes(), &compactDoc); err != nil {
		t.Fatalf("decode compact JSON: %v", err)
	}
	if !reflect.DeepEqual(indentedDoc, compactDoc) {
		t.Fatalf("documents differ: indented=%#v compact=%#v", indentedDoc, compactDoc)
	}
	if compact.Len() >= indented.Len() || bytes.Count(compact.Bytes(), []byte("\n")) != 1 {
		t.Fatalf("compact output was not compact: indented=%d compact=%d", indented.Len(), compact.Len())
	}
}

func TestJSONEntriesFromDirEntriesIncludesMetadata(t *testing.T) {
	oldAccess := time.Now().AddDate(0, 0, -120)

	entries := jsonEntriesFromDirEntries([]dirEntry{
		{
			Name:       "old.bin",
			Path:       "/tmp/old.bin",
			Size:       42,
			IsDir:      false,
			LastAccess: oldAccess,
		},
		{
			Name:  "node_modules",
			Path:  "/tmp/project/node_modules",
			Size:  128,
			IsDir: true,
		},
	}, false, nil)

	if entries[0].LastAccess == "" {
		t.Fatalf("expected last_access to be populated")
	}
	if entries[1].Cleanable != true {
		t.Fatalf("expected node_modules entry to be marked cleanable")
	}
}

func TestJSONEntriesFromDirEntriesMarksOverviewInsights(t *testing.T) {
	entry := dirEntry{
		Name:  "Old Downloads (90d+)",
		Path:  "/tmp/test-home/Downloads",
		Size:  256,
		IsDir: true,
	}

	entries := jsonEntriesFromDirEntries([]dirEntry{entry}, true, map[string]bool{
		entry.Path: true,
	})

	if len(entries) != 1 {
		t.Fatalf("expected one entry, got %d", len(entries))
	}
	if !entries[0].Insight {
		t.Fatalf("expected entry to be marked as insight")
	}
}
