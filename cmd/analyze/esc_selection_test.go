package main

import (
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func escKey(t *testing.T, m model) (model, tea.Cmd) {
	t.Helper()
	updated, cmd := m.updateKey(tea.KeyMsg{Type: tea.KeyEsc})
	got, ok := updated.(model)
	if !ok {
		t.Fatalf("expected model, got %T", updated)
	}
	return got, cmd
}

func TestEscClearsSelectionBeforeLeavingTopFiles(t *testing.T) {
	files := []fileEntry{
		{Name: "disk.vhdx", Path: `C:\p\disk.vhdx`, Size: 300},
		{Name: "setup.iso", Path: `C:\p\setup.iso`, Size: 200},
	}
	m := model{
		path:               `C:\p`,
		showLargeFiles:     true,
		largeFilesAll:      files,
		largeFiles:         append([]fileEntry(nil), files...),
		largeMultiSelected: map[string]bool{`C:\p\disk.vhdx`: true},
		height:             40,
		width:              120,
	}

	m, cmd := escKey(t, m)
	if cmd != nil {
		t.Fatalf("Esc with a selection must not emit a command")
	}
	if len(m.largeMultiSelected) != 0 {
		t.Fatalf("Esc should clear the selection, got %d selected", len(m.largeMultiSelected))
	}
	if !m.showLargeFiles {
		t.Fatalf("the first Esc should stay in Top Files")
	}

	m, _ = escKey(t, m)
	if m.showLargeFiles {
		t.Fatalf("Esc with nothing selected should leave Top Files")
	}
}

func TestEscClearsSelectionBeforeFilterInDirectoryView(t *testing.T) {
	entries := []dirEntry{
		{Name: "apps", Path: `C:\p\apps`, Size: 300, IsDir: true},
		{Name: "node_modules", Path: `C:\p\node_modules`, Size: 100, IsDir: true},
	}
	m := model{
		path:          `C:\p`,
		entriesAll:    entries,
		entries:       entries[1:],
		entryFilter:   "ode",
		multiSelected: map[string]bool{`C:\p\node_modules`: true},
		height:        40,
		width:         120,
	}

	m, cmd := escKey(t, m)
	if cmd != nil {
		t.Fatalf("Esc with a selection must not emit a command")
	}
	if len(m.multiSelected) != 0 {
		t.Fatalf("Esc should clear the selection, got %d selected", len(m.multiSelected))
	}
	if m.entryFilter != "ode" || m.path != `C:\p` {
		t.Fatalf("the first Esc should keep the filter and folder, got filter %q path %q", m.entryFilter, m.path)
	}

	m, _ = escKey(t, m)
	if m.entryFilter != "" {
		t.Fatalf("the second Esc should clear the filter, got %q", m.entryFilter)
	}
}
