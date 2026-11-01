package main

import (
	"path/filepath"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestDeletingIgnoresHiddenActions(t *testing.T) {
	keys := []tea.KeyMsg{
		{Type: tea.KeyDown}, {Type: tea.KeyDelete}, {Type: tea.KeyBackspace},
		{Type: tea.KeyEnter}, {Type: tea.KeyEsc},
		{Type: tea.KeyRunes, Runes: []rune(" ")},
	}
	for _, key := range keys {
		t.Run(key.String(), func(t *testing.T) {
			m := newModel(t.TempDir(), false)
			m.scanning = false
			m.deleting = true
			m.entries = []dirEntry{
				{Name: "first", Path: filepath.Join(m.path, "first"), Size: 1, IsDir: true},
				{Name: "second", Path: filepath.Join(m.path, "second"), Size: 2},
			}
			next, cmd := m.Update(key)
			got := next.(model)
			if cmd != nil || got.path != m.path || got.selected != m.selected || got.deleteConfirm || len(got.multiSelected) != 0 || got.scanning {
				t.Fatalf("busy input changed state: key=%s path=%s selected=%d confirm=%v scanning=%v cmd=%v", key.String(), got.path, got.selected, got.deleteConfirm, got.scanning, cmd != nil)
			}
		})
	}
}

func TestDeletingCannotDispatchHiddenConfirmation(t *testing.T) {
	for _, busy := range []bool{false, true} {
		t.Run(map[bool]string{false: "idle", true: "deleting"}[busy], func(t *testing.T) {
			m := newModel(t.TempDir(), false)
			m.scanning = false
			m.deleting = busy
			m.entries = []dirEntry{
				{Name: "first", Path: filepath.Join(m.path, "first"), Size: 1},
				{Name: "second", Path: filepath.Join(m.path, "second"), Size: 2},
			}
			for _, key := range []tea.KeyMsg{{Type: tea.KeyDown}, {Type: tea.KeyBackspace}, {Type: tea.KeyEnter}} {
				next, cmd := m.Update(key)
				m = next.(model)
				if key.Type == tea.KeyEnter && (cmd != nil) == busy {
					t.Fatalf("delete dispatch while busy=%v: cmd=%v", busy, cmd != nil)
				}
				// Never run the returned command: this test checks dispatch only.
			}
		})
	}
}

func TestDeletingKeepsQuitKeys(t *testing.T) {
	for _, key := range []tea.KeyMsg{
		{Type: tea.KeyRunes, Runes: []rune("q")},
		{Type: tea.KeyRunes, Runes: []rune("Q")},
		{Type: tea.KeyCtrlC},
	} {
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
