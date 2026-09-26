//go:build darwin

package main

import (
	"context"
	"encoding/gob"
	"encoding/json"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// Navigation starts a replacement scan immediately, so abandoned scan work
// must release its subprocesses and workers before it can compete for I/O.
const liveScanCancellationBudget = 250 * time.Millisecond

func resetOverviewSnapshotForTest() {
	overviewSnapshotMu.Lock()
	overviewSnapshotCache = nil
	overviewSnapshotLoaded = false
	overviewSnapshotMu.Unlock()
}

func runScanResultCmd(t *testing.T, cmd tea.Cmd) scanResultMsg {
	t.Helper()

	msg := cmd()
	if scanMsg, ok := scanResultMsgFromMsg(t, msg); ok {
		return scanMsg
	}
	t.Fatalf("expected scanResultMsg or live scan result, got %T", msg)
	return scanResultMsg{}
}

func scanResultMsgFromMsg(t *testing.T, msg tea.Msg) (scanResultMsg, bool) {
	t.Helper()

	switch typed := msg.(type) {
	case scanResultMsg:
		return typed, true
	case liveScanStartMsg:
		return drainLiveScanToResultMsg(t, typed), true
	case tea.BatchMsg:
		for _, batchCmd := range typed {
			if batchCmd == nil {
				continue
			}
			if scanMsg, ok := scanResultMsgFromMsg(t, batchCmd()); ok {
				return scanMsg, true
			}
		}
		return scanResultMsg{}, false
	default:
		return scanResultMsg{}, false
	}
}

func drainLiveScanToResultMsg(t *testing.T, start liveScanStartMsg) scanResultMsg {
	t.Helper()
	if start.err != nil {
		return scanResultMsg{path: start.path, err: start.err}
	}
	deadline := time.After(5 * time.Second)
	for {
		select {
		case event, ok := <-start.events:
			if !ok {
				t.Fatalf("live scan event channel closed without completion")
			}
			switch event.kind {
			case liveScanComplete:
				return scanResultMsg{path: start.path, result: event.result}
			case liveScanFailed:
				return scanResultMsg{path: start.path, err: event.err}
			}
		case <-deadline:
			if start.cancel != nil {
				start.cancel()
			}
			t.Fatalf("timed out waiting for live scan completion")
		}
	}
}

func cancelAndDrainLiveScan(start liveScanStartMsg) {
	if start.cancel != nil {
		start.cancel()
	}
	for range start.events {
	}
}

func installBlockingDuProbe(t *testing.T) string {
	t.Helper()

	binDir := t.TempDir()
	started := filepath.Join(binDir, "du-started")
	duStub := filepath.Join(binDir, "du")
	stub := "#!/bin/sh\n" +
		"printf started > \"$MOLE_TEST_DU_STARTED\"\n" +
		"exec /usr/bin/tail -f /dev/null\n"
	if err := os.WriteFile(duStub, []byte(stub), 0o755); err != nil {
		t.Fatalf("write du stub: %v", err)
	}
	t.Setenv("PATH", binDir+string(os.PathListSeparator)+os.Getenv("PATH"))
	t.Setenv("MOLE_TEST_DU_STARTED", started)
	return started
}

func waitForTestPath(t *testing.T, path string) {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	for {
		if _, err := os.Stat(path); err == nil {
			return
		}
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", path)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func waitForTestCondition(t *testing.T, description string, condition func() bool) {
	t.Helper()

	deadline := time.Now().Add(5 * time.Second)
	for !condition() {
		if time.Now().After(deadline) {
			t.Fatalf("timed out waiting for %s", description)
		}
		time.Sleep(5 * time.Millisecond)
	}
}

func rowContaining(view, needle string) string {
	for line := range strings.SplitSeq(view, "\n") {
		if strings.Contains(line, needle) {
			return line
		}
	}
	return ""
}

func progressFillCount(row string) int {
	return strings.Count(row, "█") + strings.Count(row, "▓") + strings.Count(row, "▒")
}

func TestScanPathConcurrentBasic(t *testing.T) {
	root := t.TempDir()

	rootFile := filepath.Join(root, "root.txt")
	if err := os.WriteFile(rootFile, []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root file: %v", err)
	}

	nested := filepath.Join(root, "nested")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("create nested dir: %v", err)
	}

	fileOne := filepath.Join(nested, "a.bin")
	if err := os.WriteFile(fileOne, []byte("alpha"), 0o644); err != nil {
		t.Fatalf("write file one: %v", err)
	}
	fileTwo := filepath.Join(nested, "b.bin")
	if err := os.WriteFile(fileTwo, []byte(strings.Repeat("b", 32)), 0o644); err != nil {
		t.Fatalf("write file two: %v", err)
	}

	linkPath := filepath.Join(root, "link-to-a")
	if err := os.Symlink(fileOne, linkPath); err != nil {
		t.Fatalf("create symlink: %v", err)
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	result, err := scanPathConcurrent(context.Background(), root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent returned error: %v", err)
	}

	linkInfo, err := os.Lstat(linkPath)
	if err != nil {
		t.Fatalf("stat symlink: %v", err)
	}

	expectedDirSize := int64(len("alpha") + len(strings.Repeat("b", 32)))
	expectedRootFileSize := int64(len("root-data"))
	expectedLinkSize := getActualFileSize(linkPath, linkInfo)
	expectedTotal := expectedDirSize + expectedRootFileSize + expectedLinkSize

	if result.TotalSize != expectedTotal {
		t.Fatalf("expected total size %d, got %d", expectedTotal, result.TotalSize)
	}

	if got := atomic.LoadInt64(&filesScanned); got != 3 {
		t.Fatalf("expected 3 files scanned, got %d", got)
	}
	if dirs := atomic.LoadInt64(&dirsScanned); dirs == 0 {
		t.Fatalf("expected directory scan count to increase")
	}
	if bytes := atomic.LoadInt64(&bytesScanned); bytes == 0 {
		t.Fatalf("expected byte counter to increase")
	}
	foundSymlink := false
	for _, entry := range result.Entries {
		if strings.HasSuffix(entry.Name, " →") {
			foundSymlink = true
			if entry.IsDir {
				t.Fatalf("symlink entry should not be marked as directory")
			}
		}
	}
	if !foundSymlink {
		t.Fatalf("expected symlink entry to be present in scan result")
	}
}

// TestScanPathConcurrentDedupsHardlinks guards #906: a file with multiple
// hardlinks (e.g. Final Cut Pro managed media) must be counted once, the way
// `du` does, instead of once per link.
func TestScanPathConcurrentDedupsHardlinks(t *testing.T) {
	root := t.TempDir()

	nested := filepath.Join(root, "nested")
	other := filepath.Join(root, "other")
	for _, d := range []string{nested, other} {
		if err := os.MkdirAll(d, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", d, err)
		}
	}

	original := filepath.Join(nested, "media.bin")
	if err := os.WriteFile(original, []byte(strings.Repeat("x", 4096)), 0o644); err != nil {
		t.Fatalf("write original: %v", err)
	}
	// Two more hardlinks to the same inode, one in this dir and one in a
	// sibling dir, so the shared scan-wide dedup set is exercised.
	for _, link := range []string{
		filepath.Join(nested, "media-copy.bin"),
		filepath.Join(other, "media-link.bin"),
	} {
		if err := os.Link(original, link); err != nil {
			t.Fatalf("hardlink %s: %v", link, err)
		}
	}
	// An unrelated plain file that must still be counted in full.
	plain := filepath.Join(other, "plain.bin")
	if err := os.WriteFile(plain, []byte("plaindata"), 0o644); err != nil {
		t.Fatalf("write plain: %v", err)
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	result, err := scanPathConcurrent(context.Background(), root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent returned error: %v", err)
	}

	mediaInfo, err := os.Lstat(original)
	if err != nil {
		t.Fatalf("stat original: %v", err)
	}
	plainInfo, err := os.Lstat(plain)
	if err != nil {
		t.Fatalf("stat plain: %v", err)
	}
	want := getActualFileSize(original, mediaInfo) + getActualFileSize(plain, plainInfo)
	if result.TotalSize != want {
		t.Fatalf("expected hardlinked media counted once (total %d), got %d", want, result.TotalSize)
	}
	if !result.dedupedHardlink {
		t.Fatalf("expected dedupedHardlink flag to be set when a hardlink is deduped")
	}
}

func TestPerformScanForJSONCountsTopLevelFiles(t *testing.T) {
	root := t.TempDir()

	rootFile := filepath.Join(root, "root.txt")
	if err := os.WriteFile(rootFile, []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root file: %v", err)
	}

	nested := filepath.Join(root, "nested")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("create nested dir: %v", err)
	}

	nestedFile := filepath.Join(nested, "nested.txt")
	if err := os.WriteFile(nestedFile, []byte("nested-data"), 0o644); err != nil {
		t.Fatalf("write nested file: %v", err)
	}

	result := performScanForJSON(root, false)

	if result.TotalFiles != 2 {
		t.Fatalf("expected 2 files in JSON output, got %d", result.TotalFiles)
	}
}

func TestDeletePathWithProgress(t *testing.T) {
	skipIfFinderUnavailable(t)

	parent := t.TempDir()
	target := filepath.Join(parent, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	files := []string{
		filepath.Join(target, "one.txt"),
		filepath.Join(target, "two.txt"),
	}
	for _, f := range files {
		if err := os.WriteFile(f, []byte("content"), 0o644); err != nil {
			t.Fatalf("write %s: %v", f, err)
		}
	}

	var counter int64
	count, err := trashPathWithProgress(target, &counter)
	if err != nil {
		t.Fatalf("trashPathWithProgress returned error: %v", err)
	}
	if count != 1 {
		t.Fatalf("expected one path-level Trash operation, got %d", count)
	}
	if _, err := os.Stat(target); !os.IsNotExist(err) {
		t.Fatalf("expected target to be moved to Trash, stat err=%v", err)
	}
}

func TestOverviewStoreAndLoad(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	path := filepath.Join(home, "project")
	want := int64(123456)

	if err := storeOverviewSize(path, want); err != nil {
		t.Fatalf("storeOverviewSize: %v", err)
	}

	got, err := loadStoredOverviewSize(path)
	if err != nil {
		t.Fatalf("loadStoredOverviewSize: %v", err)
	}
	if got != want {
		t.Fatalf("snapshot mismatch: want %d, got %d", want, got)
	}

	// Reload from disk and ensure value persists.
	resetOverviewSnapshotForTest()
	got, err = loadStoredOverviewSize(path)
	if err != nil {
		t.Fatalf("loadStoredOverviewSize after reset: %v", err)
	}
	if got != want {
		t.Fatalf("snapshot mismatch after reset: want %d, got %d", want, got)
	}
}

func TestUpdateKeyEscGoesBackFromDirectoryView(t *testing.T) {
	m := model{
		path: "/tmp/child",
		history: []historyEntry{
			{
				Path:        "/tmp",
				Entries:     []dirEntry{{Name: "child", Path: "/tmp/child", Size: 1, IsDir: true}},
				TotalSize:   1,
				Selected:    0,
				EntryOffset: 0,
			},
		},
		entries: []dirEntry{{Name: "file.txt", Path: "/tmp/child/file.txt", Size: 1}},
	}

	updated, cmd := m.updateKey(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd != nil {
		t.Fatalf("expected no command when returning from cached history, got %v", cmd)
	}

	got, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	if got.path != "/tmp" {
		t.Fatalf("expected path /tmp after Esc, got %s", got.path)
	}
	if got.status == "" {
		t.Fatalf("expected status to be updated after Esc navigation")
	}
}

func TestUpdateKeyCtrlCQuits(t *testing.T) {
	m := model{}

	_, cmd := m.updateKey(tea.KeyMsg{Type: tea.KeyCtrlC})
	if cmd == nil {
		t.Fatalf("expected quit command for Ctrl+C")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatalf("expected tea.QuitMsg from quit command")
	}
}

func TestIsAppBundleEntry(t *testing.T) {
	tests := []struct {
		name  string
		entry dirEntry
		want  bool
	}{
		{name: "lowercase bundle", entry: dirEntry{Name: "Safari.app", IsDir: true}, want: true},
		{name: "uppercase extension", entry: dirEntry{Name: "Safari.APP", IsDir: true}, want: true},
		{name: "file", entry: dirEntry{Name: "report.app", IsDir: false}, want: false},
		{name: "longer extension", entry: dirEntry{Name: "Notes.application", IsDir: true}, want: false},
		{name: "no extension", entry: dirEntry{Name: "Safari", IsDir: true}, want: false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := isAppBundleEntry(tt.entry); got != tt.want {
				t.Errorf("isAppBundleEntry(%+v) = %v, want %v", tt.entry, got, tt.want)
			}
		})
	}
}

func TestUninstallCommandForApp(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		{name: "simple", input: "Safari.app", want: "mo uninstall Safari"},
		{name: "space", input: "Google Chrome.app", want: "mo uninstall 'Google Chrome'"},
		{name: "dollar", input: "My$App.app", want: "mo uninstall 'My$App'"},
		{name: "command substitution", input: "Unsafe$(printf HACKED).app", want: "mo uninstall 'Unsafe$(printf HACKED)'"},
		{name: "semicolon", input: "Foo;Bar.app", want: "mo uninstall 'Foo;Bar'"},
		{name: "backtick", input: "My`App.app", want: "mo uninstall 'My`App'"},
		{name: "single quote", input: "Bob's App.app", want: `mo uninstall 'Bob'\''s App'`},
		{name: "leading dash", input: "-Example.app", want: "mo uninstall <App>"},
		{name: "tab", input: "Tabbed\tApp.app", want: "mo uninstall <App>"},
		{name: "newline", input: "Split\nApp.app", want: "mo uninstall <App>"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := uninstallCommandForApp(tt.input); got != tt.want {
				t.Errorf("uninstallCommandForApp(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestViewDeleteConfirmShowsUninstallHintForAppBundle(t *testing.T) {
	entry := dirEntry{Name: "Safari.app", Path: "/Applications/Safari.app", Size: 1, IsDir: true}
	m := model{
		path:          "/Applications",
		entries:       []dirEntry{entry},
		deleteConfirm: true,
		deleteTarget:  &entry,
	}

	view := m.View()
	if !strings.Contains(view, "mo uninstall Safari") {
		t.Fatalf("expected app-specific uninstall command, got:\n%s", view)
	}
	if !strings.Contains(view, "bundle only") {
		t.Fatalf("expected bundle-only warning, got:\n%s", view)
	}
}

func TestViewDeleteConfirmNoHintForRegularDirectory(t *testing.T) {
	entry := dirEntry{Name: "cache", Path: "/tmp/cache", Size: 1, IsDir: true}
	m := model{
		path:          "/tmp",
		entries:       []dirEntry{entry},
		deleteConfirm: true,
		deleteTarget:  &entry,
	}

	view := m.View()
	if strings.Contains(view, "mo uninstall") {
		t.Fatalf("did not expect uninstall hint for a regular directory, got:\n%s", view)
	}
}

func TestViewDeleteConfirmMultiSelectShowsGenericHint(t *testing.T) {
	app := dirEntry{Name: "Safari.app", Path: "/Applications/Safari.app", Size: 1, IsDir: true}
	cache := dirEntry{Name: "cache", Path: "/Applications/cache", Size: 1, IsDir: true}
	m := model{
		path:          "/Applications",
		entries:       []dirEntry{app, cache},
		multiSelected: map[string]bool{app.Path: true, cache.Path: true},
		deleteConfirm: true,
		deleteTarget:  &cache,
	}

	view := m.View()
	if !strings.Contains(view, "mo uninstall <App>") {
		t.Fatalf("expected generic uninstall hint for multi-select containing an app bundle, got:\n%s", view)
	}
}

func TestViewShowsEscBackAndCtrlCQuitHints(t *testing.T) {
	m := model{
		path:       "/tmp/project",
		history:    []historyEntry{{Path: "/tmp"}},
		entries:    []dirEntry{{Name: "cache", Path: "/tmp/project/cache", Size: 1, IsDir: true}},
		largeFiles: []fileEntry{{Name: "large.bin", Path: "/tmp/project/large.bin", Size: 1024}},
		totalSize:  1024,
	}

	view := m.View()
	if !strings.Contains(view, "Esc Back") {
		t.Fatalf("expected Esc Back hint in view, got:\n%s", view)
	}
	if !strings.Contains(view, "Ctrl+C Quit") {
		t.Fatalf("expected Ctrl+C Quit hint in view, got:\n%s", view)
	}
}

func TestOverviewPendingSizeUsesScanningSpinner(t *testing.T) {
	// A pending overview row reuses the list view's animated scanning idiom
	// instead of a static text placeholder: "pending.." broke the numeric
	// column rhythm, and a static "--" read as stuck. The spinner string is
	// exactly 10 display columns, flush with the right-aligned sizes.
	m := model{
		isOverview: true,
		path:       "/",
		entries: []dirEntry{
			{Name: "Applications", Path: "/Applications", Size: 16 << 30, IsDir: true},
			{Name: "iOS Backups", Path: "/tmp/backups", Size: -1, IsDir: true},
		},
		totalSize: 16 << 30,
	}

	view := m.View()
	if strings.Contains(view, "pending") {
		t.Fatalf("pending rows must not render a text placeholder, got:\n%s", view)
	}
	if !strings.Contains(view, fmt.Sprintf("%s scanning", spinnerFrames[0])) {
		t.Fatalf("expected animated scanning placeholder for pending row, got:\n%s", view)
	}
}

func TestViewKeepsCachedEntriesWhileRefreshing(t *testing.T) {
	m := model{
		path:             "/tmp/project/child",
		history:          []historyEntry{{Path: "/tmp/project"}},
		entries:          []dirEntry{{Name: "warmed-child", Path: "/tmp/project/child/warmed-child", Size: 100, IsDir: true}},
		totalSize:        100,
		scanning:         true,
		viewNeedsRefresh: true,
	}

	view := m.View()
	if !strings.Contains(view, "warmed-child") {
		t.Fatalf("expected cached entry to render during refresh, got:\n%s", view)
	}
	if !strings.Contains(view, "Showing cached results while refreshing") {
		t.Fatalf("expected refreshing hint during cached refresh, got:\n%s", view)
	}
}

func TestViewBlanksToScanOnlyWithoutWarmCache(t *testing.T) {
	// Right after entering an uncached child, m.entries still holds the parent's
	// stale entries while viewNeedsRefresh is false. The view must not paint
	// those stale rows under the new path; it stays scan-only until results land.
	m := model{
		path:             "/tmp/project/child",
		history:          []historyEntry{{Path: "/tmp/project"}},
		entries:          []dirEntry{{Name: "stale-parent-row", Path: "/tmp/project/stale-parent-row", Size: 100, IsDir: true}},
		totalSize:        100,
		scanning:         true,
		viewNeedsRefresh: false,
	}

	view := m.View()
	if strings.Contains(view, "stale-parent-row") {
		t.Fatalf("expected scan-only view to hide stale entries, got:\n%s", view)
	}
	if strings.Contains(view, "Showing cached results while refreshing") {
		t.Fatalf("did not expect cached-refresh hint without a warm cache, got:\n%s", view)
	}
	if !strings.Contains(view, "Scanning") {
		t.Fatalf("expected scan-only view to show scanning progress, got:\n%s", view)
	}
}

func TestOverviewViewShowsFreeSpaceLabel(t *testing.T) {
	m := model{
		path:       "/",
		isOverview: true,
		diskFree:   123_400_000,
		entries:    []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	view := m.View()
	want := fmt.Sprintf("(%s free)", humanizeBytes(m.diskFree))
	if !strings.Contains(view, want) {
		t.Fatalf("expected free-space label %q in overview view, got:\n%s", want, view)
	}
}

func TestOverviewViewOmitsFreeSpaceLabelWhenUnknown(t *testing.T) {
	m := model{
		path:       "/",
		isOverview: true,
		diskFree:   0,
		entries:    []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	view := m.View()
	if strings.Contains(view, "free)") {
		t.Fatalf("expected overview view to omit free-space label when unavailable, got:\n%s", view)
	}
}

func TestOverviewViewUsesTextOnlyLabels(t *testing.T) {
	m := model{
		path:       "/",
		isOverview: true,
		entries: []dirEntry{
			{Name: "Home", Path: "/tmp/home", Size: 80, IsDir: true},
			{Name: "iOS Backups", Path: "/tmp/backups", Size: 20, IsDir: true},
		},
		totalSize: 100,
	}

	view := m.View()
	for _, label := range []string{"Home", "iOS Backups"} {
		if !strings.Contains(view, label) {
			t.Fatalf("expected overview label %q, got:\n%s", label, view)
		}
	}
	for _, icon := range []string{"📁", "👀"} {
		if strings.Contains(view, icon) {
			t.Fatalf("overview should not render emoji icon %q, got:\n%s", icon, view)
		}
	}
}

func TestDirectoryViewKeepsLowPercentRowsAligned(t *testing.T) {
	m := model{
		path:      "/tmp/project",
		width:     120,
		height:    20,
		selected:  -1,
		totalSize: 100_000,
		entries: []dirEntry{
			{Name: "large", Path: "/tmp/project/large", Size: 47_000, IsDir: true},
			{Name: "tiny", Path: "/tmp/project/tiny", Size: 46, IsDir: true},
		},
	}

	stripColors := strings.NewReplacer(
		colorPurple, "",
		colorPurpleBold, "",
		colorGray, "",
		colorRed, "",
		colorYellow, "",
		colorGreen, "",
		colorBlue, "",
		colorCyan, "",
		colorReset, "",
		colorBold, "",
	)
	largeRow := stripColors.Replace(rowContaining(m.View(), "large"))
	tinyRow := stripColors.Replace(rowContaining(m.View(), "tiny"))
	if !strings.Contains(tinyRow, "< 0.1%") {
		t.Fatalf("expected tiny row to show < 0.1%%, got:\n%s", tinyRow)
	}
	if strings.Contains(m.View(), "░") {
		t.Fatalf("directory view should not render gray progress tracks:\n%s", m.View())
	}

	largePrefix, _, largeHasDivider := strings.Cut(largeRow, "  |  ")
	tinyPrefix, _, tinyHasDivider := strings.Cut(tinyRow, "  |  ")
	if !largeHasDivider || !tinyHasDivider {
		t.Fatalf("missing percent divider\nlarge: %q\ntiny:  %q", largeRow, tinyRow)
	}
	largeDividerColumn := displayWidth(largePrefix)
	tinyDividerColumn := displayWidth(tinyPrefix)
	if largeDividerColumn != tinyDividerColumn {
		t.Fatalf("percent divider columns differ: large=%d tiny=%d\nlarge: %q\ntiny:  %q",
			largeDividerColumn, tinyDividerColumn, largeRow, tinyRow)
	}
	if largeWidth, tinyWidth := displayWidth(largeRow), displayWidth(tinyRow); largeWidth != tinyWidth {
		t.Fatalf("row widths differ: large=%d tiny=%d\nlarge: %q\ntiny:  %q",
			largeWidth, tinyWidth, largeRow, tinyRow)
	}
}

func TestCacheSaveLoadRoundTrip(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "cache-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target dir: %v", err)
	}

	result := scanResult{
		Entries: []dirEntry{
			{Name: "alpha", Path: filepath.Join(target, "alpha"), Size: 10, IsDir: true},
		},
		LargeFiles: []fileEntry{
			{Name: "big.bin", Path: filepath.Join(target, "big.bin"), Size: 2048},
		},
		TotalSize: 42,
	}

	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cache, err := loadCacheFromDisk(target)
	if err != nil {
		t.Fatalf("loadCacheFromDisk: %v", err)
	}
	if cache.TotalSize != result.TotalSize {
		t.Fatalf("total size mismatch: want %d, got %d", result.TotalSize, cache.TotalSize)
	}
	if len(cache.Entries) != len(result.Entries) {
		t.Fatalf("entry count mismatch: want %d, got %d", len(result.Entries), len(cache.Entries))
	}
	if len(cache.LargeFiles) != len(result.LargeFiles) {
		t.Fatalf("large file count mismatch: want %d, got %d", len(result.LargeFiles), len(cache.LargeFiles))
	}
}

func TestPruneAnalyzerCacheDirRemovesOnlyExpiredCacheFiles(t *testing.T) {
	cacheDir := t.TempDir()
	now := time.Now()
	oldTime := now.Add(-analyzerCacheTTL - time.Hour)
	freshTime := now.Add(-time.Hour)

	oldCache := filepath.Join(cacheDir, "old.cache")
	freshCache := filepath.Join(cacheDir, "fresh.cache")
	namedState := filepath.Join(cacheDir, overviewCacheFile)
	cacheDirEntry := filepath.Join(cacheDir, "directory.cache")
	symlinkTarget := filepath.Join(cacheDir, "target")
	symlinkCache := filepath.Join(cacheDir, "link.cache")

	for _, path := range []string{oldCache, freshCache, namedState, symlinkTarget} {
		if err := os.WriteFile(path, []byte("cache"), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}
	if err := os.Mkdir(cacheDirEntry, 0o755); err != nil {
		t.Fatalf("mkdir cache dir entry: %v", err)
	}
	if err := os.Symlink(symlinkTarget, symlinkCache); err != nil {
		t.Fatalf("symlink cache entry: %v", err)
	}

	for _, path := range []string{oldCache, namedState, cacheDirEntry, symlinkCache} {
		if err := os.Chtimes(path, oldTime, oldTime); err != nil {
			t.Fatalf("chtimes %s: %v", path, err)
		}
	}
	if err := os.Chtimes(freshCache, freshTime, freshTime); err != nil {
		t.Fatalf("chtimes fresh cache: %v", err)
	}

	if err := pruneAnalyzerCacheDir(cacheDir, now); err != nil {
		t.Fatalf("pruneAnalyzerCacheDir: %v", err)
	}

	if _, err := os.Stat(oldCache); !os.IsNotExist(err) {
		t.Fatalf("expected expired cache file to be removed, stat err: %v", err)
	}
	for _, path := range []string{freshCache, namedState, cacheDirEntry, symlinkCache} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("expected %s to be preserved: %v", path, err)
		}
	}
}

func TestPruneAnalyzerCacheDirMissingDirectory(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing")
	if err := pruneAnalyzerCacheDir(missing, time.Now()); err != nil {
		t.Fatalf("expected missing cache dir to be ignored, got: %v", err)
	}
}

func TestPruneAnalyzerCacheDirIgnoresRemoveFailures(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("root can remove files from read-only directories")
	}

	cacheDir := t.TempDir()
	oldCache := filepath.Join(cacheDir, "old.cache")
	if err := os.WriteFile(oldCache, []byte("cache"), 0o644); err != nil {
		t.Fatalf("write old cache: %v", err)
	}
	oldTime := time.Now().Add(-analyzerCacheTTL - time.Hour)
	if err := os.Chtimes(oldCache, oldTime, oldTime); err != nil {
		t.Fatalf("chtimes old cache: %v", err)
	}

	if err := os.Chmod(cacheDir, 0o555); err != nil {
		t.Fatalf("chmod cache dir read-only: %v", err)
	}
	defer func() {
		_ = os.Chmod(cacheDir, 0o755)
	}()

	if err := pruneAnalyzerCacheDir(cacheDir, time.Now()); err != nil {
		t.Fatalf("expected remove failure to be ignored, got: %v", err)
	}
	if _, err := os.Stat(oldCache); err != nil {
		t.Fatalf("expected failed removal to leave cache file in place: %v", err)
	}
}

// writeAgedCacheFiles lays down n fresh cache files, oldest first, one minute
// apart so eviction order is unambiguous.
func writeAgedCacheFiles(t *testing.T, cacheDir string, n int, payload int) []string {
	t.Helper()
	base := time.Now().Add(-time.Duration(n) * time.Minute)
	names := make([]string, 0, n)
	for i := range n {
		name := filepath.Join(cacheDir, fmt.Sprintf("entry-%03d.cache", i))
		if err := os.WriteFile(name, []byte(strings.Repeat("x", payload)), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
		stamp := base.Add(time.Duration(i) * time.Minute)
		if err := os.Chtimes(name, stamp, stamp); err != nil {
			t.Fatalf("chtimes %s: %v", name, err)
		}
		names = append(names, name)
	}
	return names
}

// A TTL alone cannot bound a store whose entries are all refreshed inside it;
// the count cap is what keeps the newest N and drops the rest, oldest first.
func TestPruneAnalyzerCacheDirEnforcesEntryCap(t *testing.T) {
	cacheDir := t.TempDir()
	names := writeAgedCacheFiles(t, cacheDir, 10, 16)

	if err := pruneAnalyzerCacheDirWithLimits(cacheDir, time.Now(), 4, 0); err != nil {
		t.Fatalf("pruneAnalyzerCacheDirWithLimits: %v", err)
	}

	for i, name := range names {
		_, err := os.Stat(name)
		if i < 6 && !os.IsNotExist(err) {
			t.Fatalf("expected oldest entry %s to be evicted, stat err: %v", name, err)
		}
		if i >= 6 && err != nil {
			t.Fatalf("expected newest entry %s to be retained: %v", name, err)
		}
	}
}

func TestPruneAnalyzerCacheDirEnforcesByteCap(t *testing.T) {
	cacheDir := t.TempDir()
	names := writeAgedCacheFiles(t, cacheDir, 10, 100)

	// The count cap is set out of the way so only the byte cap can evict:
	// room for exactly three of the 100-byte entries.
	if err := pruneAnalyzerCacheDirWithLimits(cacheDir, time.Now(), len(names), 300); err != nil {
		t.Fatalf("pruneAnalyzerCacheDirWithLimits: %v", err)
	}

	for i, name := range names {
		_, err := os.Stat(name)
		if i < 7 && !os.IsNotExist(err) {
			t.Fatalf("expected oldest entry %s to be evicted, stat err: %v", name, err)
		}
		if i >= 7 && err != nil {
			t.Fatalf("expected newest entry %s to be retained: %v", name, err)
		}
	}
}

// The legacy flat store shares `~/.cache/mole` with shell-side state, so the
// sweep is scoped to the two names the analyzer ever wrote there.
func TestSweepLegacyAnalyzerCacheRemovesOnlyAnalyzerFiles(t *testing.T) {
	root := t.TempDir()

	legacyEntry := filepath.Join(root, "deadbeef.cache")
	legacyOverview := filepath.Join(root, overviewCacheFile)
	shellState := filepath.Join(root, "installed_apps_cache")
	permissionFlag := filepath.Join(root, "permissions_granted")
	for _, path := range []string{legacyEntry, legacyOverview, shellState, permissionFlag} {
		if err := os.WriteFile(path, []byte("state"), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}
	analyzerDir := filepath.Join(root, analyzerCacheDirName)
	if err := os.Mkdir(analyzerDir, 0o755); err != nil {
		t.Fatalf("mkdir analyzer dir: %v", err)
	}
	currentEntry := filepath.Join(analyzerDir, "deadbeef.cache")
	if err := os.WriteFile(currentEntry, []byte("current"), 0o644); err != nil {
		t.Fatalf("write current entry: %v", err)
	}

	if err := sweepLegacyAnalyzerCache(root); err != nil {
		t.Fatalf("sweepLegacyAnalyzerCache: %v", err)
	}

	for _, path := range []string{legacyEntry, legacyOverview} {
		if _, err := os.Stat(path); !os.IsNotExist(err) {
			t.Fatalf("expected legacy file %s to be swept, stat err: %v", path, err)
		}
	}
	for _, path := range []string{shellState, permissionFlag, currentEntry, analyzerDir} {
		if _, err := os.Lstat(path); err != nil {
			t.Fatalf("expected %s to be preserved: %v", path, err)
		}
	}
}

func TestSweepLegacyAnalyzerCacheMissingRoot(t *testing.T) {
	missing := filepath.Join(t.TempDir(), "missing")
	if err := sweepLegacyAnalyzerCache(missing); err != nil {
		t.Fatalf("expected missing root to be ignored, got: %v", err)
	}
}

// Rejecting an expired entry without deleting it leaves the file on disk for a
// whole TTL, waiting on a prune pass that may never reach it.
func TestLoadCacheFromDiskRemovesExpiredEntry(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	if err := saveCacheToDisk(target, scanResult{TotalSize: 1024, TotalFiles: 4}); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}

	expired := time.Now().Add(-analyzerCacheTTL - time.Hour)
	if err := os.Chtimes(cachePath, expired, expired); err != nil {
		t.Fatalf("chtimes cache: %v", err)
	}
	// ScanTime lives inside the payload, so age it there too.
	entry, err := loadRawCacheFromDisk(target)
	if err != nil {
		t.Fatalf("loadRawCacheFromDisk: %v", err)
	}
	entry.ScanTime = expired
	file, err := os.Create(cachePath)
	if err != nil {
		t.Fatalf("rewrite cache: %v", err)
	}
	if err := gob.NewEncoder(file).Encode(*entry); err != nil {
		file.Close() //nolint:errcheck
		t.Fatalf("encode cache: %v", err)
	}
	file.Close() //nolint:errcheck

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected expired cache to be rejected")
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("expected expired cache file to be deleted, stat err: %v", err)
	}
}

func TestLoadCacheFromDiskRemovesEntryForMissingDirectory(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	if err := saveCacheToDisk(target, scanResult{TotalSize: 1024, TotalFiles: 4}); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	if err := os.RemoveAll(target); err != nil {
		t.Fatalf("remove target: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected missing directory to fail the load")
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("expected orphaned cache file to be deleted, stat err: %v", err)
	}
}

func TestLoadRawCacheFromDiskRemovesUndecodableEntry(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	if err := os.WriteFile(cachePath, []byte("not gob"), 0o644); err != nil {
		t.Fatalf("write corrupt cache: %v", err)
	}

	if _, err := loadRawCacheFromDisk(target); err == nil {
		t.Fatalf("expected corrupt cache to fail decoding")
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("expected corrupt cache file to be deleted, stat err: %v", err)
	}
}

// getCacheDir memoizes MkdirAll, so it has to notice when HOME moves or every
// test after the first would write into the first one's temp directory.
func TestGetCacheDirFollowsHomeChanges(t *testing.T) {
	firstHome := t.TempDir()
	t.Setenv("HOME", firstHome)
	first, err := getCacheDir()
	if err != nil {
		t.Fatalf("getCacheDir(first): %v", err)
	}
	if !strings.HasPrefix(first, firstHome) {
		t.Fatalf("cache dir %q not under HOME %q", first, firstHome)
	}

	secondHome := t.TempDir()
	t.Setenv("HOME", secondHome)
	second, err := getCacheDir()
	if err != nil {
		t.Fatalf("getCacheDir(second): %v", err)
	}
	if !strings.HasPrefix(second, secondHome) {
		t.Fatalf("cache dir %q not under new HOME %q", second, secondHome)
	}
	if first == second {
		t.Fatalf("expected cache dir to change with HOME, got %q twice", first)
	}
	if _, err := os.Stat(second); err != nil {
		t.Fatalf("expected new cache dir to be created: %v", err)
	}
}

// Every save rewrites the whole overview store, so re-measuring a directory to
// the size already on record must not touch the disk at all.
func TestStoreOverviewSizeSkipsWriteWhenValueUnchanged(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	const target = "/Users/someone/project"
	if err := storeOverviewSize(target, 4096); err != nil {
		t.Fatalf("storeOverviewSize: %v", err)
	}
	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		t.Fatalf("getOverviewSizeStorePath: %v", err)
	}
	if err := os.Remove(storePath); err != nil {
		t.Fatalf("remove store: %v", err)
	}

	if err := storeOverviewSize(target, 4096); err != nil {
		t.Fatalf("storeOverviewSize(repeat): %v", err)
	}
	if _, err := os.Stat(storePath); !os.IsNotExist(err) {
		t.Fatalf("expected repeat save of an unchanged size to skip the write, stat err: %v", err)
	}

	if err := storeOverviewSize(target, 8192); err != nil {
		t.Fatalf("storeOverviewSize(changed): %v", err)
	}
	if _, err := os.Stat(storePath); err != nil {
		t.Fatalf("expected a changed size to be persisted: %v", err)
	}
}

func TestEnsureOverviewSnapshotCacheDropsExpiredAndLegacyEntries(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		t.Fatalf("getOverviewSizeStorePath: %v", err)
	}
	seeded := map[string]overviewSizeSnapshot{
		"/fresh":   {Size: 1 << 20, Updated: time.Now().Add(-time.Hour), SchemaVersion: cacheSchemaVersion},
		"/expired": {Size: 1 << 20, Updated: time.Now().Add(-overviewCacheTTL - time.Hour), SchemaVersion: cacheSchemaVersion},
		"/empty":   {Size: 0, Updated: time.Now(), SchemaVersion: cacheSchemaVersion},
		"/legacy":  {Size: 1 << 20, Updated: time.Now()},
	}
	data, err := json.Marshal(seeded)
	if err != nil {
		t.Fatalf("marshal seed: %v", err)
	}
	if err := os.WriteFile(storePath, data, 0o644); err != nil {
		t.Fatalf("write seed: %v", err)
	}

	if _, err := loadStoredOverviewSize("/fresh"); err != nil {
		t.Fatalf("expected fresh snapshot to load: %v", err)
	}

	overviewSnapshotMu.Lock()
	_, hasExpired := overviewSnapshotCache["/expired"]
	_, hasEmpty := overviewSnapshotCache["/empty"]
	_, hasLegacy := overviewSnapshotCache["/legacy"]
	_, hasFresh := overviewSnapshotCache["/fresh"]
	overviewSnapshotMu.Unlock()

	if hasExpired || hasEmpty || hasLegacy {
		t.Fatalf("expected expired, empty, and legacy snapshots to be dropped on load")
	}
	if !hasFresh {
		t.Fatalf("expected fresh snapshot to survive load")
	}
}

func TestEvictOverviewSnapshotsKeepsNewest(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	base := time.Now().Add(-time.Duration(overviewCacheMaxEntries+1) * time.Minute)
	overviewSnapshotMu.Lock()
	overviewSnapshotCache = make(map[string]overviewSizeSnapshot, overviewCacheMaxEntries+1)
	overviewSnapshotLoaded = true
	for i := range overviewCacheMaxEntries + 1 {
		overviewSnapshotCache[fmt.Sprintf("/dir-%04d", i)] = overviewSizeSnapshot{
			Size:          int64(i + 1),
			Updated:       base.Add(time.Duration(i) * time.Minute),
			SchemaVersion: cacheSchemaVersion,
		}
	}
	evictOverviewSnapshotsLocked()
	remaining := len(overviewSnapshotCache)
	_, oldestKept := overviewSnapshotCache["/dir-0000"]
	_, newestKept := overviewSnapshotCache[fmt.Sprintf("/dir-%04d", overviewCacheMaxEntries)]
	overviewSnapshotMu.Unlock()

	if remaining != overviewCacheKeepEntries {
		t.Fatalf("expected %d snapshots after eviction, got %d", overviewCacheKeepEntries, remaining)
	}
	if oldestKept {
		t.Fatalf("expected the oldest snapshot to be evicted")
	}
	if !newestKept {
		t.Fatalf("expected the newest snapshot to be kept")
	}
}

// Dropping snapshots one child at a time rewrote the whole overview store per
// child; the tree invalidation has to land as a single save.
func TestInvalidateCacheTreeDropsChildSnapshotsInOneSave(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()

	parent := filepath.Join(home, "parent")
	childA := filepath.Join(parent, "a")
	childB := filepath.Join(parent, "b")
	for _, dir := range []string{childA, childB} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", dir, err)
		}
	}
	for _, dir := range []string{parent, childA, childB} {
		if err := storeOverviewSize(dir, 1<<20); err != nil {
			t.Fatalf("storeOverviewSize(%s): %v", dir, err)
		}
		if err := saveCacheToDisk(dir, scanResult{TotalSize: 1 << 20, TotalFiles: 3}); err != nil {
			t.Fatalf("saveCacheToDisk(%s): %v", dir, err)
		}
	}

	storePath, err := getOverviewSizeStorePath()
	if err != nil {
		t.Fatalf("getOverviewSizeStorePath: %v", err)
	}
	if err := os.Remove(storePath); err != nil {
		t.Fatalf("remove store: %v", err)
	}

	invalidateCacheTree(parent)

	// Exactly one save recreated the file, and it holds none of the tree.
	data, err := os.ReadFile(storePath)
	if err != nil {
		t.Fatalf("expected the invalidation to persist once: %v", err)
	}
	var persisted map[string]overviewSizeSnapshot
	if err := json.Unmarshal(data, &persisted); err != nil {
		t.Fatalf("unmarshal store: %v", err)
	}
	for _, dir := range []string{parent, childA, childB} {
		if _, ok := persisted[dir]; ok {
			t.Fatalf("expected %s snapshot to be dropped", dir)
		}
		cachePath, err := getCachePath(dir)
		if err != nil {
			t.Fatalf("getCachePath(%s): %v", dir, err)
		}
		if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
			t.Fatalf("expected %s cache entry to be removed, stat err: %v", dir, err)
		}
	}
}

// Atomic saves stage through temp files, and prune is the only thing that ever
// looks in that directory: without this, a process killed mid-write leaks a
// temp file that nothing would ever collect.
func TestPruneAnalyzerCacheDirRemovesStaleTempFiles(t *testing.T) {
	cacheDir := t.TempDir()
	now := time.Now()

	staleTemp := filepath.Join(cacheDir, "entry-123.tmp")
	freshTemp := filepath.Join(cacheDir, "entry-456.tmp")
	liveCache := filepath.Join(cacheDir, "live.cache")
	for _, path := range []string{staleTemp, freshTemp, liveCache} {
		if err := os.WriteFile(path, []byte("payload"), 0o644); err != nil {
			t.Fatalf("write %s: %v", path, err)
		}
	}
	old := now.Add(-staleTempFileTTL - time.Minute)
	if err := os.Chtimes(staleTemp, old, old); err != nil {
		t.Fatalf("chtimes stale temp: %v", err)
	}

	if err := pruneAnalyzerCacheDir(cacheDir, now); err != nil {
		t.Fatalf("pruneAnalyzerCacheDir: %v", err)
	}

	if _, err := os.Stat(staleTemp); !os.IsNotExist(err) {
		t.Fatalf("expected stale temp file to be removed, stat err: %v", err)
	}
	for _, path := range []string{freshTemp, liveCache} {
		if _, err := os.Stat(path); err != nil {
			t.Fatalf("expected %s to be preserved: %v", path, err)
		}
	}
}

func TestSaveCacheToDiskLeavesNoTempFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	if err := saveCacheToDisk(target, scanResult{TotalSize: 2048, TotalFiles: 8}); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cacheDir, err := getCacheDir()
	if err != nil {
		t.Fatalf("getCacheDir: %v", err)
	}
	entries, err := os.ReadDir(cacheDir)
	if err != nil {
		t.Fatalf("read cache dir: %v", err)
	}
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".tmp") {
			t.Fatalf("expected no temp file left behind, found %s", entry.Name())
		}
	}
	if _, err := loadCacheFromDisk(target); err != nil {
		t.Fatalf("expected the entry to be readable after an atomic save: %v", err)
	}
}

func TestPeekCacheTotalFilesRejectsSchemaMismatch(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	file, err := os.Create(cachePath)
	if err != nil {
		t.Fatalf("create cache: %v", err)
	}
	stale := cacheEntry{TotalFiles: 42, SchemaVersion: cacheSchemaVersion + 1, ScanTime: time.Now()}
	if err := gob.NewEncoder(file).Encode(stale); err != nil {
		file.Close() //nolint:errcheck
		t.Fatalf("encode stale entry: %v", err)
	}
	file.Close() //nolint:errcheck

	if _, err := peekCacheTotalFiles(target); err == nil {
		t.Fatalf("expected a schema mismatch to be rejected")
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("expected the stale entry to be deleted, stat err: %v", err)
	}
}

// The analyzer store must not sit in the directory the shell side uses for its
// own state: the legacy sweep and the entry caps both assume they own it.
func TestGetCacheDirIsAnalyzerScoped(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root, err := getMoleCacheRoot()
	if err != nil {
		t.Fatalf("getMoleCacheRoot: %v", err)
	}
	cacheDir, err := getCacheDir()
	if err != nil {
		t.Fatalf("getCacheDir: %v", err)
	}
	if want := filepath.Join(root, analyzerCacheDirName); cacheDir != want {
		t.Fatalf("cache dir = %q, want %q", cacheDir, want)
	}
	if _, err := os.Stat(cacheDir); err != nil {
		t.Fatalf("expected cache dir to be created: %v", err)
	}
}

func TestScanPathConcurrentWarmsChildDirectoryCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "root.txt"), []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root data: %v", err)
	}
	// Only subtrees expensive enough to rescan are persisted, so the child has
	// to clear subdirCacheMinFiles to be warmed at all.
	for i := range subdirCacheMinFiles {
		name := filepath.Join(child, fmt.Sprintf("data-%d.bin", i))
		if err := os.WriteFile(name, []byte(strings.Repeat("x", 64)), 0o644); err != nil {
			t.Fatalf("write child data: %v", err)
		}
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	if _, err := scanPathConcurrent(context.Background(), root, &filesScanned, &dirsScanned, &bytesScanned, current); err != nil {
		t.Fatalf("scanPathConcurrent(root): %v", err)
	}

	cached, err := loadCacheFromDisk(child)
	if err != nil {
		t.Fatalf("expected warmed child cache, got error: %v", err)
	}
	if cached.TotalSize <= 0 {
		t.Fatalf("expected positive cached child size, got %d", cached.TotalSize)
	}
	if len(cached.Entries) == 0 {
		t.Fatalf("expected cached child entries to be populated")
	}
	if cached.TotalFiles != subdirCacheMinFiles {
		t.Fatalf("expected warmed child cache to track local file count %d, got %d", subdirCacheMinFiles, cached.TotalFiles)
	}
	if !cached.NeedsRefresh {
		t.Fatalf("expected warmed child cache to be marked for refresh")
	}
}

// A cache file costs a 4KB block plus an inode to memoize what one readdir
// returns, so cheap subtrees must not get one. Unbounded admission is what grew
// ~/.cache/mole to 1.88M files / 7.82GB on a user's Mac.
func TestScanPathConcurrentSkipsCacheForCheapSubdir(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}
	if err := os.WriteFile(filepath.Join(root, "root.txt"), []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root data: %v", err)
	}
	if err := os.WriteFile(filepath.Join(child, "data.bin"), []byte(strings.Repeat("x", 4096)), 0o644); err != nil {
		t.Fatalf("write child data: %v", err)
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	result, err := scanPathConcurrent(context.Background(), root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent(root): %v", err)
	}

	childPath, err := getCachePath(child)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	if _, err := os.Stat(childPath); !os.IsNotExist(err) {
		t.Fatalf("expected cheap subtree to be left uncached, stat err: %v", err)
	}

	// The size still has to be reported; only the persistence is skipped.
	found := false
	for _, entry := range result.Entries {
		if entry.Path == child {
			found = true
			if entry.Size <= 0 {
				t.Fatalf("expected uncached child to still report a size, got %d", entry.Size)
			}
		}
	}
	if !found {
		t.Fatalf("expected child entry in scan result")
	}
}

func TestAnalyzeIncludesParallelsVMStorageButKeepsOtherVirtualizationSkips(t *testing.T) {
	root := t.TempDir()
	parallels := filepath.Join(root, "Parallels")
	orbStack := filepath.Join(root, "OrbStack")
	for _, dir := range []string{parallels, orbStack} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("create %s: %v", dir, err)
		}
		if err := os.WriteFile(filepath.Join(dir, "disk.img"), []byte(strings.Repeat("x", 4096)), 0o644); err != nil {
			t.Fatalf("write data in %s: %v", dir, err)
		}
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")
	result, err := scanPathConcurrentWithOptions(context.Background(), root, &filesScanned, &dirsScanned, &bytesScanned, current, false, 0)
	if err != nil {
		t.Fatalf("scan root: %v", err)
	}

	foundParallels := false
	for _, entry := range result.Entries {
		switch entry.Path {
		case parallels:
			foundParallels = true
			if entry.Size <= 0 {
				t.Fatalf("expected Parallels to contribute a positive size, got %d", entry.Size)
			}
		case orbStack:
			t.Fatalf("expected existing OrbStack skip to remain in place")
		}
	}
	if !foundParallels {
		t.Fatalf("expected Parallels VM storage in scan entries")
	}
}

func TestLiveScanIncludesParallelsVMStorageButKeepsOtherVirtualizationSkips(t *testing.T) {
	root := t.TempDir()
	parallels := filepath.Join(root, "Parallels")
	orbStack := filepath.Join(root, "OrbStack")
	for _, dir := range []string{parallels, orbStack} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("create %s: %v", dir, err)
		}
	}

	initial, targets, err := readLiveScanInitialEntries(root, nil)
	entries := initial.Entries
	if err != nil {
		t.Fatalf("read live scan entries: %v", err)
	}

	foundParallelsEntry := false
	for _, entry := range entries {
		switch entry.Path {
		case parallels:
			foundParallelsEntry = true
		case orbStack:
			t.Fatalf("expected existing OrbStack skip to remain in live entries")
		}
	}
	foundParallelsTarget := false
	for _, target := range targets {
		switch target.path {
		case parallels:
			foundParallelsTarget = true
		case orbStack:
			t.Fatalf("expected existing OrbStack skip to remain in live targets")
		}
	}
	if !foundParallelsEntry || !foundParallelsTarget {
		t.Fatalf("expected Parallels in both live entries and targets, entry=%v target=%v", foundParallelsEntry, foundParallelsTarget)
	}
}

func TestShouldPersistSubdirCacheThresholds(t *testing.T) {
	cases := []struct {
		name   string
		result scanResult
		want   bool
	}{
		{"tiny subtree", scanResult{TotalFiles: 1, TotalSize: 4096}, false},
		{"just below file threshold", scanResult{TotalFiles: subdirCacheMinFiles - 1, TotalSize: 1024}, false},
		{"file threshold", scanResult{TotalFiles: subdirCacheMinFiles, TotalSize: 1024}, true},
		{"size threshold", scanResult{TotalFiles: 1, TotalSize: subdirCacheMinSize}, true},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			if got := shouldPersistSubdirCache(tc.result); got != tc.want {
				t.Fatalf("shouldPersistSubdirCache(%+v) = %v, want %v", tc.result, got, tc.want)
			}
		})
	}
}

func TestScanPathConcurrentUsesChildCacheLargeFiles(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	largeFile := filepath.Join(child, "large.bin")
	if err := os.WriteFile(largeFile, []byte(strings.Repeat("x", 2<<20)), 0o644); err != nil {
		t.Fatalf("write large file: %v", err)
	}

	var childFiles, childDirs, childBytes int64
	childCurrent := &atomic.Value{}
	childCurrent.Store("")
	childResult, err := scanPathConcurrent(context.Background(), child, &childFiles, &childDirs, &childBytes, childCurrent)
	if err != nil {
		t.Fatalf("scanPathConcurrent(child): %v", err)
	}
	if err := saveCacheToDisk(child, childResult); err != nil {
		t.Fatalf("saveCacheToDisk(child): %v", err)
	}

	if err := os.Chmod(child, 0o000); err != nil {
		t.Fatalf("chmod child unreadable: %v", err)
	}
	defer func() {
		_ = os.Chmod(child, 0o755)
	}()

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	result, err := scanPathConcurrent(context.Background(), root, &filesScanned, &dirsScanned, &bytesScanned, current)
	if err != nil {
		t.Fatalf("scanPathConcurrent(root): %v", err)
	}

	foundChild := false
	for _, entry := range result.Entries {
		if entry.Path == child {
			foundChild = true
			if entry.Size != childResult.TotalSize {
				t.Fatalf("cached child size mismatch: want %d, got %d", childResult.TotalSize, entry.Size)
			}
			break
		}
	}
	if !foundChild {
		t.Fatalf("expected cached child directory in root entries")
	}

	foundLargeFile := false
	for _, file := range result.LargeFiles {
		if file.Path == largeFile {
			foundLargeFile = true
			break
		}
	}
	if !foundLargeFile {
		t.Fatalf("expected root large files to include cached child large file")
	}
}

func TestScanPathConcurrentWarmsChildCachesWithoutRecursiveSpotlight(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	childOne := filepath.Join(root, "child-one")
	childTwo := filepath.Join(root, "child-two")
	for _, dir := range []string{childOne, childTwo} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("create dir %s: %v", dir, err)
		}
		if err := os.WriteFile(filepath.Join(dir, "data.bin"), []byte(strings.Repeat("x", 4096)), 0o644); err != nil {
			t.Fatalf("write data in %s: %v", dir, err)
		}
	}

	originalRunner := spotlightQueryRunner
	spotlightRoots := []string{}
	spotlightQueryRunner = func(_ context.Context, queryRoot, _ string) ([]byte, error) {
		spotlightRoots = append(spotlightRoots, queryRoot)
		return nil, nil
	}
	t.Cleanup(func() {
		spotlightQueryRunner = originalRunner
	})

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	if _, err := scanPathConcurrent(context.Background(), root, &filesScanned, &dirsScanned, &bytesScanned, current); err != nil {
		t.Fatalf("scanPathConcurrent(root): %v", err)
	}

	if len(spotlightRoots) != 1 || spotlightRoots[0] != root {
		t.Fatalf("expected only root spotlight invocation, got %q", spotlightRoots)
	}
}

func TestSpotlightConsumerStopsWhenScanIsCanceled(t *testing.T) {
	root := t.TempDir()
	file := filepath.Join(root, "large.bin")
	if err := os.WriteFile(file, []byte("large"), 0o644); err != nil {
		t.Fatalf("write spotlight result: %v", err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	originalRunner := spotlightQueryRunner
	spotlightQueryRunner = func(_ context.Context, _, _ string) ([]byte, error) {
		cancel()
		return []byte(strings.Repeat(file+"\n", 10_000)), nil
	}
	t.Cleanup(func() {
		spotlightQueryRunner = originalRunner
	})

	files, err := findLargeFilesWithSpotlight(ctx, root, 1)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected canceled Spotlight consumer, got %v", err)
	}
	if len(files) != 0 {
		t.Fatalf("canceled Spotlight consumer returned %d files", len(files))
	}
}

func TestScanCmdTreatsWarmedCacheAsStale(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{
		Entries:    []dirEntry{{Name: "child", Path: filepath.Join(target, "child"), Size: 1, IsDir: true}},
		LargeFiles: []fileEntry{{Name: "big.bin", Path: filepath.Join(target, "big.bin"), Size: 2 << 20}},
		TotalSize:  42,
		TotalFiles: 1,
	}
	ctx := context.Background()
	if err := saveCacheToDiskWithOptions(newScanPublication(ctx, nil), target, result, true); err != nil {
		t.Fatalf("saveCacheToDiskWithOptions: %v", err)
	}

	m := newModel(target, false)
	msg := m.scanCmd(target)()
	scanMsg, ok := msg.(scanResultMsg)
	if !ok {
		t.Fatalf("expected scanResultMsg, got %T", msg)
	}
	if !scanMsg.stale {
		t.Fatalf("expected warmed cache to trigger stale refresh path")
	}
	if scanMsg.result.TotalFiles != result.TotalFiles {
		t.Fatalf("expected cached result to survive stale load, got %d", scanMsg.result.TotalFiles)
	}
}

func TestCanceledCacheSaveDoesNotPublish(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	target := filepath.Join(home, "target")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	ctx, cancelContext := context.WithCancel(context.Background())
	publication := newScanPublication(ctx, cancelContext)
	publication.cancel()
	err := saveCacheToDiskWithOptions(publication, target, scanResult{TotalSize: 42, TotalFiles: 1}, true)
	if !errors.Is(err, context.Canceled) {
		t.Fatalf("expected canceled cache save, got %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("resolve cache path: %v", err)
	}
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("canceled cache save published %s", cachePath)
	}
}

func TestCanceledCacheMutationsDoNotPublish(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	target := filepath.Join(home, "target")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("resolve cache path: %v", err)
	}

	ctx, cancelContext := context.WithCancel(context.Background())
	publication := newScanPublication(ctx, cancelContext)
	publication.mu.Lock()
	saveDone := make(chan error, 1)
	go func() {
		saveDone <- saveCacheToDiskWithOptions(publication, target, scanResult{TotalSize: 42, TotalFiles: 1}, true)
	}()
	waitForTestCondition(t, "cache save to reach its temporary file", func() bool {
		matches, globErr := filepath.Glob(filepath.Join(filepath.Dir(cachePath), "entry-*.tmp"))
		return globErr == nil && len(matches) > 0
	})
	cancelDone := make(chan struct{})
	go func() {
		publication.cancel()
		close(cancelDone)
	}()
	waitForTestCondition(t, "cache-save cancellation to start", publication.canceling.Load)
	publication.mu.Unlock()

	if err := <-saveDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cache save to lose publication order, got %v", err)
	}
	<-cancelDone
	if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
		t.Fatalf("canceled cache save published %s", cachePath)
	}

	if err := saveCacheToDisk(target, scanResult{TotalSize: 84, TotalFiles: 2}); err != nil {
		t.Fatalf("seed cache entry: %v", err)
	}
	removeCtx, removeCancel := context.WithCancel(context.Background())
	removePublication := newScanPublication(removeCtx, removeCancel)
	removePublication.mu.Lock()
	removeDone := make(chan error, 1)
	go func() {
		removeDone <- removeCacheEntryForScan(removePublication, target)
	}()
	removeCancelDone := make(chan struct{})
	go func() {
		removePublication.cancel()
		close(removeCancelDone)
	}()
	waitForTestCondition(t, "cache-removal cancellation to start", removePublication.canceling.Load)
	removePublication.mu.Unlock()

	if err := <-removeDone; !errors.Is(err, context.Canceled) {
		t.Fatalf("expected cache removal to lose publication order, got %v", err)
	}
	<-removeCancelDone
	if _, err := os.Stat(cachePath); err != nil {
		t.Fatalf("canceled cache removal changed published state: %v", err)
	}
}

func TestLiveScanSortConfigFromEnv(t *testing.T) {
	t.Run("defaults to freeze on move", func(t *testing.T) {
		t.Setenv(liveSortModeEnv, "")

		m := newModel(t.TempDir(), false)
		if m.liveSortMode != liveSortFreezeOnMove {
			t.Fatalf("expected freeze-on-move sort mode, got %v", m.liveSortMode)
		}
	})

	t.Run("continuous remains available", func(t *testing.T) {
		t.Setenv(liveSortModeEnv, "continuous")

		m := newModel(t.TempDir(), false)
		if m.liveSortMode != liveSortContinuous {
			t.Fatalf("expected continuous sort mode, got %v", m.liveSortMode)
		}
	})
}

func TestLiveScanInitialListingShowsImmediateChildren(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}
	filePath := filepath.Join(root, "root.txt")
	if err := os.WriteFile(filePath, []byte("root-data"), 0o644); err != nil {
		t.Fatalf("write root file: %v", err)
	}

	m := newModel(root, false)
	msg := m.scanFreshCmd(root)()
	start, ok := msg.(liveScanStartMsg)
	if !ok {
		t.Fatalf("expected liveScanStartMsg, got %T", msg)
	}
	defer cancelAndDrainLiveScan(start)

	foundFile := false
	foundDir := false
	for _, entry := range start.entries {
		switch entry.Path {
		case filePath:
			foundFile = true
			if entry.Size <= 0 {
				t.Fatalf("expected file size to be known immediately, got %d", entry.Size)
			}
		case child:
			foundDir = true
			if entry.Size != -1 {
				t.Fatalf("expected child directory to start pending, got %d", entry.Size)
			}
		}
	}
	if !foundFile || !foundDir {
		t.Fatalf("expected immediate file and directory entries, got %+v", start.entries)
	}
}

func TestLiveScanCancellationStopsFoldedDirectoryProbe(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "folded")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatalf("create folded directory: %v", err)
	}

	started := installBlockingDuProbe(t)

	ctx, cancelContext := context.WithCancel(context.Background())
	publication := newScanPublication(ctx, cancelContext)
	defer publication.cancel()
	limiter := newScanLimiter(1)
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	done := make(chan error, 1)
	go func() {
		_, err := scanLiveTarget(
			ctx,
			liveScanTarget{name: "folded", path: target, kind: liveScanTargetFoldedDirectory},
			make(chan fileEntry, maxLargeFiles*2),
			limiter,
			&filesScanned,
			&dirsScanned,
			&bytesScanned,
			currentPath,
			scanCacheBypass,
			publication,
		)
		done <- err
	}()

	waitForTestPath(t, started)

	publication.cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected canceled scan, got %v", err)
		}
	case <-time.After(liveScanCancellationBudget):
		t.Fatal("folded-directory probe kept running after live scan cancellation")
	}
}

func TestLiveScanCancellationStopsNestedFoldedDirectoryProbe(t *testing.T) {
	root := t.TempDir()
	target := filepath.Join(root, "target")
	if err := os.MkdirAll(filepath.Join(target, ".git"), 0o755); err != nil {
		t.Fatalf("create nested folded directory: %v", err)
	}
	started := installBlockingDuProbe(t)

	ctx, cancelContext := context.WithCancel(context.Background())
	publication := newScanPublication(ctx, cancelContext)
	defer publication.cancel()
	limiter := newScanLimiter(1)
	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")

	done := make(chan error, 1)
	go func() {
		_, err := scanLiveTarget(
			ctx,
			liveScanTarget{name: "target", path: target, kind: liveScanTargetDirectory},
			make(chan fileEntry, maxLargeFiles*2),
			limiter,
			&filesScanned,
			&dirsScanned,
			&bytesScanned,
			currentPath,
			scanCacheBypass,
			publication,
		)
		done <- err
	}()

	waitForTestPath(t, started)
	publication.cancel()
	select {
	case err := <-done:
		if !errors.Is(err, context.Canceled) {
			t.Fatalf("expected canceled scan, got %v", err)
		}
	case <-time.After(liveScanCancellationBudget):
		t.Fatal("nested folded-directory probe kept running after live scan cancellation")
	}
}

func TestLiveScanEventStreamRejectsCompletionAfterCancellation(t *testing.T) {
	ctx, cancelContext := context.WithCancel(context.Background())
	stream := newLiveScanEventStream(newScanPublication(ctx, cancelContext), 1)

	stream.publishProgress(liveScanEventMsg{kind: liveScanChildProgress})
	stream.publishProgress(liveScanEventMsg{kind: liveScanChildProgress})
	stream.publish(liveScanEventMsg{kind: liveScanChildDone})

	canceled := make(chan struct{})
	go func() {
		stream.cancel()
		close(canceled)
	}()
	select {
	case <-canceled:
	case <-time.After(5 * time.Second):
		t.Fatal("cancel blocked behind queued live-scan events")
	}

	stream.publish(liveScanEventMsg{kind: liveScanComplete})
	stream.close()
	for event := range stream.events {
		if event.kind == liveScanComplete {
			t.Fatal("stream published completion after cancellation")
		}
	}
}

func TestLiveScanEventStreamReservesRequiredCapacity(t *testing.T) {
	ctx, cancelContext := context.WithCancel(context.Background())
	const targetCount = 3
	stream := newLiveScanEventStream(newScanPublication(ctx, cancelContext), targetCount)

	done := make(chan struct{})
	go func() {
		for range cap(stream.events) - stream.requiredSlots {
			stream.publishProgress(liveScanEventMsg{kind: liveScanChildProgress})
		}
		for range targetCount {
			stream.publish(liveScanEventMsg{kind: liveScanChildDone})
		}
		stream.publish(liveScanEventMsg{kind: liveScanComplete})
		stream.close()
		close(done)
	}()

	select {
	case <-done:
	case <-time.After(5 * time.Second):
		t.Fatal("required live-scan events exhausted their reserved capacity")
	}
	if !errors.Is(ctx.Err(), context.Canceled) {
		t.Fatalf("closed stream did not release its context: %v", ctx.Err())
	}

	var required int
	for event := range stream.events {
		if event.kind != liveScanChildProgress {
			required++
		}
	}
	if required != targetCount+1 {
		t.Fatalf("got %d required events, want %d", required, targetCount+1)
	}
}

func TestCanceledLiveScanPublishesNoResultsOrCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	project := filepath.Join(root, "project")
	if err := os.MkdirAll(filepath.Join(project, "node_modules"), 0o755); err != nil {
		t.Fatalf("create folded subtree: %v", err)
	}
	for i := range subdirCacheMinFiles {
		path := filepath.Join(project, fmt.Sprintf("file-%03d.bin", i))
		if err := os.WriteFile(path, []byte("cacheable"), 0o644); err != nil {
			t.Fatalf("write cacheable file: %v", err)
		}
	}
	started := installBlockingDuProbe(t)

	var filesScanned, dirsScanned, bytesScanned int64
	currentPath := &atomic.Value{}
	currentPath.Store("")
	start, ok := startLiveScanCmd(root, &filesScanned, &dirsScanned, &bytesScanned, currentPath)().(liveScanStartMsg)
	if !ok {
		t.Fatal("expected live scan start message")
	}

	waitForTestPath(t, started)
	start.cancel()

	deadline := time.NewTimer(liveScanCancellationBudget)
	defer deadline.Stop()
	for {
		select {
		case event, open := <-start.events:
			if !open {
				cachePath, err := getCachePath(project)
				if err != nil {
					t.Fatalf("resolve project cache path: %v", err)
				}
				if _, err := os.Stat(cachePath); !os.IsNotExist(err) {
					t.Fatalf("canceled scan persisted partial cache at %s", cachePath)
				}
				return
			}
			switch event.kind {
			case liveScanChildDone, liveScanComplete:
				t.Fatalf("canceled scan published stale event kind %v", event.kind)
			}
		case <-deadline.C:
			t.Fatal("canceled live scan did not close promptly")
		}
	}
}

func TestLiveScanStartDoesNotAddSecondSpinnerTick(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	m := newModel(root, false)
	start := m.scanFreshCmd(root)().(liveScanStartMsg)
	defer cancelAndDrainLiveScan(start)

	_, cmd := m.Update(start)
	if cmd == nil {
		t.Fatalf("expected live scan start to wait for scan events")
	}
	if _, ok := cmd().(tickMsg); ok {
		t.Fatalf("live scan start must not schedule an extra spinner tick")
	}
}

func TestOverviewHomeNavigationRendersImmediateRows(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	downloads := filepath.Join(home, "Downloads")
	desktop := filepath.Join(home, "Desktop")
	for _, dir := range []string{downloads, desktop} {
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("create %s: %v", dir, err)
		}
	}
	if err := os.WriteFile(filepath.Join(home, "note.txt"), []byte("home-note"), 0o644); err != nil {
		t.Fatalf("write home file: %v", err)
	}

	m := newModel("/", true)
	for i, entry := range m.entries {
		if entry.Path == home {
			m.selected = i
			break
		}
	}

	updated, cmd := m.enterSelectedDir()
	if cmd == nil {
		t.Fatalf("expected Home navigation to start a scan")
	}
	got := updated.(model)
	if got.path != home {
		t.Fatalf("expected path %s, got %s", home, got.path)
	}

	msg := cmd()
	batch, ok := msg.(tea.BatchMsg)
	if !ok {
		t.Fatalf("expected navigation command batch, got %T", msg)
	}
	var start liveScanStartMsg
	for _, batchCmd := range batch {
		if batchCmd == nil {
			continue
		}
		if candidate, ok := batchCmd().(liveScanStartMsg); ok {
			start = candidate
			break
		}
	}
	if start.events == nil {
		t.Fatalf("expected batch to include live scan start")
	}
	defer cancelAndDrainLiveScan(start)

	updated, _ = got.Update(start)
	got = updated.(model)
	view := got.View()
	for _, want := range []string{"Downloads", "Desktop", "note.txt"} {
		if !strings.Contains(view, want) {
			t.Fatalf("expected Home view to contain %q, got:\n%s", want, view)
		}
	}
}

func TestLiveScanChildUpdateUpdatesRowTotalAndCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}
	if err := os.WriteFile(filepath.Join(child, "data.bin"), []byte(strings.Repeat("x", 4096)), 0o644); err != nil {
		t.Fatalf("write child file: %v", err)
	}

	m := newModel(root, false)
	start := m.scanFreshCmd(root)().(liveScanStartMsg)
	defer cancelAndDrainLiveScan(start)

	updated, _ := m.Update(start)
	liveModel := updated.(model)

	deadline := time.After(5 * time.Second)
	for {
		select {
		case event := <-start.events:
			if event.kind != liveScanChildDone {
				continue
			}
			updated, _ = liveModel.Update(event)
			liveModel = updated.(model)

			var found dirEntry
			for _, entry := range liveModel.entries {
				if entry.Path == child {
					found = entry
					break
				}
			}
			if found.Path == "" {
				t.Fatalf("expected child row to remain visible")
			}
			if found.Size <= 0 {
				t.Fatalf("expected child row size to update, got %d", found.Size)
			}
			if liveModel.totalSize != found.Size {
				t.Fatalf("expected total size %d, got %d", found.Size, liveModel.totalSize)
			}
			cached, ok := liveModel.cache[child]
			if !ok {
				t.Fatalf("expected child result to warm in-memory cache")
			}
			if cached.TotalSize != found.Size {
				t.Fatalf("cached child size mismatch: want %d, got %d", found.Size, cached.TotalSize)
			}
			return
		case <-deadline:
			t.Fatalf("timed out waiting for child update")
		}
	}
}

func TestManualRefreshBypassesNestedSubdirCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	nested := filepath.Join(root, "a", "b")
	if err := os.MkdirAll(nested, 0o755); err != nil {
		t.Fatalf("create nested directory: %v", err)
	}
	for i := range subdirCacheMinFiles {
		path := filepath.Join(nested, fmt.Sprintf("data-%d.bin", i))
		if err := os.WriteFile(path, []byte(strings.Repeat("x", 64)), 0o644); err != nil {
			t.Fatalf("write nested data: %v", err)
		}
	}
	removedPath := filepath.Join(nested, "removed.bin")
	if err := os.WriteFile(removedPath, []byte(strings.Repeat("x", 2*1024*1024)), 0o644); err != nil {
		t.Fatalf("write removable data: %v", err)
	}

	m := newModel(root, false)
	warmed := runScanResultCmd(t, m.scanFreshCmd(root))
	if warmed.err != nil {
		t.Fatalf("warm scan: %v", warmed.err)
	}
	if _, err := loadCacheFromDisk(nested); err != nil {
		t.Fatalf("expected nested cache to be warmed: %v", err)
	}

	if err := os.Remove(removedPath); err != nil {
		t.Fatalf("remove nested data: %v", err)
	}

	reused := runScanResultCmd(t, m.scanFreshCmd(root))
	if reused.err != nil {
		t.Fatalf("cached scan: %v", reused.err)
	}
	if reused.result.TotalSize != warmed.result.TotalSize {
		t.Fatalf("expected ordinary scan to reuse nested cache size %d, got %d", warmed.result.TotalSize, reused.result.TotalSize)
	}

	updated, cmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'R'}})
	if cmd == nil {
		t.Fatalf("expected manual refresh command")
	}
	if !updated.(model).scanning {
		t.Fatalf("expected manual refresh to enter scanning state")
	}
	refreshed := runScanResultCmd(t, cmd)
	if refreshed.err != nil {
		t.Fatalf("manual refresh: %v", refreshed.err)
	}
	if refreshed.result.TotalSize >= warmed.result.TotalSize {
		t.Fatalf("expected manual refresh to drop removed file size below %d, got %d", warmed.result.TotalSize, refreshed.result.TotalSize)
	}

	cached, err := loadCacheFromDisk(nested)
	if err != nil {
		t.Fatalf("load refreshed nested cache: %v", err)
	}
	for _, entry := range cached.Entries {
		if entry.Path == removedPath {
			t.Fatalf("manual refresh left removed file in nested cache")
		}
	}
}

func TestCacheBypassSkipsHomeLibraryOverviewSnapshot(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	library := filepath.Join(home, "Library")
	if err := os.MkdirAll(library, 0o755); err != nil {
		t.Fatalf("create Library: %v", err)
	}
	if err := os.WriteFile(filepath.Join(library, "live.bin"), []byte(strings.Repeat("x", 8192)), 0o644); err != nil {
		t.Fatalf("write Library data: %v", err)
	}
	if err := storeOverviewSize(library, 1); err != nil {
		t.Fatalf("store stale overview size: %v", err)
	}

	scanTarget := func(policy scanCachePolicy) scanResult {
		t.Helper()
		ctx := context.Background()
		var filesScanned, dirsScanned, bytesScanned int64
		current := &atomic.Value{}
		current.Store("")
		limiter := newScanLimiter(1)
		result, err := scanLiveTarget(
			ctx,
			liveScanTarget{name: "Library", path: library, kind: liveScanTargetHomeLibrary},
			make(chan fileEntry, maxLargeFiles*2),
			limiter,
			&filesScanned,
			&dirsScanned,
			&bytesScanned,
			current,
			policy,
			newScanPublication(ctx, nil),
		)
		if err != nil {
			t.Fatalf("scan Home Library: %v", err)
		}
		return result
	}

	if got := scanTarget(scanCacheReuse).TotalSize; got != 1 {
		t.Fatalf("expected reuse policy to return snapshot size 1, got %d", got)
	}
	if got := scanTarget(scanCacheBypass).TotalSize; got <= 1 {
		t.Fatalf("expected bypass policy to scan live Library size, got %d", got)
	}

	scanHome := func(policy scanCachePolicy) int64 {
		t.Helper()
		ctx := context.Background()
		var filesScanned, dirsScanned, bytesScanned int64
		current := &atomic.Value{}
		current.Store("")
		result, err := scanPathConcurrentWithLimiter(ctx, home, &filesScanned, &dirsScanned, &bytesScanned, current, false, maxEntries, nil, policy, newScanPublication(ctx, nil))
		if err != nil {
			t.Fatalf("scan Home: %v", err)
		}
		for _, entry := range result.Entries {
			if entry.Path == library {
				return entry.Size
			}
		}
		t.Fatalf("Library entry missing from Home scan")
		return 0
	}

	if got := scanHome(scanCacheReuse); got != 1 {
		t.Fatalf("expected concurrent reuse policy to return snapshot size 1, got %d", got)
	}
	if got := scanHome(scanCacheBypass); got <= 1 {
		t.Fatalf("expected concurrent bypass policy to scan live Library size, got %d", got)
	}
}

func TestLiveScanStartPreservesEntryFilterBackingList(t *testing.T) {
	root := t.TempDir()
	apps := filepath.Join(root, "apps")
	logs := filepath.Join(root, "logs")

	m := newModel(root, false)
	m.entryFilter = "app"
	start := liveScanStartMsg{
		id:   1,
		path: root,
		entries: []dirEntry{
			{Name: "apps", Path: apps, Size: -1, IsDir: true},
			{Name: "logs", Path: logs, Size: -1, IsDir: true},
		},
		events: make(chan liveScanEventMsg),
		cancel: func() {},
	}

	updated, _ := m.Update(start)
	got := updated.(model)
	if len(got.entriesAll) != 2 {
		t.Fatalf("expected backing list to keep both live entries, got %+v", got.entriesAll)
	}
	if len(got.entries) != 1 || got.entries[0].Path != apps {
		t.Fatalf("expected active filter to render only apps, got %+v", got.entries)
	}
}

func TestLiveScanIgnoresStaleEventsAfterNavigation(t *testing.T) {
	root := t.TempDir()
	other := t.TempDir()

	m := newModel(other, false)
	m.liveScanID = 2
	m.liveScanEvents = make(chan liveScanEventMsg)
	m.entries = []dirEntry{{Name: "current", Path: filepath.Join(other, "current"), Size: 1}}
	m.totalSize = 1

	stale := liveScanEventMsg{
		id:   1,
		path: root,
		kind: liveScanChildDone,
		entry: dirEntry{
			Name:  "stale",
			Path:  filepath.Join(root, "stale"),
			Size:  99,
			IsDir: true,
		},
		result: scanResult{TotalSize: 99},
	}

	updated, _ := m.Update(stale)
	got := updated.(model)
	if got.totalSize != 1 || len(got.entries) != 1 || got.entries[0].Name != "current" {
		t.Fatalf("stale event changed model: %+v", got)
	}
}

func TestLiveScanDefaultCursorStaysOnFirstRowAcrossReorder(t *testing.T) {
	root := t.TempDir()
	a := filepath.Join(root, "a")
	b := filepath.Join(root, "b")

	m := newModel(root, false)
	m.liveScanID = 1
	m.liveScanEvents = make(chan liveScanEventMsg)
	m.scanning = true
	m.autoSortLiveEntries = true
	m.liveScanningPaths = map[string]bool{a: true, b: true}
	m.entries = []dirEntry{
		{Name: "a", Path: a, Size: -1, IsDir: true},
		{Name: "b", Path: b, Size: -1, IsDir: true},
	}
	m.entriesAll = slices.Clone(m.entries)

	updated, _ := m.Update(liveScanEventMsg{
		id:     1,
		path:   root,
		kind:   liveScanChildDone,
		entry:  dirEntry{Name: "b", Path: b, Size: 10, IsDir: true},
		result: scanResult{TotalSize: 10},
	})
	m = updated.(model)
	if got := []string{m.entries[0].Path, m.entries[1].Path}; !slices.Equal(got, []string{b, a}) {
		t.Fatalf("expected live sort to reorder by size, got %v", got)
	}
	if m.selected != 0 || m.entries[m.selected].Path != b {
		t.Fatalf("expected default cursor to stay on the first row, selected=%d entries=%+v", m.selected, m.entries)
	}

	updated, _ = m.enterSelectedDir()
	got := updated.(model)
	if got.path != b {
		t.Fatalf("expected Enter to drill into first-row path %s, got %s", b, got.path)
	}
}

func TestLiveScanProgressUpdatesRowBarAndPercent(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "child")
	sibling := filepath.Join(root, "sibling.bin")

	m := newModel(root, false)
	m.liveScanID = 1
	m.liveScanEvents = make(chan liveScanEventMsg)
	m.scanning = true
	m.autoSortLiveEntries = false
	m.liveScanningPaths = map[string]bool{child: true}
	m.entries = []dirEntry{
		{Name: "child", Path: child, Size: -1, IsDir: true},
		{Name: "sibling.bin", Path: sibling, Size: 100},
	}
	m.totalSize = 100

	updated, _ := m.Update(liveScanEventMsg{
		id:    1,
		path:  root,
		kind:  liveScanChildProgress,
		entry: dirEntry{Name: "child", Path: child, Size: 10, IsDir: true},
	})
	m = updated.(model)
	firstRow := rowContaining(m.View(), "child")
	firstFill := progressFillCount(firstRow)
	if !strings.Contains(firstRow, "9.1%") {
		t.Fatalf("expected first progress row to show 9.1%%, got:\n%s", firstRow)
	}

	updated, _ = m.Update(liveScanEventMsg{
		id:    1,
		path:  root,
		kind:  liveScanChildProgress,
		entry: dirEntry{Name: "child", Path: child, Size: 50, IsDir: true},
	})
	m = updated.(model)
	secondRow := rowContaining(m.View(), "child")
	secondFill := progressFillCount(secondRow)
	if !strings.Contains(secondRow, "33.3%") {
		t.Fatalf("expected second progress row to show 33.3%%, got:\n%s", secondRow)
	}
	if secondFill <= firstFill {
		t.Fatalf("expected child progress bar fill to increase, first=%d second=%d\nfirst: %s\nsecond: %s", firstFill, secondFill, firstRow, secondRow)
	}
	if m.totalSize != 150 {
		t.Fatalf("expected total known size to grow to 150, got %d", m.totalSize)
	}
	if _, ok := m.cache[child]; ok {
		t.Fatalf("progress event must not warm child cache before completion")
	}
	if !m.liveScanningPaths[child] {
		t.Fatalf("progress event must keep child marked as scanning")
	}
}

func TestLiveScanContinuousSortKeepsCursorByPath(t *testing.T) {
	root := t.TempDir()
	a := filepath.Join(root, "a")
	b := filepath.Join(root, "b")

	m := newModel(root, false)
	m.liveScanID = 1
	m.liveScanEvents = make(chan liveScanEventMsg)
	m.scanning = true
	m.autoSortLiveEntries = true
	m.liveSortMode = liveSortContinuous
	m.liveScanningPaths = map[string]bool{a: true, b: true}
	m.entries = []dirEntry{
		{Name: "a", Path: a, Size: -1, IsDir: true},
		{Name: "b", Path: b, Size: -1, IsDir: true},
	}

	updated, _ := m.Update(liveScanEventMsg{
		id:     1,
		path:   root,
		kind:   liveScanChildDone,
		entry:  dirEntry{Name: "b", Path: b, Size: 10, IsDir: true},
		result: scanResult{TotalSize: 10},
	})
	m = updated.(model)
	updated, _ = m.updateKey(tea.KeyMsg{Type: tea.KeyDown})
	m = updated.(model)
	if m.entries[m.selected].Path != a {
		t.Fatalf("expected selection to move to a before reorder, got selected=%d entries=%+v", m.selected, m.entries)
	}

	updated, _ = m.Update(liveScanEventMsg{
		id:     1,
		path:   root,
		kind:   liveScanChildDone,
		entry:  dirEntry{Name: "a", Path: a, Size: 100, IsDir: true},
		result: scanResult{TotalSize: 100},
	})
	m = updated.(model)
	if got := []string{m.entries[0].Path, m.entries[1].Path}; !slices.Equal(got, []string{a, b}) {
		t.Fatalf("expected live sort to continue after navigation, got %v", got)
	}
	if m.entries[m.selected].Path != a {
		t.Fatalf("expected cursor-by-path to stay on %s after reorder, selected=%d entries=%+v", a, m.selected, m.entries)
	}
}

func TestLiveScanSortCanFreezeAfterNavigationKey(t *testing.T) {
	root := t.TempDir()
	a := filepath.Join(root, "a")
	b := filepath.Join(root, "b")

	m := newModel(root, false)
	m.liveScanID = 1
	m.liveScanEvents = make(chan liveScanEventMsg)
	m.scanning = true
	m.autoSortLiveEntries = true
	m.liveSortMode = liveSortFreezeOnMove
	m.liveScanningPaths = map[string]bool{a: true, b: true}
	m.entries = []dirEntry{
		{Name: "a", Path: a, Size: -1, IsDir: true},
		{Name: "b", Path: b, Size: -1, IsDir: true},
	}

	updated, _ := m.Update(liveScanEventMsg{
		id:     1,
		path:   root,
		kind:   liveScanChildDone,
		entry:  dirEntry{Name: "b", Path: b, Size: 10, IsDir: true},
		result: scanResult{TotalSize: 10},
	})
	m = updated.(model)
	updated, _ = m.updateKey(tea.KeyMsg{Type: tea.KeyDown})
	m = updated.(model)
	if m.autoSortLiveEntries {
		t.Fatalf("expected freeze-on-move to disable live sort")
	}
	before := []string{m.entries[0].Path, m.entries[1].Path}

	updated, _ = m.Update(liveScanEventMsg{
		id:     1,
		path:   root,
		kind:   liveScanChildDone,
		entry:  dirEntry{Name: "a", Path: a, Size: 100, IsDir: true},
		result: scanResult{TotalSize: 100},
	})
	m = updated.(model)
	after := []string{m.entries[0].Path, m.entries[1].Path}
	if !slices.Equal(before, after) {
		t.Fatalf("expected freeze-on-move to keep row order %v, got %v", before, after)
	}
}

func TestLiveScanSortDoesNotFreezeWhenCursorCannotMove(t *testing.T) {
	root := t.TempDir()

	m := newModel(root, false)
	m.scanning = true
	m.autoSortLiveEntries = true
	m.liveSortMode = liveSortFreezeOnMove
	m.entries = []dirEntry{
		{Name: "only", Path: filepath.Join(root, "only"), Size: 10, IsDir: true},
	}

	updated, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyUp})
	m = updated.(model)
	if !m.autoSortLiveEntries {
		t.Fatal("an up key at the first row must not freeze live sorting")
	}

	updated, _ = m.updateKey(tea.KeyMsg{Type: tea.KeyDown})
	m = updated.(model)
	if !m.autoSortLiveEntries {
		t.Fatal("a down key with no next row must not freeze live sorting")
	}
}

func TestScanningViewRendersRowsWithSpinner(t *testing.T) {
	m := model{
		path:      "/tmp/project",
		scanning:  true,
		spinner:   1,
		totalSize: 8,
		entries: []dirEntry{
			{Name: "child", Path: "/tmp/project/child", Size: -1, IsDir: true},
			{Name: "file.txt", Path: "/tmp/project/file.txt", Size: 8},
		},
		liveScanningPaths: map[string]bool{"/tmp/project/child": true},
	}

	view := m.View()
	if !strings.Contains(view, "child") || !strings.Contains(view, "file.txt") {
		t.Fatalf("expected scanning view to render rows, got:\n%s", view)
	}
	if !strings.Contains(view, spinnerFrames[m.spinner]+" scanning") {
		t.Fatalf("expected pending directory spinner in row, got:\n%s", view)
	}
}

func TestScanningViewShowsSpinnerDividerForPartiallySizedFolders(t *testing.T) {
	m := model{
		path:      "/tmp/project",
		scanning:  true,
		spinner:   1,
		totalSize: 150,
		entries: []dirEntry{
			{Name: "child", Path: "/tmp/project/child", Size: 50, IsDir: true},
			{Name: "file.txt", Path: "/tmp/project/file.txt", Size: 100},
		},
		liveScanningPaths: map[string]bool{"/tmp/project/child": true},
	}

	view := m.View()
	childRow := rowContaining(view, "child")
	fileRow := rowContaining(view, "file.txt")
	if !strings.Contains(childRow, spinnerFrames[m.spinner]) {
		t.Fatalf("expected active child row divider to show spinner, got:\n%s", childRow)
	}
	if strings.Contains(fileRow, spinnerFrames[m.spinner]) {
		t.Fatalf("expected non-scanning file row to keep static divider, got:\n%s", fileRow)
	}
}

func TestEnterSelectedDirMarksScanningParentForRefresh(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	cancelled := false
	m := newModel(root, false)
	m.entries = []dirEntry{{Name: "child", Path: child, Size: -1, IsDir: true}}
	m.scanning = true
	m.liveScanID = 1
	m.liveScanCancel = func() { cancelled = true }

	updated, cmd := m.enterSelectedDir()
	if cmd == nil {
		t.Fatalf("expected child navigation to start a scan")
	}
	got := updated.(model)
	if !cancelled {
		t.Fatalf("expected active parent scan to be cancelled")
	}
	if len(got.history) != 1 || !got.history[0].NeedsRefresh {
		t.Fatalf("expected scanning parent history to be marked for refresh, got %+v", got.history)
	}
}

func TestEnterSelectedDirRefreshesStaleInMemoryCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	parent := filepath.Join(home, "parent")
	child := filepath.Join(parent, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	freshPath := filepath.Join(child, "fresh.bin")
	if err := os.WriteFile(freshPath, []byte("fresh-data"), 0o644); err != nil {
		t.Fatalf("write fresh file: %v", err)
	}
	freshInfo, err := os.Stat(freshPath)
	if err != nil {
		t.Fatalf("stat fresh file: %v", err)
	}
	freshSize := getActualFileSize(freshPath, freshInfo)

	warmed := scanResult{
		Entries:    []dirEntry{{Name: "stale.bin", Path: filepath.Join(child, "stale.bin"), Size: 1}},
		TotalSize:  1,
		TotalFiles: 1,
	}
	ctx := context.Background()
	if err := saveCacheToDiskWithOptions(newScanPublication(ctx, nil), child, warmed, true); err != nil {
		t.Fatalf("saveCacheToDiskWithOptions: %v", err)
	}

	m := newModel(parent, false)
	m.entries = []dirEntry{{Name: "child", Path: child, Size: 9, IsDir: true}}
	m.cache[child] = historyEntry{
		Path:         child,
		Entries:      []dirEntry{{Name: "stale.bin", Path: filepath.Join(child, "stale.bin"), Size: 1}},
		TotalSize:    1,
		TotalFiles:   1,
		NeedsRefresh: true,
	}

	updated, cmd := m.enterSelectedDir()
	if cmd == nil {
		t.Fatalf("expected stale in-memory child cache to trigger a refresh")
	}

	got := updated.(model)
	if got.path != child {
		t.Fatalf("expected path %s, got %s", child, got.path)
	}
	if !got.scanning {
		t.Fatalf("expected directory to remain scanning while refreshing stale cache")
	}
	if got.totalSize != 1 {
		t.Fatalf("expected stale cache contents to be shown immediately, got %d", got.totalSize)
	}

	scanMsg := runScanResultCmd(t, cmd)
	if scanMsg.stale {
		t.Fatalf("expected stale cached navigation to force a fresh scan")
	}
	if scanMsg.result.TotalSize != freshSize {
		t.Fatalf("expected fresh rescan total size %d, got %d", freshSize, scanMsg.result.TotalSize)
	}
	if scanMsg.result.Entries[0].Name != "fresh.bin" {
		t.Fatalf("expected rescan to surface live filesystem contents, got %+v", scanMsg.result.Entries)
	}
}

func TestGoBackRefreshesHistoryEntryNeedingRefresh(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	child := filepath.Join(home, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	freshPath := filepath.Join(child, "fresh.bin")
	if err := os.WriteFile(freshPath, []byte("fresh-data-2"), 0o644); err != nil {
		t.Fatalf("write fresh file: %v", err)
	}
	freshInfo, err := os.Stat(freshPath)
	if err != nil {
		t.Fatalf("stat fresh file: %v", err)
	}
	freshSize := getActualFileSize(freshPath, freshInfo)

	warmed := scanResult{
		Entries:    []dirEntry{{Name: "stale.bin", Path: filepath.Join(child, "stale.bin"), Size: 2}},
		TotalSize:  2,
		TotalFiles: 1,
	}
	ctx := context.Background()
	if err := saveCacheToDiskWithOptions(newScanPublication(ctx, nil), child, warmed, true); err != nil {
		t.Fatalf("saveCacheToDiskWithOptions: %v", err)
	}

	m := newModel(filepath.Join(child, "grandchild"), false)
	m.history = []historyEntry{{
		Path:         child,
		Entries:      []dirEntry{{Name: "stale.bin", Path: filepath.Join(child, "stale.bin"), Size: 2}},
		TotalSize:    2,
		TotalFiles:   1,
		NeedsRefresh: true,
	}}

	updated, cmd := m.goBack()
	if cmd == nil {
		t.Fatalf("expected stale history entry to trigger a refresh")
	}

	got := updated.(model)
	if got.path != child {
		t.Fatalf("expected path %s after goBack, got %s", child, got.path)
	}
	if !got.scanning {
		t.Fatalf("expected goBack to keep scanning while refreshing stale history entry")
	}
	if got.totalSize != 2 {
		t.Fatalf("expected stale history snapshot to be restored immediately, got %d", got.totalSize)
	}

	scanMsg := runScanResultCmd(t, cmd)
	if scanMsg.stale {
		t.Fatalf("expected stale history navigation to force a fresh scan")
	}
	if scanMsg.result.TotalSize != freshSize {
		t.Fatalf("expected fresh rescan total size %d, got %d", freshSize, scanMsg.result.TotalSize)
	}
	if scanMsg.result.Entries[0].Name != "fresh.bin" {
		t.Fatalf("expected rescan to surface live filesystem contents, got %+v", scanMsg.result.Entries)
	}
}

func TestScanPathConcurrentWarmsChildCacheWithLiveProgress(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatalf("create child: %v", err)
	}

	const dirCount = 32
	const filesPerDir = 256
	for i := range dirCount {
		dir := filepath.Join(child, fmt.Sprintf("dir-%02d", i))
		if err := os.MkdirAll(dir, 0o755); err != nil {
			t.Fatalf("create nested dir %s: %v", dir, err)
		}
		for j := range filesPerDir {
			file := filepath.Join(dir, fmt.Sprintf("file-%03d.bin", j))
			if err := os.WriteFile(file, []byte("x"), 0o644); err != nil {
				t.Fatalf("write %s: %v", file, err)
			}
		}
	}

	var filesScanned, dirsScanned, bytesScanned int64
	current := &atomic.Value{}
	current.Store("")

	done := make(chan struct{})
	errCh := make(chan error, 1)
	go func() {
		_, err := scanPathConcurrent(context.Background(), root, &filesScanned, &dirsScanned, &bytesScanned, current)
		errCh <- err
		close(done)
	}()

	deadline := time.Now().Add(5 * time.Second)
	sawLiveProgress := false
	for time.Now().Before(deadline) {
		if atomic.LoadInt64(&filesScanned) > 0 {
			select {
			case <-done:
			default:
				sawLiveProgress = true
			}
			if sawLiveProgress {
				break
			}
		}
		select {
		case <-done:
			if !sawLiveProgress {
				t.Fatalf("expected live progress before child warm scan completed, final files=%d", atomic.LoadInt64(&filesScanned))
			}
		default:
		}
		time.Sleep(2 * time.Millisecond)
	}

	if !sawLiveProgress {
		t.Fatalf("expected filesScanned to advance before warm child scan finished")
	}

	select {
	case err := <-errCh:
		if err != nil {
			t.Fatalf("scanPathConcurrent(root): %v", err)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("scan did not complete")
	}
}

func TestMeasureOverviewSize(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	resetOverviewSnapshotForTest()
	t.Cleanup(resetOverviewSnapshotForTest)

	target := filepath.Join(home, "measure")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}
	content := []byte(strings.Repeat("x", 4096))
	if err := os.WriteFile(filepath.Join(target, "data.bin"), content, 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}

	size, err := measureOverviewSize(context.Background(), target)
	if err != nil {
		t.Fatalf("measureOverviewSize: %v", err)
	}
	if size <= 0 {
		t.Fatalf("expected positive size, got %d", size)
	}

	// Ensure snapshot stored.
	cached, err := loadStoredOverviewSize(target)
	if err != nil {
		t.Fatalf("loadStoredOverviewSize: %v", err)
	}
	if cached != size {
		t.Fatalf("snapshot mismatch: want %d, got %d", size, cached)
	}

	// Ensure measureOverviewSize does not use cache
	// APFS block size is 4KB, 4097 bytes should use more blocks
	content = []byte(strings.Repeat("x", 4097))
	if err := os.WriteFile(filepath.Join(target, "data2.bin"), content, 0o644); err != nil {
		t.Fatalf("write file: %v", err)
	}
	size2, err := measureOverviewSize(context.Background(), target)
	if err != nil {
		t.Fatalf("measureOverviewSize: %v", err)
	}
	if size2 == size {
		t.Fatalf("measureOverwiewSize used cache")
	}
}

func TestIsHandledByMoClean(t *testing.T) {
	tests := []struct {
		name string
		path string
		want bool
	}{
		// Paths mo clean handles.
		{"user caches", "/Users/test/Library/Caches/com.example", true},
		{"user logs", "/Users/test/Library/Logs/DiagnosticReports", true},
		{"saved app state", "/Users/test/Library/Saved Application State/com.example", true},
		{"user trash", "/Users/test/.Trash/deleted-file", true},
		{"diagnostic reports", "/Users/test/Library/DiagnosticReports/crash.log", true},

		// Paths mo clean does NOT handle.
		{"project node_modules", "/Users/test/project/node_modules", false},
		{"project build", "/Users/test/project/build", false},
		{"home directory", "/Users/test", false},
		{"random path", "/some/random/path", false},
		{"empty string", "", false},

		// Partial matches should not trigger (case sensitive).
		{"lowercase caches", "/users/test/library/caches/foo", false},
		{"different trash path", "/Users/test/Trash/file", false}, // Missing dot prefix
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isHandledByMoClean(tt.path)
			if got != tt.want {
				t.Errorf("isHandledByMoClean(%q) = %v, want %v", tt.path, got, tt.want)
			}
		})
	}
}

func TestIsCleanableDir(t *testing.T) {
	tests := []struct {
		name string
		path string
		want bool
	}{
		// Empty path.
		{"empty string", "", false},

		// Project dependencies (should be cleanable).
		{"node_modules", "/Users/test/project/node_modules", true},
		{"nested node_modules", "/Users/test/project/packages/app/node_modules", true},
		{"venv", "/Users/test/project/venv", true},
		{"dot venv", "/Users/test/project/.venv", true},
		{"pycache", "/Users/test/project/src/__pycache__", true},
		{"build dir", "/Users/test/project/build", true},
		{"dist dir", "/Users/test/project/dist", true},
		{"target dir", "/Users/test/project/target", true},
		{"next.js cache", "/Users/test/project/.next", true},
		{"DerivedData", "/Users/test/Library/Developer/Xcode/DerivedData", true},
		{"Pods", "/Users/test/project/ios/Pods", true},
		{"gradle cache", "/Users/test/project/.gradle", true},
		{"coverage", "/Users/test/project/coverage", true},
		{"terraform", "/Users/test/infra/.terraform", true},

		// Paths handled by mo clean (should NOT be cleanable).
		{"user caches", "/Users/test/Library/Caches/com.example", false},
		{"user logs", "/Users/test/Library/Logs/app.log", false},
		{"trash", "/Users/test/.Trash/deleted", false},

		// Not in projectDependencyDirs.
		{"src dir", "/Users/test/project/src", false},
		{"random dir", "/Users/test/project/random", false},
		{"home dir", "/Users/test", false},
		{".git dir", "/Users/test/project/.git", false},

		// Edge cases.
		{"just basename node_modules", "node_modules", true},
		{"root path", "/", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isCleanableDir(tt.path)
			if got != tt.want {
				t.Errorf("isCleanableDir(%q) = %v, want %v", tt.path, got, tt.want)
			}
		})
	}
}

func TestLoadCacheExpiresWhenDirectoryChanges(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "change-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 5}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	// Advance mtime beyond grace period.
	time.Sleep(time.Millisecond * 10)
	if err := os.Chtimes(target, time.Now(), time.Now()); err != nil {
		t.Fatalf("chtimes: %v", err)
	}

	// Simulate older cache entry to exceed grace window.
	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	if _, err := os.Stat(cachePath); err != nil {
		t.Fatalf("stat cache: %v", err)
	}
	oldTime := time.Now().Add(-cacheModTimeGrace - time.Minute)
	if err := os.Chtimes(cachePath, oldTime, oldTime); err != nil {
		t.Fatalf("chtimes cache: %v", err)
	}

	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	entry.ScanTime = time.Now().Add(-8 * 24 * time.Hour)

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected cache load to fail after stale scan time")
	}
}

func TestLoadCacheReusesRecentEntryAfterDirectoryChanges(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "recent-change-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 5, TotalFiles: 1}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}

	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	// Make cache entry look recently scanned, but older than mod time grace.
	entry.ModTime = time.Now().Add(-2 * time.Hour)
	entry.ScanTime = time.Now().Add(-1 * time.Hour)

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if err := os.Chtimes(target, time.Now(), time.Now()); err != nil {
		t.Fatalf("chtimes target: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err != nil {
		t.Fatalf("expected recent cache to be reused, got error: %v", err)
	}
}

func TestLoadCacheExpiresWhenModifiedAndReuseWindowPassed(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "reuse-window-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 5, TotalFiles: 1}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}

	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	// Within overall 7-day TTL but beyond reuse window.
	entry.ModTime = time.Now().Add(-48 * time.Hour)
	entry.ScanTime = time.Now().Add(-(cacheReuseWindow + time.Hour))

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if err := os.Chtimes(target, time.Now(), time.Now()); err != nil {
		t.Fatalf("chtimes target: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected cache load to fail after reuse window passes")
	}
}

func TestLoadStaleCacheFromDiskAllowsRecentExpiredCache(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "stale-cache-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 7, TotalFiles: 2}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	// Expired for normal cache validation but still inside stale fallback window.
	entry.ModTime = time.Now().Add(-48 * time.Hour)
	entry.ScanTime = time.Now().Add(-48 * time.Hour)

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if err := os.Chtimes(target, time.Now(), time.Now()); err != nil {
		t.Fatalf("chtimes target: %v", err)
	}

	if _, err := loadCacheFromDisk(target); err == nil {
		t.Fatalf("expected normal cache load to fail")
	}
	if _, err := loadStaleCacheFromDisk(target); err != nil {
		t.Fatalf("expected stale cache load to succeed, got error: %v", err)
	}
}

func TestLoadStaleCacheFromDiskExpiresByStaleTTL(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)

	target := filepath.Join(home, "stale-cache-expired-target")
	if err := os.MkdirAll(target, 0o755); err != nil {
		t.Fatalf("create target: %v", err)
	}

	result := scanResult{TotalSize: 9, TotalFiles: 3}
	if err := saveCacheToDisk(target, result); err != nil {
		t.Fatalf("saveCacheToDisk: %v", err)
	}

	cachePath, err := getCachePath(target)
	if err != nil {
		t.Fatalf("getCachePath: %v", err)
	}
	file, err := os.Open(cachePath)
	if err != nil {
		t.Fatalf("open cache: %v", err)
	}
	var entry cacheEntry
	if err := gob.NewDecoder(file).Decode(&entry); err != nil {
		t.Fatalf("decode cache: %v", err)
	}
	_ = file.Close()

	entry.ScanTime = time.Now().Add(-(staleCacheTTL + time.Hour))

	tmp := cachePath + ".tmp"
	f, err := os.Create(tmp)
	if err != nil {
		t.Fatalf("create tmp cache: %v", err)
	}
	if err := gob.NewEncoder(f).Encode(&entry); err != nil {
		t.Fatalf("encode tmp cache: %v", err)
	}
	_ = f.Close()
	if err := os.Rename(tmp, cachePath); err != nil {
		t.Fatalf("rename tmp cache: %v", err)
	}

	if _, err := loadStaleCacheFromDisk(target); err == nil {
		t.Fatalf("expected stale cache load to fail after stale TTL")
	}
}

func TestScanPathPermissionError(t *testing.T) {
	root := t.TempDir()
	lockedDir := filepath.Join(root, "locked")
	if err := os.Mkdir(lockedDir, 0o755); err != nil {
		t.Fatalf("create locked dir: %v", err)
	}

	// Create a file before locking.
	if err := os.WriteFile(filepath.Join(lockedDir, "secret.txt"), []byte("shh"), 0o644); err != nil {
		t.Fatalf("write secret: %v", err)
	}

	// Remove permissions.
	if err := os.Chmod(lockedDir, 0o000); err != nil {
		t.Fatalf("chmod 000: %v", err)
	}
	defer func() {
		// Restore permissions for cleanup.
		_ = os.Chmod(lockedDir, 0o755)
	}()

	var files, dirs, bytes int64
	current := &atomic.Value{}
	current.Store("")

	// Scanning the locked dir itself should fail.
	_, err := scanPathConcurrent(context.Background(), lockedDir, &files, &dirs, &bytes, current)
	if err == nil {
		t.Fatalf("expected error scanning locked directory, got nil")
	}
	if !os.IsPermission(err) {
		t.Logf("unexpected error type: %v", err)
	}
}

func TestCalculateDirSizeFastHighFanoutCompletes(t *testing.T) {
	root := t.TempDir()

	// Reproduce high fan-out nested directory pattern that previously risked semaphore deadlock.
	const fanout = 256
	for i := range fanout {
		nested := filepath.Join(root, fmt.Sprintf("dir-%03d", i), "nested")
		if err := os.MkdirAll(nested, 0o755); err != nil {
			t.Fatalf("create nested dir: %v", err)
		}
		if err := os.WriteFile(filepath.Join(nested, "data.bin"), []byte("x"), 0o644); err != nil {
			t.Fatalf("write nested file: %v", err)
		}
	}

	var files, dirs, bytes int64
	current := &atomic.Value{}
	current.Store("")

	done := make(chan int64, 1)
	go func() {
		size, err := calculateDirSizeFast(context.Background(), root, &files, &dirs, &bytes, current)
		if err != nil {
			t.Errorf("calculateDirSizeFast: %v", err)
		}
		done <- size
	}()

	select {
	case total := <-done:
		if total <= 0 {
			t.Fatalf("expected positive total size, got %d", total)
		}
		if got := atomic.LoadInt64(&files); got < fanout {
			t.Fatalf("expected at least %d files scanned, got %d", fanout, got)
		}
	case <-time.After(5 * time.Second):
		t.Fatalf("calculateDirSizeFast did not complete under high fan-out")
	}
}

func TestSystemOverviewRootsDefaultsToRealSystemPaths(t *testing.T) {
	roots := systemOverviewRoots()
	if len(roots) != 2 {
		t.Fatalf("expected 2 default system roots, got %d", len(roots))
	}
	if roots[0].Path != "/Applications" || roots[1].Path != "/Library" {
		t.Fatalf("unexpected default system roots: %q, %q", roots[0].Path, roots[1].Path)
	}
	for _, root := range roots {
		if root.Size != -1 || !root.IsDir {
			t.Fatalf("default root %q must start pending and be a dir, got size=%d isDir=%v",
				root.Path, root.Size, root.IsDir)
		}
	}
}

func TestDeleteViewHidesZeroTally(t *testing.T) {
	// The delete counter is path-level and only advances once a move finishes, so a
	// single large directory sits at zero for the whole operation. Printing
	// "0 items removed" there reads as a stalled delete.
	var counter int64
	m := model{deleting: true, deleteCount: &counter}

	view := m.View()
	if strings.Contains(view, "0 items") {
		t.Fatalf("expected no zero tally while nothing has completed, got:\n%s", view)
	}
	if !strings.Contains(view, "moving to Trash") {
		t.Fatalf("expected a progress line while deleting, got:\n%s", view)
	}

	atomic.StoreInt64(&counter, 2)
	view = m.View()
	if !strings.Contains(view, "2") || !strings.Contains(view, "items") {
		t.Fatalf("expected the tally once paths completed, got:\n%s", view)
	}
}

func TestDeleteProgressPartialFailureRemovesSucceededPathsAndRefreshes(t *testing.T) {
	var filesScanned int64
	var dirsScanned int64
	var bytesScanned int64
	var currentPath atomic.Value
	parent := t.TempDir()
	removed := filepath.Join(parent, "removed")
	failed := filepath.Join(parent, "failed")

	m := model{
		path:         parent,
		entries:      []dirEntry{{Path: removed, Size: 10}, {Path: failed, Size: 20}},
		entriesAll:   []dirEntry{{Path: removed, Size: 10}, {Path: failed, Size: 20}},
		totalSize:    30,
		deleting:     true,
		filesScanned: &filesScanned,
		dirsScanned:  &dirsScanned,
		bytesScanned: &bytesScanned,
		currentPath:  &currentPath,
		cache: map[string]historyEntry{
			parent: {},
		},
		multiSelected:      map[string]bool{removed: true, failed: true},
		largeMultiSelected: map[string]bool{},
	}

	updated, cmd := m.Update(deleteProgressMsg{
		done:         true,
		err:          fmt.Errorf("permission denied"),
		count:        1,
		removedPaths: []string{removed},
	})
	got := updated.(model)

	if len(got.entries) != 1 || got.entries[0].Path != failed {
		t.Fatalf("expected only failed path to remain, got %#v", got.entries)
	}
	if got.totalSize != 20 {
		t.Fatalf("expected successful removal to update total size, got %d", got.totalSize)
	}
	if !strings.Contains(got.status, "Deleted 1 items; some failed") {
		t.Fatalf("expected partial-failure status, got %q", got.status)
	}
	if entry := got.cache[parent]; !entry.NeedsRefresh {
		t.Fatal("expected current path cache to be marked for refresh")
	}
	if cmd == nil {
		t.Fatal("expected partial success to trigger a rescan")
	}
}

// The no-argument invocation is the overview scan. Flipping that routing used to
// be invisible: every Go and CLI JSON test passed with the overview branch
// disabled, because the CLI cases all pass an explicit directory.
func TestResolveScanTargetRouting(t *testing.T) {
	cases := []struct {
		name         string
		envPath      string
		args         []string
		wantOverview bool
		wantPath     string
	}{
		{name: "no target is the overview scan", wantOverview: true, wantPath: "/"},
		{name: "explicit arg is a directory scan", args: []string{"/tmp"}, wantPath: "/tmp"},
		{name: "env target is a directory scan", envPath: "/tmp", wantPath: "/tmp"},
		{name: "env target wins over args", envPath: "/tmp", args: []string{"/var"}, wantPath: "/tmp"},
		{name: "relative arg resolves to absolute", args: []string{"."}, wantPath: mustAbs(t, ".")},
	}

	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path, isOverview, err := resolveScanTarget(tc.envPath, tc.args)
			if err != nil {
				t.Fatalf("resolveScanTarget: %v", err)
			}
			if isOverview != tc.wantOverview {
				t.Errorf("isOverview = %v, want %v", isOverview, tc.wantOverview)
			}
			if path != tc.wantPath {
				t.Errorf("path = %q, want %q", path, tc.wantPath)
			}
		})
	}
}

func mustAbs(t *testing.T, path string) string {
	t.Helper()
	abs, err := filepath.Abs(path)
	if err != nil {
		t.Fatalf("filepath.Abs(%q): %v", path, err)
	}
	return abs
}

func TestLiveScanKeepsUnavailableDirectoryAndPartialTotal(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission fixture requires an unprivileged user")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	locked := filepath.Join(root, "locked")
	writeFileWithSize(t, filepath.Join(root, "readable"), 4096)
	writeFileWithSize(t, filepath.Join(locked, "hidden"), 1<<20)
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	var files, dirs, bytes int64
	current := &atomic.Value{}
	current.Store("")
	msg := runScanResultCmd(t, startLiveScanCmd(root, &files, &dirs, &bytes, current))
	if msg.err != nil || msg.result.State != scanPartial || msg.result.TotalSize != 4096 {
		t.Fatalf("live scan lost partial result: %+v", msg)
	}
	for _, entry := range msg.result.Entries {
		if entry.Path == locked {
			if entry.State != scanUnavailable || entry.Size != 0 {
				t.Fatalf("unavailable entry: %+v", entry)
			}
			return
		}
	}
	t.Fatal("live scan omitted unreadable directory")
}

func TestPartialScanViewAndNavigationRetainUnavailableEntries(t *testing.T) {
	root := filepath.Join(t.TempDir(), "root")
	locked := filepath.Join(root, "locked")
	result := scanResult{
		State: scanPartial, TotalSize: 4096, TotalFiles: 1,
		Entries: []dirEntry{
			{Name: "readable", Path: filepath.Join(root, "readable"), Size: 4096},
			{Name: "locked", Path: locked, IsDir: true, State: scanUnavailable},
		},
	}
	m := model{path: root, width: 80, height: 24, cache: make(map[string]historyEntry), overviewSizeCache: map[string]int64{root: 1 << 20}}
	m.finishLiveScan(result)
	if len(m.entries) != 2 || m.scanState != scanPartial || m.overviewSizeCache[root] != 1<<20 {
		t.Fatalf("completion lost partial state or published incomplete snapshot: %+v", m)
	}
	view := m.View()
	if !strings.Contains(view, "locked") || !strings.Contains(view, "unknown") || !strings.Contains(view, humanizeBytes(4096)+"+") {
		t.Fatalf("partial view must retain unknown row and mark total: %s", view)
	}
	saved := snapshotFromModel(m)
	if saved.State != scanPartial || !saved.NeedsRefresh || m.cache[root].State != scanPartial || !m.cache[root].NeedsRefresh {
		t.Fatalf("navigation discarded coverage: %+v", saved)
	}
	m.multiSelected = map[string]bool{locked: true}
	m.deleteTarget = &m.entries[1]
	m.deleteConfirm = true
	if !strings.Contains(m.View(), "locked, unknown") {
		t.Fatalf("confirmation pretended size was zero: %s", m.View())
	}
}

func TestOverviewPartialMeasurementKeepsBytesAndUnknownRows(t *testing.T) {
	root := t.TempDir()
	m := model{path: "/", isOverview: true, width: 80, height: 24, entries: []dirEntry{{Name: "Unavailable", Path: root, IsDir: true, Size: -1}}}
	updated, _ := m.Update(overviewSizeMsg{Path: root, Err: os.ErrPermission})
	m = updated.(model)
	if m.entries[0].State != scanUnavailable || !strings.Contains(m.View(), "unknown") {
		t.Fatalf("overview hid failed measurement: %+v\n%s", m.entries, m.View())
	}
	updated, _ = m.Update(overviewSizeMsg{Path: root, Size: 4096, Err: os.ErrPermission})
	m = updated.(model)
	if m.totalSize != 4096 || m.entries[0].State != scanPartial || !strings.Contains(m.View(), humanizeBytes(4096)+"+") {
		t.Fatalf("overview discarded partial bytes: %+v\n%s", m.entries, m.View())
	}
}

func TestAnalyzeJSONReportsPartialCoverageAndUnavailableSizes(t *testing.T) {
	if os.Geteuid() == 0 {
		t.Skip("permission fixture requires an unprivileged user")
	}
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	locked := filepath.Join(root, "locked")
	writeFileWithSize(t, filepath.Join(root, "readable"), 4096)
	writeFileWithSize(t, filepath.Join(locked, "hidden"), 1<<20)
	if err := os.Chmod(locked, 0); err != nil {
		t.Fatal(err)
	}
	t.Cleanup(func() { _ = os.Chmod(locked, 0o755) })
	for _, overview := range []bool{false, true} {
		t.Run(fmt.Sprintf("overview=%t", overview), func(t *testing.T) {
			var result jsonOutput
			if overview {
				result = performOverviewScanForJSONWithEntries(root, nil, []dirEntry{{Name: "locked", Path: locked, IsDir: true, Size: -1}, {Name: "root", Path: root, IsDir: true, Size: -1}})
			} else {
				result = performDirectoryScanForJSON(root)
			}
			data, err := json.Marshal(result)
			if err != nil {
				t.Fatal(err)
			}
			var document struct {
				ScanStatus string `json:"scan_status"`
				TotalSize  int64  `json:"total_size"`
				Entries    []struct {
					Path       string `json:"path"`
					Size       int64  `json:"size"`
					ScanStatus string `json:"scan_status"`
				} `json:"entries"`
			}
			if err := json.Unmarshal(data, &document); err != nil {
				t.Fatal(err)
			}
			if document.ScanStatus != "partial" || document.TotalSize < 4096 {
				t.Fatalf("JSON lost coverage or bytes: %s", data)
			}
			for _, entry := range document.Entries {
				if entry.Path == locked {
					if entry.ScanStatus != "unavailable" || entry.Size != 0 {
						t.Fatalf("JSON fabricated unknown size: %s", data)
					}
					return
				}
			}
			t.Fatalf("JSON omitted unavailable entry: %s", data)
		})
	}
}
