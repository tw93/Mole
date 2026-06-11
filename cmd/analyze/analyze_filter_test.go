//go:build darwin

package main

import (
	"slices"
	"strings"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func topFilesFixture() model {
	files := []fileEntry{
		{Name: "alpha.mp4", Path: "/tmp/p/alpha.mp4", Size: 300},
		{Name: "photo.jpg", Path: "/tmp/p/photo.jpg", Size: 200},
		{Name: "beta.mp4", Path: "/tmp/p/beta.mp4", Size: 100},
	}
	cloned := make([]fileEntry, len(files))
	copy(cloned, files)
	return model{
		path:               "/tmp/p",
		showLargeFiles:     true,
		largeFilesAll:      files,
		largeFiles:         cloned,
		largeMultiSelected: map[string]bool{},
		height:             40,
		width:              120,
	}
}

func filterKey(t *testing.T, m model, msg tea.KeyMsg) (model, tea.Cmd) {
	t.Helper()
	updated, cmd := m.updateKey(msg)
	got, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	return got, cmd
}

func filterRune(t *testing.T, m model, r rune) (model, tea.Cmd) {
	t.Helper()
	return filterKey(t, m, tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{r}})
}

func filterType(t *testing.T, m model, s string) model {
	t.Helper()
	for _, r := range s {
		m, _ = filterRune(t, m, r)
	}
	return m
}

func TestLargeFilterNarrowsApplyAndClear(t *testing.T) {
	m := topFilesFixture()

	m, _ = filterRune(t, m, '/')
	if !m.largeFiltering {
		t.Fatalf("expected to enter filter input mode")
	}

	m = filterType(t, m, "mp4")
	if len(m.largeFiles) != 2 {
		t.Fatalf("want 2 matches for mp4, got %d", len(m.largeFiles))
	}

	// Enter applies the filter and returns to navigation, keeping the subset.
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.largeFiltering {
		t.Fatalf("Enter should exit input mode")
	}
	if len(m.largeFiles) != 2 {
		t.Fatalf("filter should persist after Enter, got %d", len(m.largeFiles))
	}

	// Esc clears the filter and restores the full list.
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEsc})
	if m.largeFilter != "" {
		t.Fatalf("Esc should clear the query, got %q", m.largeFilter)
	}
	if len(m.largeFiles) != 3 {
		t.Fatalf("want full list of 3 after clear, got %d", len(m.largeFiles))
	}
}

func TestLargeFilterSwallowsNavigationKeys(t *testing.T) {
	m := topFilesFixture()
	m, _ = filterRune(t, m, '/')

	// 'q' would normally quit; while filtering it must edit the query instead.
	m, cmd := filterRune(t, m, 'q')
	if cmd != nil {
		t.Fatalf("q while filtering must not emit a command (no quit)")
	}
	if m.largeFilter != "q" {
		t.Fatalf("q should append to the query, got %q", m.largeFilter)
	}
}

func TestLargeFilterBackspaceEditsQuery(t *testing.T) {
	m := topFilesFixture()
	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, "mp")

	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyBackspace})
	if m.largeFilter != "m" {
		t.Fatalf("backspace should trim the query to 'm', got %q", m.largeFilter)
	}
}

func TestLargeFilterClearsMultiSelectOnQueryChange(t *testing.T) {
	m := topFilesFixture()
	m.largeMultiSelected = map[string]bool{"/tmp/p/photo.jpg": true}

	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, "a")

	if len(m.largeMultiSelected) != 0 {
		t.Fatalf("changing the query should clear multi-selection, got %d", len(m.largeMultiSelected))
	}
}

func TestLargeFilterClampsSelection(t *testing.T) {
	m := topFilesFixture()
	m.largeSelected = 2 // beta.mp4 in the full list

	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, "photo") // single match, full index 1

	if len(m.largeFiles) != 1 {
		t.Fatalf("want 1 match for photo, got %d", len(m.largeFiles))
	}
	if m.largeSelected != 0 {
		t.Fatalf("selection should clamp into the visible range, got %d", m.largeSelected)
	}
}

func TestLargeFilterDeleteTargetsVisibleMatch(t *testing.T) {
	m := topFilesFixture()

	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, "beta") // single visible match: beta.mp4 (hidden in full list at index 2)
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEnter})

	// backspace maps to the delete action once we are out of input mode.
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyBackspace})
	if !m.deleteConfirm {
		t.Fatalf("expected delete confirmation to open")
	}
	if m.deleteTarget == nil || m.deleteTarget.Path != "/tmp/p/beta.mp4" {
		t.Fatalf("delete must target the visible match, got %+v", m.deleteTarget)
	}
}

func TestLargeFilterIgnoredOutsideTopView(t *testing.T) {
	m := topFilesFixture()
	m.showLargeFiles = false
	m.entries = []dirEntry{{Name: "x", Path: "/tmp/p/x", Size: 1}}

	m, _ = filterRune(t, m, '/')
	if m.largeFiltering {
		t.Fatalf("'/' should do nothing outside the Top-files view")
	}
}

func treeFixture() model {
	entries := []dirEntry{
		{Name: "apps", Path: "/tmp/p/apps", Size: 300, IsDir: true},
		{Name: "logs", Path: "/tmp/p/logs", Size: 200, IsDir: true},
		{Name: "node_modules", Path: "/tmp/p/node_modules", Size: 100, IsDir: true},
	}
	var filesScanned, dirsScanned, bytesScanned int64
	return model{
		path:          "/tmp/p",
		entriesAll:    entries,
		entries:       slices.Clone(entries),
		multiSelected: map[string]bool{},
		cache:         map[string]historyEntry{},
		filesScanned:  &filesScanned,
		dirsScanned:   &dirsScanned,
		bytesScanned:  &bytesScanned,
		height:        40,
		width:         120,
	}
}

func TestEntryFilterNarrowsApplyAndClear(t *testing.T) {
	m := treeFixture()

	m, _ = filterRune(t, m, '/')
	if !m.entryFiltering {
		t.Fatalf("expected to enter directory filter input mode")
	}

	m = filterType(t, m, "s") // apps, logs, node_modules all end in 's'
	if len(m.entries) != 3 {
		t.Fatalf("want 3 matches for s, got %d", len(m.entries))
	}
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyBackspace})
	m = filterType(t, m, "ode") // only node_modules contains "ode"
	if len(m.entries) != 1 {
		t.Fatalf("want 1 match for ode, got %d", len(m.entries))
	}

	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEsc})
	if m.entryFilter != "" {
		t.Fatalf("Esc should clear the query, got %q", m.entryFilter)
	}
	if len(m.entries) != 3 {
		t.Fatalf("want full list of 3 after clear, got %d", len(m.entries))
	}
}

func TestEntryFilterSwallowsNavigationKeys(t *testing.T) {
	m := treeFixture()
	m, _ = filterRune(t, m, '/')

	m, cmd := filterRune(t, m, 'q')
	if cmd != nil {
		t.Fatalf("q while filtering must not emit a command (no quit)")
	}
	if m.entryFilter != "q" {
		t.Fatalf("q should append to the query, got %q", m.entryFilter)
	}
}

func TestEntryFilterClearsMultiSelectOnQueryChange(t *testing.T) {
	m := treeFixture()
	m.multiSelected = map[string]bool{"/tmp/p/logs": true}

	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, "a")

	if len(m.multiSelected) != 0 {
		t.Fatalf("changing the query should clear multi-selection, got %d", len(m.multiSelected))
	}
}

func TestEntryFilterIgnoredInOverview(t *testing.T) {
	m := treeFixture()
	m.isOverview = true
	m.path = "/"

	m, _ = filterRune(t, m, '/')
	if m.entryFiltering {
		t.Fatalf("'/' should do nothing in overview mode")
	}
}

// The load-bearing case: filter the tree, drill into a match, then go back.
// The parent must be restored in full (not the one-row filtered view) with the
// entered directory still highlighted.
func TestEntryFilterDrillInPreservesFullParentOnBack(t *testing.T) {
	m := treeFixture()
	m.cache["/tmp/p/node_modules"] = historyEntry{
		Path:      "/tmp/p/node_modules",
		Entries:   []dirEntry{{Name: "pkg", Path: "/tmp/p/node_modules/pkg", Size: 50, IsDir: true}},
		TotalSize: 50,
	}

	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, "node") // single match: node_modules (full index 2)
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEnter})
	if len(m.entries) != 1 {
		t.Fatalf("want 1 match before drilling in, got %d", len(m.entries))
	}

	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEnter}) // drill into the match
	if m.path != "/tmp/p/node_modules" {
		t.Fatalf("expected to drill into node_modules, got %s", m.path)
	}
	if m.entryFilter != "" {
		t.Fatalf("filter must be cleared after drilling in, got %q", m.entryFilter)
	}

	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEsc}) // go back to parent
	if m.path != "/tmp/p" {
		t.Fatalf("expected to return to /tmp/p, got %s", m.path)
	}
	if len(m.entries) != 3 {
		t.Fatalf("parent must be restored with all 3 entries, got %d", len(m.entries))
	}
	if m.selected < 0 || m.selected >= len(m.entries) || m.entries[m.selected].Path != "/tmp/p/node_modules" {
		t.Fatalf("entered entry should stay highlighted, selected=%d", m.selected)
	}
}

// Deleting with no active filter must not corrupt the backing lists. Before the
// rebuild-from-backing fix, removing from both a list and its aliased view
// shifted the shared array twice, leaving a duplicated, stale entry behind.
func TestRemovePathPreservesBackingLists(t *testing.T) {
	m := treeFixture() // entriesAll aliases entries: [apps, logs, node_modules]
	m.totalSize = 600

	m.removePathFromView("/tmp/p/logs")

	if len(m.entriesAll) != 2 {
		t.Fatalf("entriesAll should drop to 2, got %d", len(m.entriesAll))
	}
	if len(m.entries) != 2 {
		t.Fatalf("entries should drop to 2, got %d", len(m.entries))
	}
	seen := map[string]int{}
	for _, e := range m.entriesAll {
		seen[e.Path]++
	}
	if seen["/tmp/p/logs"] != 0 {
		t.Fatalf("deleted path still present in entriesAll")
	}
	for p, c := range seen {
		if c != 1 {
			t.Fatalf("entry %s duplicated %d times in entriesAll", p, c)
		}
	}
}

func TestEntryFilterViewShowsHintAndQuery(t *testing.T) {
	m := treeFixture()
	if hint := m.View(); !strings.Contains(hint, "/ Filter") {
		t.Fatalf("expected '/ Filter' footer hint, got:\n%s", hint)
	}

	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, "node")
	view := m.View()
	if !strings.Contains(view, "Filter:") {
		t.Fatalf("expected active 'Filter:' line, got:\n%s", view)
	}
	if !strings.Contains(view, "No matches") && !strings.Contains(view, "node_modules") {
		t.Fatalf("expected the single match rendered, got:\n%s", view)
	}
}

func TestLargeFilterViewShowsHintAndQuery(t *testing.T) {
	m := topFilesFixture()
	if hint := m.View(); !strings.Contains(hint, "/ Filter") {
		t.Fatalf("expected '/ Filter' footer hint, got:\n%s", hint)
	}

	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, "mp4")
	view := m.View()
	if !strings.Contains(view, "Filter:") {
		t.Fatalf("expected active 'Filter:' line, got:\n%s", view)
	}
	if !strings.Contains(view, "matches") {
		t.Fatalf("expected match count in filter line, got:\n%s", view)
	}
}
