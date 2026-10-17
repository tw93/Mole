//go:build darwin

package main

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/ansi"
)

func TestDirectoryRefreshKeepsSelectedPathVisible(t *testing.T) {
	for _, live := range []bool{false, true} {
		t.Run(fmt.Sprintf("live=%t", live), func(t *testing.T) {
			home := t.TempDir()
			t.Setenv("HOME", home)
			root := filepath.Join(home, "root")
			if err := os.Mkdir(root, 0o755); err != nil {
				t.Fatal(err)
			}
			const count = 80
			for i := range count {
				child := filepath.Join(root, fmt.Sprintf("entry-%02d", i))
				if err := os.Mkdir(child, 0o755); err != nil {
					t.Fatal(err)
				}
				if err := os.WriteFile(filepath.Join(child, "data"), []byte("data"), 0o644); err != nil {
					t.Fatal(err)
				}
			}
			m := newModel(root, false)
			m.height, m.width = 24, 120
			updated, _ := m.Update(runScanResultCmd(t, m.scanFreshCmd(root)))
			m = updated.(model)
			defer m.cancelBackgroundCacheWrites(nil)
			target := filepath.Join(root, "entry-79")
			if err := os.WriteFile(filepath.Join(target, "data"), []byte(strings.Repeat("x", 8192)), 0o644); err != nil {
				t.Fatal(err)
			}

			if live {
				start := m.scanFreshCmd(root)().(liveScanStartMsg)
				defer cancelAndDrainLiveScan(start)
				updated, _ = m.Update(start)
				m = updated.(model)
				for range count - 1 {
					m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyDown})
				}
				result := drainLiveScanToResultMsg(t, start)
				if result.err != nil {
					t.Fatal(result.err)
				}
				updated, _ = m.Update(liveScanEventMsg{
					id: start.id, path: root, kind: liveScanComplete, result: result.result,
				})
			} else {
				for range count - 1 {
					m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyDown})
				}
				updated, _ = m.Update(runScanResultCmd(t, m.scanFreshCmd(root)))
			}
			m = updated.(model)
			for line := range strings.SplitSeq(ansi.Strip(m.View()), "\n") {
				if strings.Contains(line, "▶") && strings.Contains(line, "entry-79") {
					return
				}
			}
			t.Fatalf("refresh hid or changed the selected path: %s", ansi.Strip(m.View()))
		})
	}
}

func TestDirectoryNavigationExpandsWarmedSummary(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	child := filepath.Join(root, "child")
	if err := os.MkdirAll(child, 0o755); err != nil {
		t.Fatal(err)
	}
	for i := range subdirCacheMinFiles {
		if err := os.WriteFile(filepath.Join(child, fmt.Sprintf("entry-%03d", i)), []byte("data"), 0o644); err != nil {
			t.Fatal(err)
		}
	}
	m := newModel(root, false)
	m.height, m.width = 24, 120
	start := m.scanFreshCmd(root)().(liveScanStartMsg)
	defer cancelAndDrainLiveScan(start)
	defer m.cancelBackgroundCacheWrites(nil)
	updated, _ := m.Update(start)
	m = updated.(model)
	deadline := time.NewTimer(5 * time.Second)
	defer deadline.Stop()
	for m.scanning {
		select {
		case event, ok := <-start.events:
			if !ok {
				t.Fatal("live scan closed without completing")
			}
			updated, _ = m.Update(event)
			m = updated.(model)
		case <-deadline.C:
			t.Fatal("live scan did not complete")
		}
	}
	var cmd tea.Cmd
	m, cmd = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.path != child || !m.scanning || len(m.entries) > maxEntries {
		t.Fatalf("expected the warmed child summary to refresh on entry: %s, %d rows", m.path, len(m.entries))
	}
	updated, _ = m.Update(runScanResultCmd(t, cmd))
	m = updated.(model)
	name := fmt.Sprintf("entry-%03d", subdirCacheMinFiles-1)
	m, _ = filterRune(t, m, '/')
	m = filterType(t, m, name)
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEnter})
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyBackspace})
	if !m.deleteConfirm || m.deleteTarget == nil || m.deleteTarget.Path != filepath.Join(child, name) {
		t.Fatalf("confirmation did not target the selected late entry: %+v", m.deleteTarget)
	}
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEsc}) // Cancel; no deletion is executed.
	m, _ = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEsc}) // Clear the filter.
	m, _ = filterRune(t, m, 'b')
	if m.path != root || len(m.entries) != 1 {
		t.Fatalf("back navigation lost the parent: %s", m.path)
	}
	m, cmd = filterKey(t, m, tea.KeyMsg{Type: tea.KeyEnter})
	if m.path != child || len(m.entries) != subdirCacheMinFiles || m.scanning || cmd != nil {
		t.Fatalf("in-memory revisit lost the complete child listing: %s, %d rows", m.path, len(m.entries))
	}
}

func BenchmarkDirectoryBrowsing(b *testing.B) {
	m := model{path: "/fixture", width: 120, height: 24}
	for i := range 10000 {
		m.entriesAll = append(m.entriesAll, dirEntry{
			Name: fmt.Sprintf("entry-%05d", i),
			Path: fmt.Sprintf("/fixture/entry-%05d", i),
			Size: 1,
		})
	}
	m.entries = m.entriesAll
	m.totalSize = int64(len(m.entries))
	b.Run("render", func(b *testing.B) {
		b.ReportAllocs()
		for b.Loop() {
			_ = m.View()
		}
	})
	b.Run("filter_last", func(b *testing.B) {
		m.entryFilter = "entry-09999"
		b.ReportAllocs()
		for b.Loop() {
			m.applyEntryFilter()
			_ = m.View()
		}
	})
}

func TestCompletedListingCacheDuringDeletion(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	root := filepath.Join(home, "root")
	if err := os.Mkdir(root, 0o755); err != nil {
		t.Fatal(err)
	}
	entries := make([]dirEntry, 10000)
	for i := range entries {
		name := fmt.Sprintf("entry-%05d", i)
		entries[i] = dirEntry{Name: name, Path: filepath.Join(root, name), Size: 1}
	}
	for range 100 {
		m := newModel(root, false)
		m.finishLiveScan(scanResult{Entries: entries, TotalSize: int64(len(entries)), TotalFiles: int64(len(entries))})
		updated, _ := m.Update(deleteProgressMsg{done: true, count: 1, path: entries[0].Path})
		m = updated.(model)
		m.cancelBackgroundCacheWrites(nil)
		if len(m.entries) != len(entries)-1 || m.entries[0].Path == entries[0].Path {
			t.Fatal("deletion completion did not remove the row from the view")
		}
		if _, err := loadCacheFromDisk(root); !os.IsNotExist(err) {
			t.Fatalf("deleted listing's cache survived invalidation: %v", err)
		}
	}
}

func TestDirectoryRowsStayAlignedBeyondTwoDigitIndexes(t *testing.T) {
	m := model{path: "/fixture", width: 120, height: 8, selected: -1, totalSize: 10000}
	for i := range 10000 {
		name := fmt.Sprintf("entry-%05d", i)
		m.entries = append(m.entries, dirEntry{Name: name, Path: "/fixture/" + name, Size: 1})
	}
	for _, withHints := range []bool{false, true} {
		if withHints {
			for i := range m.entries {
				m.entries[i].LastAccess = time.Now().Add(-120 * 24 * time.Hour)
			}
		}
		for _, width := range []int{80, 120, 140} {
			m.width = width
			short := m
			short.entries = m.entries[:2]
			short.offset = 0
			rowWidth := ansi.StringWidth(rowContaining(ansi.Strip(short.View()), short.entries[0].Name))
			for _, offset := range []int{98, 998, 9998} {
				m.offset = offset
				view := ansi.Strip(m.View())
				first := rowContaining(view, m.entries[offset].Name)
				second := rowContaining(view, m.entries[offset+1].Name)
				firstPrefix, _, firstOK := strings.Cut(first, "  |  ")
				secondPrefix, _, secondOK := strings.Cut(second, "  |  ")
				if !firstOK || !secondOK || ansi.StringWidth(firstPrefix) != ansi.StringWidth(secondPrefix) {
					t.Fatalf("row numbers shifted the columns at %d:\n%s\n%s", offset+1, first, second)
				}
				if ansi.StringWidth(first) > rowWidth || ansi.StringWidth(second) > rowWidth {
					t.Fatalf("row numbers widened the rows at %d:\n%s\n%s", offset+1, first, second)
				}
			}
		}
	}
}
