//go:build darwin

package main

import (
	"context"
	"os/exec"
	"regexp"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

const localSnapshotProbeTimeout = 3 * time.Second

type localSnapshotMsg struct {
	probeID int64
	count   int
	err     error
}

type localSnapshotCommandRunner func(context.Context, string, ...string) ([]byte, error)

func runLocalSnapshotCommand(ctx context.Context, name string, args ...string) ([]byte, error) {
	return exec.CommandContext(ctx, name, args...).Output()
}

func (m model) detectLocalSnapshotsCmd() tea.Cmd {
	run := m.snapshotRunner
	if run == nil {
		run = runLocalSnapshotCommand
	}
	return localSnapshotProbeCmd(run, m.snapshotProbeID)
}

func localSnapshotProbeCmd(run localSnapshotCommandRunner, probeID int64) tea.Cmd {
	return func() tea.Msg {
		ctx, cancel := context.WithTimeout(context.Background(), localSnapshotProbeTimeout)
		defer cancel()

		output, err := run(ctx, "/usr/bin/tmutil", "listlocalsnapshots", "/")
		if err != nil {
			return localSnapshotMsg{probeID: probeID, err: err}
		}

		return localSnapshotMsg{probeID: probeID, count: parseLocalSnapshotCount(output)}
	}
}

var (
	localSnapshotNamePattern = regexp.MustCompile(`^[A-Za-z0-9_-]+(\.[A-Za-z0-9_-]+)+$`)
	timeMachineSnapshotName  = regexp.MustCompile(`^com\.apple\.TimeMachine\.[0-9]{4}-[0-9]{2}-[0-9]{2}-[0-9]{6}`)
)

// parseLocalSnapshotCount counts the snapshot names `tmutil listlocalsnapshots`
// prints: Time Machine ones and those other backup apps (Synology Active
// Backup, Carbon Copy Cloner) leave on the data volume, which pin deleted
// files the same way (#1916). The localized heading holds spaces or a colon,
// so only bare reverse-DNS names count, and Apple's other com.apple.* names
// (software update prep) stay out, the same name rule mole_local_snapshot_rows
// in lib/clean/snapshots.sh uses; unlike `mo clean`, the count here does not
// depend on Time Machine being configured or idle. Sizes are intentionally not inferred because tmutil
// does not expose retained bytes.
func parseLocalSnapshotCount(data []byte) int {
	count := 0
	for line := range strings.SplitSeq(string(data), "\n") {
		name := strings.TrimSpace(line)
		if !localSnapshotNamePattern.MatchString(name) {
			continue
		}
		if timeMachineSnapshotName.MatchString(name) || !strings.HasPrefix(name, "com.apple.") {
			count++
		}
	}
	return count
}
