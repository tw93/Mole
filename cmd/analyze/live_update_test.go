package main

import (
	"fmt"
	"path/filepath"
	"testing"
	"time"
)

func liveUpdateFixture(n int) model {
	m := model{path: "/fixture", width: 120, height: 24, scanning: true, autoSortLiveEntries: true, liveSortMode: liveSortFreezeOnMove}
	m.cache = make(map[string]historyEntry)
	for i := range n {
		name := fmt.Sprintf("child-%05d", i)
		m.entriesAll = append(m.entriesAll, dirEntry{Name: name, Path: filepath.Join(m.path, name), Size: -1, IsDir: true})
	}
	m.entries = m.entriesAll
	return m
}

func TestLiveUpdatesSortOnceAtTick(t *testing.T) {
	m := liveUpdateFixture(3)
	first, second, last := m.entriesAll[0], m.entriesAll[1], m.entriesAll[2]
	last.Size = 30
	m.applyLiveChildProgress(last)
	last.Size = 40
	m.applyLiveChildUpdate(last, scanResult{})
	second.Size = 20
	m.applyLiveChildUpdate(second, scanResult{})
	if m.entries[0].Path != first.Path {
		t.Fatal("an individual child event reordered the view before the display tick")
	}
	if m.totalSize != 60 {
		t.Fatalf("progress and completion counted bytes twice: %d", m.totalSize)
	}
	next, _ := m.Update(tickMsg(time.Now()))
	m = next.(model)
	if m.entries[0].Path != last.Path || m.entries[1].Path != second.Path || m.entries[0].Size != 40 {
		t.Fatalf("tick did not publish the latest sorted rows: %+v", m.entries)
	}
	// The next event must address the same path after sorting changed row indexes.
	first.Size = 80
	m.applyLiveChildUpdate(first, scanResult{})
	next, _ = m.Update(tickMsg(time.Now()))
	m = next.(model)
	if m.entries[0].Path != first.Path || m.totalSize != 140 {
		t.Fatalf("post-sort update changed the wrong row: %+v, total=%d", m.entries, m.totalSize)
	}
}

func TestLiveUpdateTickKeepsFilteredSelection(t *testing.T) {
	for _, continuous := range []bool{false, true} {
		t.Run(fmt.Sprintf("continuous=%t", continuous), func(t *testing.T) {
			m := liveUpdateFixture(3)
			m.entryFilter = "child-0000"
			m.applyEntryFilter()
			m.selected = 1
			selected := m.selectedEntryPath()
			m.autoSortLiveEntries = continuous
			m.liveSortMode = liveSortContinuous
			entry := m.entriesAll[2]
			entry.Size = 99
			m.applyLiveChildUpdate(entry, scanResult{})
			next, _ := m.Update(tickMsg(time.Now()))
			m = next.(model)
			if m.selectedEntryPath() != selected {
				t.Fatalf("tick moved the filtered cursor from %s to %s", selected, m.selectedEntryPath())
			}
			found := false
			for _, got := range m.entries {
				if got.Path == entry.Path && got.Size == 99 {
					found = true
				}
			}
			if !found {
				t.Fatal("filtered progress did not refresh at the tick")
			}
		})
	}
}

func BenchmarkLiveChildUpdates(b *testing.B) {
	for _, n := range []int{1000, 5000, 10000} {
		b.Run(fmt.Sprint(n), func(b *testing.B) {
			for b.Loop() {
				b.StopTimer()
				m := liveUpdateFixture(n)
				entries := append([]dirEntry(nil), m.entriesAll...)
				b.StartTimer()
				for _, entry := range entries {
					entry.Size = 1
					m.applyLiveChildUpdate(entry, scanResult{})
				}
				m.Update(tickMsg(time.Now()))
			}
		})
	}
}
