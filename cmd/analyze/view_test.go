package main

import (
	"fmt"
	"path/filepath"
	"regexp"
	"strings"
	"sync/atomic"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

var ansiPattern = regexp.MustCompile("\x1b\\[[0-9;]*m")

func stripANSI(s string) string { return ansiPattern.ReplaceAllString(s, "") }

func rowContaining(view, needle string) string {
	for _, line := range strings.Split(view, "\n") {
		if strings.Contains(line, needle) {
			return line
		}
	}
	return ""
}

func keyRunes(s string) tea.KeyMsg { return tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune(s)} }

func TestUpdateKeyEscGoesBackFromDirectoryView(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "parent")
	child := filepath.Join(parent, "child")
	m := model{
		path: child,
		history: []historyEntry{{
			Path:    parent,
			Entries: []dirEntry{{Name: "child", Path: child, Size: 1, IsDir: true}},
		}},
		entries: []dirEntry{{Name: "file.txt", Path: filepath.Join(child, "file.txt"), Size: 1}},
	}

	updated, cmd := m.updateKey(tea.KeyMsg{Type: tea.KeyEsc})
	if cmd != nil {
		t.Fatalf("expected no command when returning from cached history, got %v", cmd)
	}
	got := updated.(model)
	if got.path != parent {
		t.Fatalf("path after Esc = %q, want %q", got.path, parent)
	}
	if got.status == "" {
		t.Fatal("expected status to be updated after Esc navigation")
	}
}

// Backspace is Explorer's back key on Windows; Delete is the delete key.
func TestBackspaceGoesBackAndDeleteKeyConfirms(t *testing.T) {
	parent := filepath.Join(t.TempDir(), "parent")
	child := filepath.Join(parent, "child")
	file := filepath.Join(child, "file.bin")
	m := model{
		path:    child,
		history: []historyEntry{{Path: parent, Entries: []dirEntry{{Name: "child", Path: child, Size: 1, IsDir: true}}}},
		entries: []dirEntry{{Name: "file.bin", Path: file, Size: 10}},
	}

	updated, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyBackspace})
	if got := updated.(model); got.path != parent || got.deleteConfirm {
		t.Fatalf("Backspace: path=%q deleteConfirm=%v, want back to %q without a prompt", got.path, got.deleteConfirm, parent)
	}

	updated, _ = m.updateKey(tea.KeyMsg{Type: tea.KeyDelete})
	got := updated.(model)
	if !got.deleteConfirm || got.deleteTarget == nil || got.deleteTarget.Path != file {
		t.Fatalf("Delete: deleteConfirm=%v target=%v, want a prompt for %q", got.deleteConfirm, got.deleteTarget, file)
	}
	view := stripANSI(got.View())
	if !strings.Contains(view, "Move to Recycle Bin: file.bin, 10 B  Press Enter to confirm  |  ESC cancel") {
		t.Fatalf("expected the macOS confirmation line, got:\n%s", view)
	}

	updated, _ = got.updateKey(tea.KeyMsg{Type: tea.KeyEsc})
	if got := updated.(model); got.deleteConfirm || got.status != "Cancelled" {
		t.Fatalf("Esc in confirmation: deleteConfirm=%v status=%q", got.deleteConfirm, got.status)
	}
}

func TestDeleteKeysIgnoredWhileScanning(t *testing.T) {
	dir := t.TempDir()
	m := model{
		path:          dir,
		scanning:      true,
		entries:       []dirEntry{{Name: "a", Path: filepath.Join(dir, "a"), Size: 1, IsDir: true}},
		multiSelected: map[string]bool{},
	}
	updated, _ := m.updateKey(tea.KeyMsg{Type: tea.KeyDelete})
	got := updated.(model)
	if got.deleteConfirm {
		t.Fatal("Delete opened a confirmation while scanning")
	}
	if got.status != "Move to Recycle Bin is available after the scan finishes" {
		t.Fatalf("status = %q", got.status)
	}
}

func TestUpdateKeyCtrlCQuits(t *testing.T) {
	_, cmd := model{}.updateKey(tea.KeyMsg{Type: tea.KeyCtrlC})
	if cmd == nil {
		t.Fatal("expected quit command for Ctrl+C")
	}
	if _, ok := cmd().(tea.QuitMsg); !ok {
		t.Fatal("expected tea.QuitMsg from quit command")
	}
}

func TestDirectoryFooterMatchesMacOSWithWindowsDeleteKey(t *testing.T) {
	dir := t.TempDir()
	m := model{
		path:       dir,
		history:    []historyEntry{{Path: filepath.Dir(dir)}},
		entries:    []dirEntry{{Name: "cache", Path: filepath.Join(dir, "cache"), Size: 1, IsDir: true}},
		largeFiles: []fileEntry{{Name: "large.bin", Path: filepath.Join(dir, "large.bin"), Size: 1024}},
		totalSize:  1024,
	}

	want := "↑↓←→ | Space Select | Enter | / Filter | R Refresh | O Open | P Preview | F File | Del Recycle | T Top 1 | Esc Back | Q/Ctrl+C Quit"
	if !strings.Contains(stripANSI(m.View()), want) {
		t.Fatalf("expected footer %q, got:\n%s", want, stripANSI(m.View()))
	}
}

func TestOverviewFooterAndHeader(t *testing.T) {
	m := model{
		path:       overviewPath,
		isOverview: true,
		diskFree:   5 << 30,
		entries:    []dirEntry{{Name: "Home", Path: t.TempDir(), Size: 1, IsDir: true}},
		totalSize:  1,
	}
	view := stripANSI(m.View())
	for _, want := range []string{
		"Analyze Disk  (5.0 GB free)",
		"Select a location to explore:",
		"↑↓→ | Enter | R Refresh | O Open | P Preview | F File | Esc/Q Quit",
	} {
		if !strings.Contains(view, want) {
			t.Fatalf("expected %q in overview, got:\n%s", want, view)
		}
	}

	m.diskFree = 0
	if strings.Contains(m.View(), "free)") {
		t.Fatalf("expected no free-space label when unknown, got:\n%s", m.View())
	}
}

func TestOverviewPendingSizeUsesScanningSpinner(t *testing.T) {
	m := model{
		isOverview: true,
		path:       overviewPath,
		entries: []dirEntry{
			{Name: "Program Files", Path: t.TempDir(), Size: 16 << 30, IsDir: true},
			{Name: "Temp Files", Path: t.TempDir(), Size: -1, IsDir: true},
		},
		totalSize: 16 << 30,
	}

	view := m.View()
	if !strings.Contains(view, fmt.Sprintf("%s scanning", spinnerFrames[0])) {
		t.Fatalf("expected animated scanning placeholder for pending row, got:\n%s", view)
	}
	for _, icon := range []string{"📁", "📄"} {
		if strings.Contains(view, icon) {
			t.Fatalf("overview should not render emoji icon %q, got:\n%s", icon, view)
		}
	}
}

func TestViewKeepsCachedEntriesWhileRefreshing(t *testing.T) {
	dir := t.TempDir()
	m := model{
		path:             dir,
		history:          []historyEntry{{Path: filepath.Dir(dir)}},
		entries:          []dirEntry{{Name: "warmed-child", Path: filepath.Join(dir, "warmed-child"), Size: 100, IsDir: true}},
		totalSize:        100,
		scanning:         true,
		viewNeedsRefresh: true,
	}

	view := m.View()
	if !strings.Contains(view, "warmed-child") || !strings.Contains(view, "Showing cached results while refreshing") {
		t.Fatalf("expected cached rows and the refreshing hint, got:\n%s", view)
	}
}

func TestViewBlanksToScanOnlyWithoutWarmCache(t *testing.T) {
	dir := t.TempDir()
	m := model{
		path:      dir,
		history:   []historyEntry{{Path: filepath.Dir(dir)}},
		entries:   []dirEntry{{Name: "stale-parent-row", Path: filepath.Join(filepath.Dir(dir), "stale-parent-row"), Size: 100, IsDir: true}},
		totalSize: 100,
		scanning:  true,
	}

	view := m.View()
	if strings.Contains(view, "stale-parent-row") {
		t.Fatalf("expected scan-only view to hide stale entries, got:\n%s", view)
	}
	if !strings.Contains(view, "Scanning") {
		t.Fatalf("expected scan-only view to show scanning progress, got:\n%s", view)
	}
}

func TestDirectoryViewKeepsLowPercentRowsAligned(t *testing.T) {
	dir := t.TempDir()
	m := model{
		path:      dir,
		width:     120,
		height:    20,
		selected:  -1,
		totalSize: 100_000,
		entries: []dirEntry{
			{Name: "large", Path: filepath.Join(dir, "large"), Size: 47_000, IsDir: true},
			{Name: "tiny", Path: filepath.Join(dir, "tiny"), Size: 46, IsDir: true},
		},
	}

	largeRow := stripANSI(rowContaining(m.View(), "large"))
	tinyRow := stripANSI(rowContaining(m.View(), "tiny"))
	if !strings.Contains(tinyRow, "< 0.1%") {
		t.Fatalf("expected tiny row to show < 0.1%%, got:\n%s", tinyRow)
	}
	largePrefix, _, largeHasDivider := strings.Cut(largeRow, "  |  ")
	tinyPrefix, _, tinyHasDivider := strings.Cut(tinyRow, "  |  ")
	if !largeHasDivider || !tinyHasDivider {
		t.Fatalf("missing percent divider\nlarge: %q\ntiny:  %q", largeRow, tinyRow)
	}
	if displayWidth(largePrefix) != displayWidth(tinyPrefix) {
		t.Fatalf("percent divider columns differ\nlarge: %q\ntiny:  %q", largeRow, tinyRow)
	}
	if displayWidth(largeRow) != displayWidth(tinyRow) {
		t.Fatalf("row widths differ\nlarge: %q\ntiny:  %q", largeRow, tinyRow)
	}
}

// The directory row layout is the macOS one: prefix, select dot, rank, bar,
// percent, divider, icon and name, then the 10-column size field.
func TestDirectoryRowLayout(t *testing.T) {
	dir := t.TempDir()
	m := model{
		path:      dir,
		width:     85,
		height:    20,
		totalSize: 2 << 30,
		entries: []dirEntry{
			{Name: "Videos", Path: filepath.Join(dir, "Videos"), Size: 1 << 30, IsDir: true},
			{Name: "notes.iso", Path: filepath.Join(dir, "notes.iso"), Size: 1 << 30},
		},
	}
	view := stripANSI(m.View())
	selected := rowContaining(view, "Videos")
	other := rowContaining(view, "notes.iso")
	wantSelected := " ▶ ○  1. " + strings.Repeat("█", barWidth) + "  50.0%  |  📁 " + padName("Videos", 24) + "    1.0 GB "
	if selected != wantSelected {
		t.Fatalf("selected row\n got %q\nwant %q", selected, wantSelected)
	}
	if !strings.HasPrefix(other, "   ○  2. ") || !strings.Contains(other, "|  📄 notes.iso") {
		t.Fatalf("unexpected second row %q", other)
	}
}

func TestSizeColumnKeepsUnitsAlignedForPartialRows(t *testing.T) {
	complete := sizeColumn(measuredSizeLabel(2*1024*1024*1024, scanComplete))
	partial := sizeColumn(measuredSizeLabel(37*1024*1024*1024, scanPartial))
	unknown := sizeColumn(measuredSizeLabel(0, scanUnavailable))
	for _, col := range []string{complete, partial, unknown} {
		if len(col) != 10 {
			t.Fatalf("size column %q is %d columns, want 10", col, len(col))
		}
	}
	if strings.Index(complete, "GB") != strings.Index(partial, "GB") {
		t.Fatalf("units drift between %q and %q", complete, partial)
	}
	if partial[9] != '+' || complete[9] != ' ' || unknown[9] != ' ' {
		t.Fatalf("partial marker not in its own last column: %q %q %q", complete, partial, unknown)
	}
}

func TestDeleteViewHidesZeroTally(t *testing.T) {
	var counter int64
	m := model{deleting: true, deleteCount: &counter}

	view := m.View()
	if strings.Contains(view, "0 items") {
		t.Fatalf("expected no zero tally while nothing has completed, got:\n%s", view)
	}
	if !strings.Contains(view, "Moving to Recycle Bin") {
		t.Fatalf("expected a progress line while deleting, got:\n%s", view)
	}

	atomic.StoreInt64(&counter, 2)
	if view = m.View(); !strings.Contains(view, "2") || !strings.Contains(view, "items") {
		t.Fatalf("expected the tally once paths completed, got:\n%s", view)
	}
}

func TestLargeFilesViewLayout(t *testing.T) {
	dir := t.TempDir()
	m := model{
		path:           dir,
		width:          85,
		showLargeFiles: true,
		largeFiles: []fileEntry{
			{Name: "disk.vhdx", Path: filepath.Join(dir, "disk.vhdx"), Size: 4 << 30},
			{Name: "setup.iso", Path: filepath.Join(dir, "setup.iso"), Size: 1 << 30},
		},
	}
	view := stripANSI(m.View())
	row := rowContaining(view, "disk.vhdx")
	if !strings.HasPrefix(row, " ▶ ○  1. "+strings.Repeat("█", barWidth)+"  |  📄 ") || !strings.HasSuffix(row, "    4.0 GB") {
		t.Fatalf("unexpected large-file row %q", row)
	}
	if !strings.Contains(view, "↑↓← | Space Select | / Filter | R Refresh | O Open | P Preview | F File | Del Recycle | Esc Back | Q/Ctrl+C Quit") {
		t.Fatalf("unexpected large-file footer:\n%s", view)
	}
}

func TestPathIsWithin(t *testing.T) {
	cases := []struct {
		path, root string
		want       bool
	}{
		{`C:\Users\me\Downloads`, overviewPath, true},
		{`C:\Users\me\Downloads`, `C:\Users\me`, true},
		{`c:\users\ME\downloads`, `C:\Users\me`, true},
		{`C:\Users\me`, `C:\Users\me`, true},
		{`C:\Users\meow`, `C:\Users\me`, false},
		{`C:\Users`, `C:\Users\me`, false},
	}
	for _, tc := range cases {
		path, root := filepath.FromSlash(strings.ReplaceAll(tc.path, `\`, "/")), tc.root
		if root != overviewPath {
			root = filepath.FromSlash(strings.ReplaceAll(root, `\`, "/"))
		}
		if got := pathIsWithin(path, root); got != tc.want {
			t.Errorf("pathIsWithin(%q, %q) = %v, want %v", path, root, got, tc.want)
		}
	}
}

func TestResolveScanTargetRouting(t *testing.T) {
	dir := t.TempDir()
	other := t.TempDir()
	cases := []struct {
		name         string
		envPath      string
		args         []string
		wantOverview bool
		wantPath     string
	}{
		{name: "no target is the overview", wantOverview: true, wantPath: overviewPath},
		{name: "explicit arg is a directory scan", args: []string{dir}, wantPath: dir},
		{name: "env target is a directory scan", envPath: dir, wantPath: dir},
		{name: "env target wins over args", envPath: dir, args: []string{other}, wantPath: dir},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			path, isOverview, err := resolveScanTarget(tc.envPath, tc.args)
			if err != nil {
				t.Fatalf("resolveScanTarget: %v", err)
			}
			if isOverview != tc.wantOverview || path != tc.wantPath {
				t.Errorf("got (%q, %v), want (%q, %v)", path, isOverview, tc.wantPath, tc.wantOverview)
			}
		})
	}

	if _, _, err := resolveScanTarget(filepath.Join(dir, "missing"), nil); err == nil {
		t.Error("expected an error for a missing path")
	}
}

func TestNavigationEnterAndBackRestoresSelection(t *testing.T) {
	root := t.TempDir()
	child := filepath.Join(root, "child")
	var files, dirs, bytes int64
	m := model{
		path:          root,
		entries:       []dirEntry{{Name: "a", Path: filepath.Join(root, "a"), Size: 5}, {Name: "child", Path: child, Size: 3, IsDir: true}},
		selected:      1,
		cache:         map[string]historyEntry{child: {Path: child, Entries: []dirEntry{{Name: "x", Path: filepath.Join(child, "x"), Size: 3}}, TotalSize: 3}},
		filesScanned:  &files,
		dirsScanned:   &dirs,
		bytesScanned:  &bytes,
		multiSelected: map[string]bool{},
	}
	m.entriesAll = m.entries

	updated, cmd := m.updateKey(tea.KeyMsg{Type: tea.KeyRight})
	got := updated.(model)
	if got.path != child || got.scanning || cmd != nil {
		t.Fatalf("Right into a cached child: path=%q scanning=%v cmd=%v", got.path, got.scanning, cmd)
	}
	if got.status != "Cached view for "+displayPath(child) {
		t.Fatalf("status = %q", got.status)
	}

	updated, _ = got.updateKey(tea.KeyMsg{Type: tea.KeyLeft})
	got = updated.(model)
	if got.path != root || got.selected != 1 {
		t.Fatalf("Left back: path=%q selected=%d, want %q and 1", got.path, got.selected, root)
	}
}

func TestTopFilesToggleAndFilter(t *testing.T) {
	dir := t.TempDir()
	m := model{
		path: dir,
		largeFilesAll: []fileEntry{
			{Name: "alpha.iso", Path: filepath.Join(dir, "alpha.iso"), Size: 3 << 20},
			{Name: "beta.vhdx", Path: filepath.Join(dir, "beta.vhdx"), Size: 2 << 20},
		},
		largeMultiSelected: map[string]bool{},
		multiSelected:      map[string]bool{},
	}
	m.largeFiles = m.largeFilesAll

	updated, _ := m.updateKey(keyRunes("T"))
	got := updated.(model)
	if !got.showLargeFiles {
		t.Fatal("T did not open the top files view")
	}
	for _, key := range []tea.KeyMsg{keyRunes("/"), keyRunes("beta"), {Type: tea.KeyEnter}} {
		updated, _ = got.updateKey(key)
		got = updated.(model)
	}
	if len(got.largeFiles) != 1 || got.largeFiles[0].Name != "beta.vhdx" {
		t.Fatalf("filter result = %+v", got.largeFiles)
	}
	if got.status != `Filter "beta", 1 matches` {
		t.Fatalf("status = %q", got.status)
	}
}

func TestRemovePathPreservesBackingLists(t *testing.T) {
	dir := t.TempDir()
	a, b := filepath.Join(dir, "a"), filepath.Join(dir, "b")
	m := model{
		entriesAll:    []dirEntry{{Name: "a", Path: a, Size: 1}, {Name: "b", Path: b, Size: 2}},
		largeFilesAll: []fileEntry{{Name: "a", Path: a, Size: 1}, {Name: "b", Path: b, Size: 2}},
		totalSize:     3,
	}
	m.entries = m.entriesAll
	m.largeFiles = m.largeFilesAll
	m.removePathFromView(a)
	if len(m.entriesAll) != 1 || m.entriesAll[0].Path != b || len(m.largeFilesAll) != 1 || m.totalSize != 2 {
		t.Fatalf("after removing a: entries=%+v large=%+v total=%d", m.entriesAll, m.largeFilesAll, m.totalSize)
	}
}

func TestDeleteProgressPartialFailureRemovesSucceededPathsAndRefreshes(t *testing.T) {
	var filesScanned, dirsScanned, bytesScanned int64
	var currentPath atomic.Value
	parent := t.TempDir()
	removed := filepath.Join(parent, "removed")
	failed := filepath.Join(parent, "failed")

	m := model{
		path:               parent,
		entries:            []dirEntry{{Path: removed, Size: 10}, {Path: failed, Size: 20}},
		entriesAll:         []dirEntry{{Path: removed, Size: 10}, {Path: failed, Size: 20}},
		totalSize:          30,
		deleting:           true,
		filesScanned:       &filesScanned,
		dirsScanned:        &dirsScanned,
		bytesScanned:       &bytesScanned,
		currentPath:        &currentPath,
		cache:              map[string]historyEntry{parent: {}},
		multiSelected:      map[string]bool{removed: true, failed: true},
		largeMultiSelected: map[string]bool{},
	}

	updated, cmd := m.Update(deleteProgressMsg{
		done:         true,
		err:          fmt.Errorf("access denied"),
		count:        1,
		removedPaths: []string{removed},
	})
	got := updated.(model)
	if len(got.entries) != 1 || got.entries[0].Path != failed || got.totalSize != 20 {
		t.Fatalf("entries=%+v total=%d, want only the failed path and 20", got.entries, got.totalSize)
	}
	if !strings.Contains(got.status, "Removed 1 items, some failed") {
		t.Fatalf("status = %q", got.status)
	}
	if !got.cache[parent].NeedsRefresh {
		t.Fatal("expected current path cache to be marked for refresh")
	}
	if cmd == nil {
		t.Fatal("expected partial success to trigger a rescan")
	}
}

func TestAnalyzeRowsFitNarrowTerminal(t *testing.T) {
	for _, width := range []int{50, 60, 79, 80, 81, 84, 85, 120} {
		for _, height := range []int{20, 40} {
			for _, mode := range []string{"directory", "overview", "large"} {
				m := model{path: "test", width: width, height: height, totalSize: 1024, entries: []dirEntry{{Name: "demo", Path: "test/demo", Size: 1024}}}
				if mode == "overview" {
					m.path = overviewPath
				}
				if mode == "large" {
					m.showLargeFiles = true
					m.largeFiles = []fileEntry{{Path: "test/demo", Size: 1024}}
				}
				row := stripANSI(rowContaining(m.View(), "demo"))
				if row == "" {
					t.Fatal("missing positive row")
				}
				if got := displayWidth(row); got > width {
					t.Errorf("%s %dx%d row width %d: %q", mode, width, height, got, row)
				}
			}
		}
	}
}

// A successful shell operation can recycle, permanently delete after the
// shell's prompt, or leave recycling unverified. Completion must not promise
// recoverability when the message carries only the removal count.
func TestDeleteCompletionDoesNotPromiseRecycling(t *testing.T) {
	for _, partial := range []bool{false, true} {
		for _, withPath := range []bool{false, true} {
			t.Run(fmt.Sprintf("partial=%v/path=%v", partial, withPath), func(t *testing.T) {
				var files, dirs, bytes int64
				var current atomic.Value
				parent := t.TempDir()
				target := filepath.Join(parent, "removed")
				m := model{path: parent, deleting: true, filesScanned: &files,
					dirsScanned: &dirs, bytesScanned: &bytes, currentPath: &current}
				msg := deleteProgressMsg{done: true, count: 1}
				if withPath {
					msg.removedPaths = []string{target}
				}
				if partial {
					msg.err = fmt.Errorf("access denied")
				}
				updated, _ := m.Update(msg)
				status := updated.(model).status
				if partial && !withPath {
					if !strings.HasPrefix(status, "Failed to move to Recycle Bin:") {
						t.Fatalf("failed operation status = %q", status)
					}
					return
				}
				want := "Removed 1 items"
				if partial {
					want += ", some failed: access denied"
				}
				if status != want {
					t.Fatalf("completion = %q, want %q", status, want)
				}
			})
		}
	}
}
