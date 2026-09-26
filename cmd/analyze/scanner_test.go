//go:build darwin

package main

import (
	"context"
	"fmt"
	"os"
	"path/filepath"
	"sync/atomic"
	"testing"
)

func writeFileWithSize(t testing.TB, path string, size int) {
	t.Helper()
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		t.Fatalf("mkdir %s: %v", path, err)
	}
	content := make([]byte, size)
	if err := os.WriteFile(path, content, 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}

func TestGetDirectoryLogicalSizeWithExclude(t *testing.T) {
	base := t.TempDir()
	homeFile := filepath.Join(base, "fileA")
	libFile := filepath.Join(base, "Library", "fileB")
	projectLibFile := filepath.Join(base, "Projects", "Library", "fileC")

	writeFileWithSize(t, homeFile, 100)
	writeFileWithSize(t, libFile, 200)
	writeFileWithSize(t, projectLibFile, 300)

	total, err := getDirectoryLogicalSizeWithExclude(base, "")
	if err != nil {
		t.Fatalf("getDirectoryLogicalSizeWithExclude (no exclude) error: %v", err)
	}
	if total != 600 {
		t.Fatalf("expected total 600 bytes, got %d", total)
	}

	excluding, err := getDirectoryLogicalSizeWithExclude(base, filepath.Join(base, "Library"))
	if err != nil {
		t.Fatalf("getDirectoryLogicalSizeWithExclude (exclude Library) error: %v", err)
	}
	if excluding != 400 {
		t.Fatalf("expected 400 bytes when excluding top-level Library, got %d", excluding)
	}
}

func TestGetDirectorySizeFromDuSkippingImmediateChildDoesNotMeasureExcludedPath(t *testing.T) {
	base := t.TempDir()
	excluded := filepath.Join(base, "Library")
	included := filepath.Join(base, "Documents")
	if err := os.MkdirAll(excluded, 0o755); err != nil {
		t.Fatalf("mkdir excluded: %v", err)
	}
	if err := os.MkdirAll(included, 0o755); err != nil {
		t.Fatalf("mkdir included: %v", err)
	}

	var measured []string
	size, err := getDirectorySizeFromDuSkippingImmediateChild(base, excluded, func(path string) (int64, error) {
		measured = append(measured, path)
		return 100, nil
	})
	if err != nil {
		t.Fatalf("getDirectorySizeFromDuSkippingImmediateChild: %v", err)
	}
	if size < 100 {
		t.Fatalf("expected included directory size in total, got %d", size)
	}
	if len(measured) != 1 || measured[0] != included {
		t.Fatalf("expected to measure only %s, measured %#v", included, measured)
	}
}

func TestGetDirectorySizeFromDuWithIgnoresSkipsCloudPlaceholderTree(t *testing.T) {
	base := t.TempDir()
	writeFileWithSize(t, filepath.Join(base, "Application Support", "state.dat"), 4096)
	writeFileWithSize(t, filepath.Join(base, "Mobile Documents", "cloud.dat"), 1024*1024)

	withoutIgnore, err := getDirectorySizeFromDuWithExcludeAndIgnores(context.Background(), base, "", nil)
	if err != nil {
		t.Fatalf("getDirectorySizeFromDuWithExcludeAndIgnores without ignore: %v", err)
	}
	withIgnore, err := getDirectorySizeFromDuWithExcludeAndIgnores(context.Background(), base, "", []string{"Mobile Documents"})
	if err != nil {
		t.Fatalf("getDirectorySizeFromDuWithExcludeAndIgnores with ignore: %v", err)
	}
	if withIgnore >= withoutIgnore {
		t.Fatalf("expected ignored Mobile Documents to reduce size, got ignored=%d without=%d", withIgnore, withoutIgnore)
	}
	if withIgnore <= 0 {
		t.Fatalf("expected non-zero size for included files, got %d", withIgnore)
	}
}

func TestValidateDuIgnoreNameRejectsPathPatterns(t *testing.T) {
	for _, name := range []string{"", "../Library", "Library/Developer", "bad\x00name"} {
		if err := validateDuIgnoreName(name); err == nil {
			t.Fatalf("expected %q to be rejected", name)
		}
	}
	if err := validateDuIgnoreName("Mobile Documents"); err != nil {
		t.Fatalf("expected basename ignore to be accepted: %v", err)
	}
}

func BenchmarkGetDirectorySizeFromDuWithExcludeHomeLibrary(b *testing.B) {
	base := b.TempDir()
	libraryDir := filepath.Join(base, "Library")
	for dirIdx := range 250 {
		for fileIdx := range 20 {
			writeFileWithSize(
				b,
				filepath.Join(libraryDir, "bulk", fmt.Sprintf("dir-%03d", dirIdx), "bucket", fmt.Sprintf("file-%03d.dat", fileIdx)),
				16,
			)
		}
	}
	writeFileWithSize(b, filepath.Join(base, "Documents", "keep.dat"), 4096)

	excludePath := filepath.Join(base, "Library")
	b.ReportAllocs()
	b.ResetTimer()

	for b.Loop() {
		size, err := getDirectorySizeFromDuWithExclude(context.Background(), base, excludePath)
		if err != nil {
			b.Fatalf("getDirectorySizeFromDuWithExclude: %v", err)
		}
		if size <= 0 {
			b.Fatalf("expected non-zero size, got %d", size)
		}
	}
}

// A readable root must not turn an unreadable descendant into a measured zero.
func TestScanUnreadableDescendantPreservesCoverageAndGoodCache(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission fixture requires an unprivileged user")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	locked := filepath.Join(child, "locked")
	writeFileWithSize(t, filepath.Join(child, "readable"), 4096)
	writeFileWithSize(t, filepath.Join(locked, "hidden"), 1<<20)
	scan := func() scanResult {
		t.Helper()
		var files, dirs, bytes int64
		current := &atomic.Value{}
		current.Store("")
		result, err := scanPathConcurrentAllEntries(context.Background(), root, &files, &dirs, &bytes, current)
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	good := scan()
	if good.State != scanComplete {
		t.Fatalf("initial scan state = %s", good.State)
	}
	if err := saveCacheToDisk(root, good); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	partial := scan()
	if partial.State != scanPartial || partial.TotalSize != 4096 || partial.TotalFiles != 1 {
		t.Fatalf("partial result lost coverage or readable bytes: %+v", partial)
	}
	if len(partial.Entries) != 1 || partial.Entries[0].State != scanPartial {
		t.Fatalf("child coverage not propagated: %+v", partial.Entries)
	}
	if err := saveCacheToDisk(root, partial); err != nil {
		t.Fatal(err)
	}
	cached, err := loadCacheFromDisk(root)
	if err != nil || cached.TotalSize != good.TotalSize {
		t.Fatalf("partial scan replaced good cache: %+v, %v", cached, err)
	}
	if err := os.Chmod(locked, 0o755); err != nil {
		t.Fatal(err)
	}
	recovered := scan()
	if recovered.State != scanComplete || recovered.TotalSize != good.TotalSize {
		t.Fatalf("recovery: %+v", recovered)
	}
}

func TestFoldedDirectoryRetainsPartialDuOutput(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	folded := filepath.Join(root, "node_modules")
	writeFileWithSize(t, filepath.Join(folded, "file"), 1)
	stubDir := t.TempDir()
	// The real external-command boundary returns a subtotal and fails.
	if err := os.WriteFile(filepath.Join(stubDir, "du"), []byte("#!/bin/sh\nprintf '8\tpartial\n'\nexit 1\n"), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", stubDir)
	size, err := getDirectorySizeFromDu(context.Background(), folded)
	if size != 8192 || err == nil {
		t.Fatalf("du lost partial bytes or failure: %d, %v", size, err)
	}
	var files, dirs, bytes int64
	current := &atomic.Value{}
	current.Store("")
	result, err := scanPathConcurrentWithOptions(context.Background(), root, &files, &dirs, &bytes, current, false, 0)
	if err != nil {
		t.Fatal(err)
	}
	if result.State != scanPartial || result.TotalSize != 8192 || len(result.Entries) != 1 || result.Entries[0].State != scanPartial {
		t.Fatalf("partial du result was lost or replaced by fallback walk: %+v", result)
	}
}
