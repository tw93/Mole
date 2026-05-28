//go:build darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
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

func TestPerformScanForJSONIncludesDuplicateGroupsWhenRequested(t *testing.T) {
	root := t.TempDir()
	content := []byte("duplicate payload")
	first := filepath.Join(root, "first.bin")
	second := filepath.Join(root, "second.bin")
	unique := filepath.Join(root, "unique.bin")

	if err := os.WriteFile(first, content, 0o644); err != nil {
		t.Fatalf("write first duplicate: %v", err)
	}
	if err := os.WriteFile(second, content, 0o644); err != nil {
		t.Fatalf("write second duplicate: %v", err)
	}
	if err := os.WriteFile(unique, []byte("different payload"), 0o644); err != nil {
		t.Fatalf("write unique: %v", err)
	}

	oldDuplicatesMode := *duplicatesMode
	oldMinSize := *duplicateMinSizeFlag
	oldTimeout := *duplicateTimeoutFlag
	oldMaxCandidates := *duplicateMaxCandidatesFlag
	*duplicatesMode = true
	*duplicateMinSizeFlag = 1
	*duplicateTimeoutFlag = 5 * time.Second
	*duplicateMaxCandidatesFlag = 100
	t.Cleanup(func() {
		*duplicatesMode = oldDuplicatesMode
		*duplicateMinSizeFlag = oldMinSize
		*duplicateTimeoutFlag = oldTimeout
		*duplicateMaxCandidatesFlag = oldMaxCandidates
	})

	result := performScanForJSON(root, false)

	if len(result.DuplicateGroups) != 1 {
		t.Fatalf("expected one duplicate group, got %#v", result.DuplicateGroups)
	}
	group := result.DuplicateGroups[0]
	if group.WastedBytes != int64(len(content)) {
		t.Fatalf("expected wasted bytes %d, got %d", len(content), group.WastedBytes)
	}
	if len(group.Files) != 2 {
		t.Fatalf("expected two duplicate files, got %#v", group.Files)
	}
	if result.DuplicateScan == nil {
		t.Fatalf("expected duplicate_scan metadata")
	}
	if result.DuplicateScan.Partial {
		t.Fatalf("expected complete duplicate scan, got %#v", result.DuplicateScan)
	}
	if result.DuplicateScan.HashedFiles != 3 {
		t.Fatalf("expected 3 hashed files, got %d", result.DuplicateScan.HashedFiles)
	}
}

func TestPerformScanForJSONReportsPartialDuplicateScanAtCandidateLimit(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"a.bin", "b.bin", "c.bin"} {
		if err := os.WriteFile(filepath.Join(root, name), []byte("same payload"), 0o644); err != nil {
			t.Fatalf("write candidate %s: %v", name, err)
		}
	}

	oldDuplicatesMode := *duplicatesMode
	oldMinSize := *duplicateMinSizeFlag
	oldTimeout := *duplicateTimeoutFlag
	oldMaxCandidates := *duplicateMaxCandidatesFlag
	*duplicatesMode = true
	*duplicateMinSizeFlag = 1
	*duplicateTimeoutFlag = 5 * time.Second
	*duplicateMaxCandidatesFlag = 1
	t.Cleanup(func() {
		*duplicatesMode = oldDuplicatesMode
		*duplicateMinSizeFlag = oldMinSize
		*duplicateTimeoutFlag = oldTimeout
		*duplicateMaxCandidatesFlag = oldMaxCandidates
	})

	result := performScanForJSON(root, false)

	if result.DuplicateScan == nil {
		t.Fatalf("expected duplicate_scan metadata")
	}
	if !result.DuplicateScan.Partial {
		t.Fatalf("expected partial duplicate scan")
	}
	if result.DuplicateScan.Reason != "candidate_limit" {
		t.Fatalf("expected candidate_limit reason, got %q", result.DuplicateScan.Reason)
	}
	if result.DuplicateScan.Candidates != 1 {
		t.Fatalf("expected 1 candidate, got %d", result.DuplicateScan.Candidates)
	}
}

func TestValidateFlagsRejectsInvalidDuplicateControls(t *testing.T) {
	oldMinSize := *duplicateMinSizeFlag
	oldTimeout := *duplicateTimeoutFlag
	oldMaxCandidates := *duplicateMaxCandidatesFlag
	t.Cleanup(func() {
		*duplicateMinSizeFlag = oldMinSize
		*duplicateTimeoutFlag = oldTimeout
		*duplicateMaxCandidatesFlag = oldMaxCandidates
	})

	*duplicateMinSizeFlag = 0
	*duplicateTimeoutFlag = time.Second
	*duplicateMaxCandidatesFlag = 1
	if err := validateFlags(); err == nil {
		t.Fatalf("expected invalid min size to fail")
	}

	*duplicateMinSizeFlag = 1
	*duplicateTimeoutFlag = -time.Second
	if err := validateFlags(); err == nil {
		t.Fatalf("expected negative timeout to fail")
	}

	*duplicateTimeoutFlag = time.Second
	*duplicateMaxCandidatesFlag = -1
	if err := validateFlags(); err == nil {
		t.Fatalf("expected negative max candidates to fail")
	}

	*duplicateMaxCandidatesFlag = 0
	if err := validateFlags(); err != nil {
		t.Fatalf("expected zero max candidates to mean unlimited: %v", err)
	}

	*duplicateTimeoutFlag = 0
	if err := validateFlags(); err != nil {
		t.Fatalf("expected zero timeout to mean unlimited: %v", err)
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
