package main

import (
	"context"
	"errors"
	"path/filepath"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestDeletingIgnoresHiddenActions(t *testing.T) {
	keys := []tea.KeyMsg{{Type: tea.KeyDown}, {Type: tea.KeyDelete}, {Type: tea.KeyEnter}, {Type: tea.KeyEsc}, keyRunes("r"), keyRunes(" "), keyRunes("o")}
	for _, key := range keys {
		t.Run(key.String(), func(t *testing.T) {
			m := newModel(t.TempDir(), false)
			m.scanning = false
			m.deleting = true
			m.entries = []dirEntry{{Name: "first", Path: filepath.Join(m.path, "first"), Size: 1, IsDir: true}, {Name: "second", Path: filepath.Join(m.path, "second"), Size: 2}}
			next, cmd := m.Update(key)
			got := next.(model)
			if cmd != nil || got.path != m.path || got.selected != m.selected || got.deleteConfirm || len(got.multiSelected) != 0 || got.scanning {
				t.Fatalf("busy input changed state: key=%s path=%s selected=%d confirm=%v scanning=%v cmd=%v", key.String(), got.path, got.selected, got.deleteConfirm, got.scanning, cmd != nil)
			}
		})
	}
}

func TestDeletingKeepsQuitKeys(t *testing.T) {
	for _, key := range []tea.KeyMsg{keyRunes("q"), keyRunes("Q"), {Type: tea.KeyCtrlC}} {
		m := model{deleting: true}
		_, cmd := m.Update(key)
		if cmd == nil {
			t.Fatalf("%s did not quit", key.String())
		}
		if _, ok := cmd().(tea.QuitMsg); !ok {
			t.Fatalf("%s did not return QuitMsg", key.String())
		}
	}
}

func TestLiveSortStartsFrozenWhateverTheEnvironment(t *testing.T) {
	t.Setenv("MOLE_ANALYZE_LIVE_SORT", "continuous")
	m := newModel(t.TempDir(), false)
	if m.liveSortMode != liveSortFreezeOnMove {
		t.Fatalf("live sort mode = %v, want freeze-on-move", m.liveSortMode)
	}
}

func TestLiveScanRejectsOlderSamePathStart(t *testing.T) {
	m := newModel(t.TempDir(), false)
	oldCmd := m.scanCmd(m.path)
	newCmd := m.scanCmd(m.path)
	newer := newCmd().(liveScanStartMsg)
	next, _ := m.Update(newer)
	m = next.(model)
	older := oldCmd().(liveScanStartMsg)
	next, _ = m.Update(older)
	got := next.(model)
	defer got.cancelLiveScan()
	if got.liveScanID != newer.id {
		t.Fatalf("older request replaced newest scan: got=%d newest=%d", got.liveScanID, newer.id)
	}
}

func TestLiveScanRejectsStartAfterCancel(t *testing.T) {
	m := newModel(t.TempDir(), false)
	cmd := m.scanCmd(m.path)
	m.cancelLiveScan()
	start := cmd().(liveScanStartMsg)
	if !errors.Is(start.err, context.Canceled) {
		t.Fatalf("canceled command still enumerated directory: %v", start.err)
	}
	next, wait := m.Update(start)
	got := next.(model)
	defer got.cancelLiveScan()
	if got.liveScanID != 0 || wait != nil {
		t.Fatalf("canceled queued request became active: id=%d", got.liveScanID)
	}
}

func TestLiveScanRejectsDelayedStartedRequest(t *testing.T) {
	m := newModel(t.TempDir(), false)
	oldStart := m.scanCmd(m.path)().(liveScanStartMsg)
	newerCmd := m.scanCmd(m.path)
	newStart := newerCmd().(liveScanStartMsg)
	next, _ := m.Update(newStart)
	m = next.(model)
	next, cmd := m.Update(oldStart)
	got := next.(model)
	defer got.cancelLiveScan()
	if got.liveScanID != newStart.id || cmd != nil {
		t.Fatal("delayed start superseded active request")
	}
}

func TestLiveScanCurrentRequestCompletes(t *testing.T) {
	m := newModel(t.TempDir(), false)
	cmd := m.scanCmd(m.path)
	next, wait := m.Update(cmd())
	m = next.(model)
	if wait == nil {
		t.Fatal("current request did not start event delivery")
	}
	next, _ = m.Update(wait())
	got := next.(model)
	if got.scanning || got.liveScanID != 0 {
		t.Fatalf("empty directory did not complete: scanning=%v id=%d", got.scanning, got.liveScanID)
	}
}
