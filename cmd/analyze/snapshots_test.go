//go:build darwin

package main

import (
	"context"
	"errors"
	"reflect"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func TestParseLocalSnapshotCount(t *testing.T) {
	tests := []struct {
		name   string
		output string
		want   int
	}{
		{
			name: "counts Time Machine snapshot names",
			output: `Snapshots for disk /:
com.apple.TimeMachine.2026-08-26-091500.local
com.apple.TimeMachine.2026-08-26-101500.local
`,
			want: 2,
		},
		{
			name: "counts snapshots other backup apps leave without Time Machine (#1916)",
			output: `Snapshots for disk /:
com.synology.activebackup.F0yvGv9C
com.bombich.ccc.6F2A7C1E-1D3B-4C55-9A0B-2E8F1C7D4B10
com.apple.TimeMachine.2026-08-26-091500.local
`,
			want: 3,
		},
		{
			name:   "ignores a localized heading with no snapshots",
			output: "本地快照：\n",
			want:   0,
		},
		{
			name: "ignores Apple update snapshots and malformed lines",
			output: `Snapshots for disk /:
com.apple.os.update-MSUPrepareUpdate
com.apple.TimeMachine.2026-99-99
not a snapshot name
`,
			want: 0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseLocalSnapshotCount([]byte(tt.output))
			if got != tt.want {
				t.Fatalf("parseLocalSnapshotCount() = %d, want %d", got, tt.want)
			}
		})
	}
}

func TestLocalSnapshotProbeUsesBoundedReadOnlyTMUtilQuery(t *testing.T) {
	var gotName string
	var gotArgs []string
	runner := func(ctx context.Context, name string, args ...string) ([]byte, error) {
		gotName = name
		gotArgs = append([]string(nil), args...)
		deadline, ok := ctx.Deadline()
		if !ok || time.Until(deadline) <= 0 || time.Until(deadline) > localSnapshotProbeTimeout {
			t.Fatalf("snapshot probe context deadline = %v, want a live %s budget", deadline, localSnapshotProbeTimeout)
		}
		return []byte("Snapshots for disk /:\ncom.apple.TimeMachine.2026-08-26-091500.local\ncom.synology.activebackup.F0yvGv9C\n"), nil
	}

	msg := localSnapshotProbeCmd(runner, 0)().(localSnapshotMsg)
	if msg.err != nil || msg.count != 2 {
		t.Fatalf("snapshot probe result = %#v, want count 2", msg)
	}
	if gotName != "/usr/bin/tmutil" {
		t.Fatalf("snapshot probe command = %q, want /usr/bin/tmutil", gotName)
	}
	wantArgs := []string{"listlocalsnapshots", "/"}
	if !reflect.DeepEqual(gotArgs, wantArgs) {
		t.Fatalf("snapshot probe args = %#v, want %#v", gotArgs, wantArgs)
	}
}

func TestLocalSnapshotProbeReportsCommandFailure(t *testing.T) {
	wantErr := errors.New("tmutil unavailable")
	msg := localSnapshotProbeCmd(func(context.Context, string, ...string) ([]byte, error) {
		return nil, wantErr
	}, 0)().(localSnapshotMsg)
	if !errors.Is(msg.err, wantErr) || msg.count != 0 {
		t.Fatalf("snapshot probe result = %#v, want command error", msg)
	}
}

func TestOverviewStoresSuccessfulLocalSnapshotCount(t *testing.T) {
	m := model{path: "/", isOverview: true}
	updated, cmd := m.Update(localSnapshotMsg{count: 3})
	if cmd != nil {
		t.Fatalf("snapshot update command = %v, want nil", cmd)
	}
	got := updated.(model)
	if got.localSnapshotCount != 3 {
		t.Fatalf("snapshot count = %d, want 3", got.localSnapshotCount)
	}
	if !got.localSnapshotFresh {
		t.Fatal("successful snapshot probe was not marked fresh")
	}

	updated, _ = got.Update(localSnapshotMsg{count: 9, err: errors.New("bad output")})
	failed := updated.(model)
	if failed.localSnapshotCount != 3 {
		t.Fatalf("failed refresh changed snapshot count to %d, want 3", failed.localSnapshotCount)
	}
	if failed.localSnapshotFresh {
		t.Fatal("failed refresh left the previous snapshot count marked fresh")
	}
}

func TestOverviewRefreshReprobesLocalSnapshots(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	m := newModel("/", true)
	m.snapshotRunner = func(context.Context, string, ...string) ([]byte, error) {
		return []byte("Snapshots for disk /:\n"), nil
	}
	m.localSnapshotCount = 4
	firstUpdated, firstCmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'R'}})
	first := firstUpdated.(model)
	firstMsg := localSnapshotMsgFromBatch(t, firstCmd)

	secondUpdated, secondCmd := first.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'R'}})
	second := secondUpdated.(model)
	secondMsg := localSnapshotMsgFromBatch(t, secondCmd)
	if firstMsg.probeID == secondMsg.probeID {
		t.Fatalf("consecutive refreshes reused snapshot probe ID %d", firstMsg.probeID)
	}

	staleUpdated, _ := second.Update(firstMsg)
	stale := staleUpdated.(model)
	if stale.localSnapshotCount != 4 {
		t.Fatalf("stale probe changed snapshot count to %d, want 4", stale.localSnapshotCount)
	}

	currentUpdated, _ := stale.Update(secondMsg)
	if got := currentUpdated.(model).localSnapshotCount; got != 0 {
		t.Fatalf("current successful zero-count refresh left snapshot count at %d", got)
	}
}

func TestOverviewRefreshResultSurvivesDrillDown(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	m := newModel("/", true)
	m.snapshotRunner = func(context.Context, string, ...string) ([]byte, error) {
		return []byte("Snapshots for disk /:\n"), nil
	}
	m.localSnapshotCount = 4
	refreshedModel, refreshCmd := m.Update(tea.KeyMsg{Type: tea.KeyRunes, Runes: []rune{'R'}})
	refreshed := refreshedModel.(model)
	refreshMsg := localSnapshotMsgFromBatch(t, refreshCmd)

	refreshed.entries = []dirEntry{{Name: "child", Path: t.TempDir(), Size: 1, IsDir: true}}
	drilledModel, _ := refreshed.Update(tea.KeyMsg{Type: tea.KeyEnter})
	drilled := drilledModel.(model)
	if drilled.inOverviewMode() {
		t.Fatal("enter key left model in overview mode")
	}

	updatedModel, _ := drilled.Update(refreshMsg)
	backModel, _ := updatedModel.(model).Update(tea.KeyMsg{Type: tea.KeyEsc})
	if got := backModel.(model).localSnapshotCount; got != 0 {
		t.Fatalf("refresh completed during drill-down left snapshot count at %d", got)
	}
}

func TestEnteringOverviewProbesLocalSnapshots(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	m := newModel(t.TempDir(), false)
	m.snapshotRunner = func(context.Context, string, ...string) ([]byte, error) {
		return []byte("Snapshots for disk /:\ncom.apple.TimeMachine.2026-08-27-101500.local\n"), nil
	}

	overviewModel, overviewCmd := m.Update(tea.KeyMsg{Type: tea.KeyEsc})
	overview := overviewModel.(model)
	if !overview.inOverviewMode() {
		t.Fatal("escape key did not enter overview mode")
	}

	msg := localSnapshotMsgFromBatch(t, overviewCmd)
	updatedModel, _ := overview.Update(msg)
	if got := updatedModel.(model).localSnapshotCount; got != 1 {
		t.Fatalf("entering overview stored snapshot count %d, want 1", got)
	}
}

func TestSwitchingToOverviewAdvancesSnapshotProbeGeneration(t *testing.T) {
	t.Setenv("HOME", t.TempDir())

	m := newModel(t.TempDir(), false)
	m.snapshotRunner = func(context.Context, string, ...string) ([]byte, error) {
		return []byte("Snapshots for disk /:\ncom.apple.TimeMachine.2026-08-29-101500.local\n"), nil
	}
	firstMsg := localSnapshotMsgFromBatch(t, m.switchToOverviewMode())
	m.isOverview = false
	m.path = t.TempDir()
	secondMsg := localSnapshotMsgFromBatch(t, m.switchToOverviewMode())

	if firstMsg.probeID == secondMsg.probeID {
		t.Fatalf("switching to overview reused snapshot probe ID %d", secondMsg.probeID)
	}
	staleModel, _ := m.Update(localSnapshotMsg{probeID: firstMsg.probeID, count: 9})
	if got := staleModel.(model).localSnapshotCount; got != 0 {
		t.Fatalf("older overview probe changed snapshot count to %d, want 0", got)
	}
	currentModel, _ := staleModel.(model).Update(localSnapshotMsg{probeID: secondMsg.probeID, count: 1})
	if got := currentModel.(model).localSnapshotCount; got != 1 {
		t.Fatalf("current overview probe stored snapshot count %d, want 1", got)
	}
}

func localSnapshotMsgFromBatch(t *testing.T, cmd tea.Cmd) localSnapshotMsg {
	t.Helper()
	if cmd == nil {
		t.Fatalf("overview refresh command = nil, want a command batch")
	}
	msg := cmd()
	if snapshotMsg, ok := msg.(localSnapshotMsg); ok {
		return snapshotMsg
	}
	batch, ok := msg.(tea.BatchMsg)
	if !ok {
		t.Fatalf("overview refresh command returned %T, want tea.BatchMsg", msg)
	}
	for _, batchCmd := range batch {
		if batchCmd == nil {
			continue
		}
		if msg, ok := batchCmd().(localSnapshotMsg); ok {
			return msg
		}
	}
	t.Fatalf("overview refresh batch did not re-probe local snapshots")
	return localSnapshotMsg{}
}

func TestOverviewViewExplainsLocalSnapshotOnlySpace(t *testing.T) {
	m := model{
		path:               "/",
		isOverview:         true,
		localSnapshotCount: 2,
		localSnapshotFresh: true,
		entries:            []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	view := m.View()
	for _, want := range []string{"2 local snapshots", "snapshot-only space is not listed below"} {
		if !strings.Contains(view, want) {
			t.Fatalf("expected overview snapshot notice %q, got:\n%s", want, view)
		}
	}
}

func TestOverviewViewUsesSingularSnapshotLabel(t *testing.T) {
	m := model{
		path:               "/",
		isOverview:         true,
		localSnapshotCount: 1,
		localSnapshotFresh: true,
		entries:            []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	view := m.View()
	if !strings.Contains(view, "1 local snapshot") || strings.Contains(view, "1 local snapshots") {
		t.Fatalf("expected singular snapshot notice, got:\n%s", view)
	}
}

func TestOverviewViewMarksSnapshotCountStaleAfterProbeFailure(t *testing.T) {
	m := model{
		path:               "/",
		isOverview:         true,
		localSnapshotCount: 2,
		localSnapshotFresh: false,
		entries:            []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	if view := m.View(); !strings.Contains(view, "last successful check") {
		t.Fatalf("expected stale snapshot notice, got:\n%s", view)
	}
}

func TestOverviewViewOmitsSnapshotNoticeWhenNoneDetected(t *testing.T) {
	m := model{
		path:       "/",
		isOverview: true,
		entries:    []dirEntry{{Name: "Home", Path: "/tmp/home", Size: 1, IsDir: true}},
	}

	if view := m.View(); strings.Contains(view, "local snapshot") {
		t.Fatalf("expected no snapshot notice, got:\n%s", view)
	}
}
