package main

import (
	"fmt"
	"sort"
	"syscall"
	"time"
)

type ProcessWatchOptions struct {
	Enabled      bool
	CPUThreshold float64
	Window       time.Duration
}

type ProcessWatchConfig struct {
	Enabled      bool    `json:"enabled"`
	CPUThreshold float64 `json:"cpu_threshold"`
	Window       string  `json:"window"`
}

type ProcessAlert struct {
	PID         int       `json:"pid"`
	Name        string    `json:"name"`
	Command     string    `json:"command,omitempty"`
	CPU         float64   `json:"cpu"`
	Threshold   float64   `json:"threshold"`
	Window      string    `json:"window"`
	TriggeredAt time.Time `json:"triggered_at,omitempty"`
	Status      string    `json:"status"`
}

type trackedProcess struct {
	info        ProcessInfo
	firstAbove  time.Time
	triggeredAt time.Time
	currentAbove bool
	ignored     bool
}

type ProcessWatcher struct {
	options ProcessWatchOptions
	tracks  map[int]*trackedProcess
}

func NewProcessWatcher(options ProcessWatchOptions) *ProcessWatcher {
	return &ProcessWatcher{
		options: options,
		tracks:  make(map[int]*trackedProcess),
	}
}

func (o ProcessWatchOptions) SnapshotConfig() ProcessWatchConfig {
	return ProcessWatchConfig{
		Enabled:      o.Enabled,
		CPUThreshold: o.CPUThreshold,
		Window:       o.Window.String(),
	}
}

func (w *ProcessWatcher) Update(now time.Time, processes []ProcessInfo) []ProcessAlert {
	if w == nil || !w.options.Enabled {
		return nil
	}

	seen := make(map[int]bool, len(processes))
	for _, proc := range processes {
		if proc.PID <= 0 {
			continue
		}
		seen[proc.PID] = true

		track, ok := w.tracks[proc.PID]
		if !ok {
			track = &trackedProcess{}
			w.tracks[proc.PID] = track
		}

		track.info = proc
		track.currentAbove = proc.CPU >= w.options.CPUThreshold

		if track.currentAbove {
			if track.firstAbove.IsZero() {
				track.firstAbove = now
			}
			if !track.ignored && now.Sub(track.firstAbove) >= w.options.Window && track.triggeredAt.IsZero() {
				track.triggeredAt = now
			}
			continue
		}

		track.firstAbove = time.Time{}
		track.triggeredAt = time.Time{}
	}

	for pid := range w.tracks {
		if !seen[pid] {
			delete(w.tracks, pid)
		}
	}

	return w.Snapshot()
}

func (w *ProcessWatcher) Ignore(pid int) bool {
	if w == nil || !w.options.Enabled {
		return false
	}
	track, ok := w.tracks[pid]
	if !ok {
		return false
	}
	track.ignored = true
	if track.triggeredAt.IsZero() {
		track.triggeredAt = time.Now()
	}
	return true
}

func (w *ProcessWatcher) Snapshot() []ProcessAlert {
	if w == nil || !w.options.Enabled {
		return nil
	}

	alerts := make([]ProcessAlert, 0, len(w.tracks))
	for pid, track := range w.tracks {
		if !track.currentAbove {
			continue
		}

		status := ""
		switch {
		case track.ignored:
			status = "ignored"
		case !track.triggeredAt.IsZero():
			status = "active"
		}
		if status == "" {
			continue
		}

		triggeredAt := track.triggeredAt
		if triggeredAt.IsZero() {
			triggeredAt = track.firstAbove
		}

		alerts = append(alerts, ProcessAlert{
			PID:         pid,
			Name:        track.info.Name,
			Command:     track.info.Command,
			CPU:         track.info.CPU,
			Threshold:   w.options.CPUThreshold,
			Window:      w.options.Window.String(),
			TriggeredAt: triggeredAt,
			Status:      status,
		})
	}

	sort.Slice(alerts, func(i, j int) bool {
		if alerts[i].Status != alerts[j].Status {
			return alerts[i].Status == "active"
		}
		if !alerts[i].TriggeredAt.Equal(alerts[j].TriggeredAt) {
			return alerts[i].TriggeredAt.Before(alerts[j].TriggeredAt)
		}
		if alerts[i].CPU != alerts[j].CPU {
			return alerts[i].CPU > alerts[j].CPU
		}
		return alerts[i].PID < alerts[j].PID
	})

	return alerts
}

var syscallKill = syscall.Kill

func terminateProcess(pid int) error {
	if pid <= 0 {
		return fmt.Errorf("invalid pid %d", pid)
	}
	if err := syscallKill(pid, syscall.SIGTERM); err != nil {
		return fmt.Errorf("send SIGTERM to pid %d: %w", pid, err)
	}
	return nil
}
