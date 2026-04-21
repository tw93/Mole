//go:build darwin

package main

import (
	"sync/atomic"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestDeleteProgressMsgDoesNotTriggerRescan(t *testing.T) {
	childPath := "/tmp/mole-incremental-delete/child"
	parentPath := "/tmp/mole-incremental-delete"

	var filesScanned, dirsScanned, bytesScanned int64
	m := model{
		path: parentPath,
		entries: []dirEntry{
			{Path: childPath, Size: 2_000_000, IsDir: true},
			{Path: parentPath + "/other", Size: 500_000, IsDir: true},
		},
		totalSize:          2_500_000,
		totalFiles:         42,
		cache:              map[string]historyEntry{},
		multiSelected:      map[string]bool{},
		largeMultiSelected: map[string]bool{},
		filesScanned:       &filesScanned,
		dirsScanned:        &dirsScanned,
		bytesScanned:       &bytesScanned,
	}

	msg := deleteProgressMsg{
		done:  true,
		count: 5,
		path:  childPath,
		paths: []string{childPath},
	}

	updated, cmd := m.Update(msg)
	got, ok := updated.(model)
	if !ok {
		t.Fatalf("unexpected model type: %T", updated)
	}

	if got.scanning {
		t.Errorf("delete triggered a rescan (scanning=true); expected incremental update")
	}
	// A persist command may be returned to write the updated cache off the
	// UI thread; it must not produce a follow-up message (no rescan/tick).
	if cmd != nil {
		if followup := cmd(); followup != nil {
			t.Errorf("delete's follow-up cmd should be fire-and-forget, got %T", followup)
		}
	}

	if len(got.entries) != 1 || got.entries[0].Path != parentPath+"/other" {
		t.Errorf("entries not pruned after delete: %+v", got.entries)
	}
	if got.totalSize != 500_000 {
		t.Errorf("totalSize not decremented: got %d, want 500000", got.totalSize)
	}
	if got.status == "" {
		t.Errorf("status should report deletion count")
	}
}

func TestDeleteProgressMsgMultiPathSubtractsAll(t *testing.T) {
	a := "/tmp/mole-multi-delete/a"
	b := "/tmp/mole-multi-delete/b"

	var filesScanned, dirsScanned, bytesScanned int64
	m := model{
		path: "/tmp/mole-multi-delete",
		entries: []dirEntry{
			{Path: a, Size: 1_000_000, IsDir: true},
			{Path: b, Size: 2_000_000, IsDir: true},
			{Path: "/tmp/mole-multi-delete/keep", Size: 300_000, IsDir: true},
		},
		totalSize:          3_300_000,
		cache:              map[string]historyEntry{},
		multiSelected:      map[string]bool{a: true, b: true},
		largeMultiSelected: map[string]bool{},
		filesScanned:       &filesScanned,
		dirsScanned:        &dirsScanned,
		bytesScanned:       &bytesScanned,
	}

	msg := deleteProgressMsg{
		done:  true,
		count: 7,
		path:  "",
		paths: []string{a, b},
	}

	updated, _ := m.Update(msg)
	got := updated.(model)

	if got.scanning {
		t.Errorf("multi-delete triggered a rescan; expected incremental update")
	}
	if len(got.entries) != 1 {
		t.Fatalf("expected 1 entry after multi-delete, got %d: %+v", len(got.entries), got.entries)
	}
	if got.totalSize != 300_000 {
		t.Errorf("totalSize after multi-delete: got %d, want 300000", got.totalSize)
	}
	if len(got.multiSelected) != 0 {
		t.Errorf("multiSelected not cleared: %+v", got.multiSelected)
	}
}

func TestSubtractFromAncestorsUpdatesHistoryAndCache(t *testing.T) {
	deleted := "/Users/me/Library/Caches/big"
	size := int64(5_000_000)

	m := model{
		history: []historyEntry{
			{
				Path: "/Users/me/Library",
				Entries: []dirEntry{
					{Path: "/Users/me/Library/Caches", Size: 8_000_000, IsDir: true},
					{Path: "/Users/me/Library/Other", Size: 1_000_000, IsDir: true},
				},
				TotalSize: 9_000_000,
			},
			{
				Path: "/Users/other",
				Entries: []dirEntry{
					{Path: "/Users/other/x", Size: 100, IsDir: true},
				},
				TotalSize: 100,
			},
		},
		cache: map[string]historyEntry{
			"/Users/me/Library/Caches": {
				Path: "/Users/me/Library/Caches",
				Entries: []dirEntry{
					{Path: deleted, Size: size, IsDir: true},
				},
				TotalSize: size,
			},
		},
	}

	m.subtractFromAncestors(deleted, size)

	libHistory := m.history[0]
	if libHistory.TotalSize != 4_000_000 {
		t.Errorf("history TotalSize: got %d, want 4000000", libHistory.TotalSize)
	}
	if !libHistory.NeedsRefresh {
		t.Errorf("history ancestor should be flagged NeedsRefresh")
	}
	// The top-level Caches entry shrank from 8MB to 3MB.
	var cachesSize int64
	for _, e := range libHistory.Entries {
		if e.Path == "/Users/me/Library/Caches" {
			cachesSize = e.Size
		}
	}
	if cachesSize != 3_000_000 {
		t.Errorf("top-level Caches entry size: got %d, want 3000000", cachesSize)
	}

	otherHistory := m.history[1]
	if otherHistory.TotalSize != 100 || otherHistory.NeedsRefresh {
		t.Errorf("unrelated ancestor should be untouched: %+v", otherHistory)
	}

	cached := m.cache["/Users/me/Library/Caches"]
	if cached.TotalSize != 0 {
		t.Errorf("cache TotalSize after full delete: got %d, want 0", cached.TotalSize)
	}
	if !cached.NeedsRefresh {
		t.Errorf("cache ancestor should be flagged NeedsRefresh")
	}
	if len(cached.Entries) != 0 {
		t.Errorf("cache should have dropped the deleted entry, got: %+v", cached.Entries)
	}
}

func TestIsAncestorOf(t *testing.T) {
	cases := []struct {
		ancestor, child string
		want            bool
	}{
		{"/a", "/a/b", true},
		{"/a", "/a", false},
		{"/a", "/ab", false},
		{"/", "/a", true},
		{"/", "", false},
		{"", "/a", false},
		{"/a/b", "/a/b/c/d", true},
	}
	for _, c := range cases {
		if got := isAncestorOf(c.ancestor, c.child); got != c.want {
			t.Errorf("isAncestorOf(%q, %q) = %v, want %v", c.ancestor, c.child, got, c.want)
		}
	}
}

func TestDeleteProgressMsgErrorDoesNotMutate(t *testing.T) {
	entries := []dirEntry{{Path: "/x/y", Size: 100, IsDir: true}}
	var filesScanned, dirsScanned, bytesScanned int64

	m := model{
		path:               "/x",
		entries:            entries,
		totalSize:          100,
		cache:              map[string]historyEntry{},
		multiSelected:      map[string]bool{"/x/y": true},
		largeMultiSelected: map[string]bool{},
		filesScanned:       &filesScanned,
		dirsScanned:        &dirsScanned,
		bytesScanned:       &bytesScanned,
	}

	msg := deleteProgressMsg{done: true, err: errBoom{}, path: "/x/y"}
	updated, _ := m.Update(msg)
	got := updated.(model)

	if got.totalSize != 100 {
		t.Errorf("totalSize mutated on error: got %d", got.totalSize)
	}
	if len(got.entries) != 1 {
		t.Errorf("entries mutated on error: %+v", got.entries)
	}
	if got.status == "" {
		t.Errorf("status should describe the failure")
	}

	// Unused vars to satisfy atomic import-like presence.
	_ = atomic.LoadInt64(&filesScanned)
	_ = tea.Batch
}

type errBoom struct{}

func (errBoom) Error() string { return "boom" }
