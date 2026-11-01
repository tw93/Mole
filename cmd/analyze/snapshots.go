package main

import (
	"context"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const localSnapshotProbeTimeout = 3 * time.Second

type localSnapshotMsg struct {
	probeID int64
	count   int
	err     error
}

// localSnapshotCounter counts filesystem snapshots without running a tool.
type localSnapshotCounter func(context.Context) (int, error)

// snapshotStores are the places snapper and Timeshift keep read-only
// snapshots. Each snapshot is one numbered (snapper) or dated (Timeshift)
// directory below the store; the stores are counted, never scanned.
var snapshotStores = []string{
	"/.snapshots",
	"/timeshift/snapshots",
	"/run/timeshift/backup/timeshift/snapshots",
}

func countSnapshotsIn(ctx context.Context, stores []string) (int, error) {
	count := 0
	var firstErr error
	for _, store := range stores {
		if err := ctx.Err(); err != nil {
			return 0, err
		}
		entries, err := os.ReadDir(store)
		if err != nil {
			if !os.IsNotExist(err) && firstErr == nil {
				firstErr = err
			}
			continue
		}
		for _, entry := range entries {
			if entry.IsDir() {
				count++
			}
		}
	}
	if count == 0 && firstErr != nil {
		return 0, firstErr
	}
	return count, nil
}

func runLocalSnapshotCount(ctx context.Context) (int, error) {
	return countSnapshotsIn(ctx, snapshotStores)
}

func (m model) detectLocalSnapshotsCmd() tea.Cmd {
	count := m.snapshotRunner
	if count == nil {
		count = runLocalSnapshotCount
	}
	return localSnapshotProbeCmd(count, m.snapshotProbeID)
}

func localSnapshotProbeCmd(count localSnapshotCounter, probeID int64) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), localSnapshotProbeTimeout)
		defer cancel()

		n, err := count(ctx)
		if err != nil {
			return localSnapshotMsg{probeID: probeID, err: err}
		}
		return localSnapshotMsg{probeID: probeID, count: n}
	}
}
