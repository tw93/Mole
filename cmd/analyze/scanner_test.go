//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/charmbracelet/x/ansi"
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

	total, err := getDirectoryLogicalSizeWithExclude(context.Background(), base, "", nil)
	if err != nil {
		t.Fatalf("getDirectoryLogicalSizeWithExclude (no exclude) error: %v", err)
	}
	if total != 600 {
		t.Fatalf("expected total 600 bytes, got %d", total)
	}

	excluding, err := getDirectoryLogicalSizeWithExclude(context.Background(), base, filepath.Join(base, "Library"), nil)
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
	size, err := getDirectorySizeFromDuSkippingImmediateChild(context.Background(), base, excluded, func(path string) (int64, error) {
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

func TestGetDirectorySizeFromDuMeasuresUserLibraryInOneTraversal(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	library := filepath.Join(home, "Library")
	writeFileWithSize(t, filepath.Join(library, "Application Support", "state.dat"), 4096)
	writeFileWithSize(t, filepath.Join(library, "Caches", "cache.dat"), 8192)
	writeFileWithSize(t, filepath.Join(library, "Containers", "app", "Mobile Documents", "nested.dat"), 4*1024*1024)
	writeFileWithSize(t, filepath.Join(library, "Mobile Documents", "cloud.dat"), 4*1024*1024)
	writeFileWithSize(t, filepath.Join(library, "top.plist"), 100)

	binDir := t.TempDir()
	operandLog := filepath.Join(binDir, "du-operands")
	stub := "#!/bin/sh\n" +
		"for operand; do :; done\n" +
		"printf '%s\\n' \"$operand\" >> \"$MOLE_TEST_DU_OPERANDS\"\n" +
		"exec /usr/bin/du \"$@\"\n"
	if err := os.WriteFile(filepath.Join(binDir, "du"), []byte(stub), 0o755); err != nil {
		t.Fatalf("write du stub: %v", err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	useDuStub(t, filepath.Join(binDir, "du"))
	t.Setenv("MOLE_TEST_DU_OPERANDS", operandLog)

	size, err := getDirectorySizeFromDuWithExcludeAndIgnores(context.Background(), library, "", overviewIgnoreNamesForPath(library), duTimeout)
	if err != nil {
		t.Fatalf("getDirectorySizeFromDuWithExcludeAndIgnores: %v", err)
	}
	if size < 4096+8192 {
		t.Fatalf("expected sibling sizes to be summed, got %d", size)
	}
	if size >= 1024*1024 {
		t.Fatalf("expected both Mobile Documents trees to be ignored, got %d", size)
	}

	data, err := os.ReadFile(operandLog)
	if err != nil {
		t.Fatalf("read du operands: %v", err)
	}
	got := strings.Split(strings.TrimSpace(string(data)), "\n")
	if len(got) != 1 || got[0] != library {
		t.Fatalf("expected one Library traversal for shared hardlink accounting, got %q", got)
	}
}

func TestOverviewPerChildDuPoolBelongsToOneMeasurement(t *testing.T) {
	workers := min(max(runtime.NumCPU()*2, 2), 8)
	stuckBase := t.TempDir()
	for i := range workers + 2 {
		if err := os.MkdirAll(filepath.Join(stuckBase, fmt.Sprintf("child-%d", i)), 0o755); err != nil {
			t.Fatalf("mkdir child: %v", err)
		}
	}
	freshBase := t.TempDir()
	if err := os.MkdirAll(filepath.Join(freshBase, "child"), 0o755); err != nil {
		t.Fatalf("mkdir child: %v", err)
	}

	// Hold every permit of one measurement on children that never finish,
	// the way a cancelled Home refresh can while its du processes wind down.
	release := make(chan struct{})
	stuckDone := make(chan struct{})
	var started atomic.Int64
	go func() {
		defer close(stuckDone)
		_, _ = getDirectorySizeFromDuSkippingImmediateChild(context.Background(), stuckBase, filepath.Join(stuckBase, "Library"), func(string) (int64, error) {
			started.Add(1)
			<-release
			return 100, nil
		})
	}()
	defer func() {
		close(release)
		<-stuckDone
	}()

	deadline := time.Now().Add(5 * time.Second)
	for started.Load() < int64(workers) {
		if time.Now().After(deadline) {
			t.Fatalf("expected %d concurrent du workers, saw %d", workers, started.Load())
		}
		time.Sleep(time.Millisecond)
	}

	// A new measurement gets its own permits instead of queueing behind the
	// stuck one.
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var calls atomic.Int64
	_, err := getDirectorySizeFromDuSkippingImmediateChild(ctx, freshBase, filepath.Join(freshBase, "Library"), func(string) (int64, error) {
		calls.Add(1)
		return 100, nil
	})
	if err != nil || calls.Load() != 1 {
		t.Fatalf("a stuck measurement held this one's permits: du calls=%d err=%v", calls.Load(), err)
	}
}

func TestGetDirectorySizeFromDuWithIgnoresSkipsCloudPlaceholderTree(t *testing.T) {
	base := t.TempDir()
	writeFileWithSize(t, filepath.Join(base, "Application Support", "state.dat"), 4096)
	writeFileWithSize(t, filepath.Join(base, "Mobile Documents", "cloud.dat"), 1024*1024)

	withoutIgnore, err := getDirectorySizeFromDuWithExcludeAndIgnores(context.Background(), base, "", nil, duTimeout)
	if err != nil {
		t.Fatalf("getDirectorySizeFromDuWithExcludeAndIgnores without ignore: %v", err)
	}
	withIgnore, err := getDirectorySizeFromDuWithExcludeAndIgnores(context.Background(), base, "", []string{"Mobile Documents"}, duTimeout)
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

func TestDuIgnoresUseSystemDuWhenGNUDuIsFirstInPath(t *testing.T) {
	base := t.TempDir()
	writeFileWithSize(t, filepath.Join(base, "Application Support", "state.dat"), 4096)
	writeFileWithSize(t, filepath.Join(base, "Mobile Documents", "cloud.dat"), 1024*1024)

	// GNU coreutils du has no -I, so a gnubin PATH broke every ignore-aware
	// size, including the User Library overview row.
	stubDir := t.TempDir()
	stub := "#!/bin/sh\nfor arg; do [ \"$arg\" = -I ] && { echo \"du: invalid option -- 'I'\" >&2; exit 1; }; done\nexec /usr/bin/du \"$@\"\n"
	if err := os.WriteFile(filepath.Join(stubDir, "du"), []byte(stub), 0o755); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", stubDir+string(os.PathListSeparator)+os.Getenv("PATH"))

	size, err := getDirectorySizeFromDuWithExcludeAndIgnores(context.Background(), base, "", []string{"Mobile Documents"}, duTimeout)
	if err != nil {
		t.Fatalf("ignore-aware size failed with a GNU du in PATH: %v", err)
	}
	if size <= 0 || size >= 1024*1024 {
		t.Fatalf("expected the ignored tree to be skipped, got %d", size)
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
	scan := func(scanRoot string) scanResult {
		t.Helper()
		var files, dirs, bytes int64
		current := &atomic.Value{}
		current.Store("")
		result, err := scanPathConcurrentWithLimiter(context.Background(), scanRoot, &files, &dirs, &bytes, current, false, 0, nil, scanCacheBypass, newScanPublication(context.Background(), nil))
		if err != nil {
			t.Fatal(err)
		}
		return result
	}
	good := scan(root)
	if good.State != scanComplete {
		t.Fatalf("initial scan state = %s", good.State)
	}
	if err := saveCacheToDisk(root, good); err != nil {
		t.Fatal(err)
	}
	if err := saveCacheToDisk(child, scan(child)); err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	partial := scan(root)
	if partial.State != scanPartial || partial.TotalSize != 4096 || partial.TotalFiles != 1 {
		t.Fatalf("partial result lost coverage or readable bytes: %+v", partial)
	}
	if len(partial.Entries) != 1 || partial.Entries[0].State != scanPartial {
		t.Fatalf("child coverage not propagated: %+v", partial.Entries)
	}
	if partial.transientFailure {
		t.Fatal("a chmod 000 denial was classified as transient")
	}
	transient := partial
	transient.transientFailure = true
	if err := saveCacheToDisk(root, transient); err != nil {
		t.Fatal(err)
	}
	cached, err := loadCacheFromDisk(root)
	if err != nil || cached.TotalSize != good.TotalSize {
		t.Fatalf("transient partial scan replaced good cache: %+v, %v", cached, err)
	}
	// A denial-only partial is the current answer and replaces stale caches.
	if childCache, err := loadCacheFromDisk(child); err == nil && childCache.State == scanComplete {
		t.Fatalf("stale complete child cache survived a denial-only rescan: %+v", childCache)
	}
	if err := saveCacheToDisk(root, partial); err != nil {
		t.Fatal(err)
	}
	cached, err = loadCacheFromDisk(root)
	if err != nil || cached.State != scanPartial || cached.TotalSize != partial.TotalSize {
		t.Fatalf("denial-only partial was not cached as partial: %+v, %v", cached, err)
	}
	if err := os.Chmod(locked, 0o755); err != nil {
		t.Fatal(err)
	}
	recovered := scan(root)
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
	useDuStub(t, filepath.Join(stubDir, "du"))
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

func TestDuFailureKeepsDiagnosticAndPartialBytes(t *testing.T) {
	for _, tc := range []struct {
		name       string
		stdout     string
		diagnostic string
		wantSize   int64
		permission bool
	}{
		{"partial", "8", "Resource deadlock avoided", 8192, false},
		{"unavailable", "", "Resource deadlock avoided", 0, false},
		{"permission", "8", "Permission denied", 8192, true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			root := filepath.Join(t.TempDir(), "path: with spaces")
			if err := os.Mkdir(root, 0o755); err != nil {
				t.Fatal(err)
			}
			stubDir := t.TempDir()
			script := "#!/bin/sh\nfor target do :; done\n"
			if tc.stdout != "" {
				script += "printf '" + tc.stdout + "\\t%s\\n' \"$target\"\n"
			}
			script += "printf 'du: %s: " + tc.diagnostic + "\\n' \"$target\" >&2\nexit 1\n"
			if err := os.WriteFile(filepath.Join(stubDir, "du"), []byte(script), 0o755); err != nil {
				t.Fatal(err)
			}
			t.Setenv("PATH", stubDir)
			useDuStub(t, filepath.Join(stubDir, "du"))
			size, err := getDirectorySizeFromDu(context.Background(), root)
			if size != tc.wantSize || err == nil || !strings.Contains(err.Error(), tc.diagnostic) {
				t.Fatalf("du lost subtotal or diagnostic: size=%d err=%v", size, err)
			}
			if isPermissionFailure(err) != tc.permission {
				t.Fatalf("du changed permission classification: %v", err)
			}
			var exitErr *exec.ExitError
			if !errors.As(err, &exitErr) || exitErr.ExitCode() != 1 {
				t.Fatalf("du lost its process failure: %v", err)
			}
			pending := filepath.Join(root, "pending")
			m := model{
				path: "/", isOverview: true, width: 80, height: 24,
				entries: []dirEntry{
					{Name: "Xcode Simulators", Path: root, IsDir: true, Size: -1},
					{Name: "Pending", Path: pending, IsDir: true, Size: -1},
				},
				overviewScanningSet: map[string]*scanPublication{pending: {}},
			}
			updated, _ := m.Update(overviewSizeMsg{Path: root, Size: size, Err: err})
			m = updated.(model)
			wantReason := tc.diagnostic
			if tc.permission {
				wantReason = "access denied"
			}
			for _, width := range []int{60, 80, 120} {
				m.width = width
				view := m.View()
				foundReason := false
				for line := range strings.SplitSeq(view, "\n") {
					if strings.Contains(line, wantReason) {
						foundReason = true
						if ansi.StringWidth(line) > width {
							t.Fatalf("diagnostic overflows %d columns: %q", width, line)
						}
					}
				}
				if !foundReason || strings.Contains(view, root) {
					t.Fatalf("diagnostic was lost or path repeated at width %d: %s", width, view)
				}
			}
		})
	}
}

func TestOverviewMeasurementStoresDenialOnlyPartial(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission fixture requires an unprivileged user")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	locked := filepath.Join(root, "locked")
	writeFileWithSize(t, filepath.Join(root, "readable"), 4096)
	writeFileWithSize(t, filepath.Join(locked, "hidden"), 1<<20)
	good, err := measureOverviewSize(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	partial, err := measureOverviewSize(context.Background(), root)
	if err == nil || partial < 4096 || partial >= good {
		t.Fatalf("overview must retain partial bytes and error: good=%d partial=%d err=%v", good, partial, err)
	}
	cached, state, err := loadStoredOverviewMeasurement(root)
	if err != nil || cached != partial || state != scanPartial {
		t.Fatalf("denial-only measurement was not stored as partial: %d, %s, %v", cached, state, err)
	}
	logical, err := getDirectoryLogicalSizeWithExclude(context.Background(), root, "", nil)
	if err == nil || logical != 4096 {
		t.Fatalf("fallback erased failure: %d, %v", logical, err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, err = measureOverviewSize(ctx, root)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("cancellation lost: %v", err)
	}
}

func TestUserLibraryOverviewDeduplicatesHardlinks(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	library := filepath.Join(home, "Library")
	original := filepath.Join(library, "Application Support", "payload")
	writeFileWithSize(t, original, 1024*1024)
	for _, link := range []string{filepath.Join(library, "Caches", "payload"), filepath.Join(library, "top-link")} {
		if err := os.MkdirAll(filepath.Dir(link), 0755); err != nil {
			t.Fatal(err)
		}
		if err := os.Link(original, link); err != nil {
			t.Fatal(err)
		}
	}
	out, err := exec.Command("/usr/bin/du", "-skPx", library).Output()
	if err != nil {
		t.Fatal(err)
	}
	kb, err := strconv.ParseInt(strings.Fields(string(out))[0], 10, 64)
	if err != nil {
		t.Fatal(err)
	}
	got, err := getDirectorySizeFromDuWithExcludeAndIgnores(context.Background(), library, "", nil, duTimeout)
	if err != nil {
		t.Fatal(err)
	}
	if got != kb*1024 {
		t.Fatalf("Library size = %d, single du = %d; hardlinks must count once", got, kb*1024)
	}
}
