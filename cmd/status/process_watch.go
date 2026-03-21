package main

import (
	"sort"
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
	TriggeredAt time.Time `json:"triggered_at"`
	Status      string    `json:"status"`
}

type trackedProcess struct {
	info         ProcessInfo
	firstAbove   time.Time
	triggeredAt  time.Time
	currentAbove bool
}

type processIdentity struct {
	pid     int
	ppid    int
	command string
}

type ProcessWatcher struct {
	options ProcessWatchOptions
	tracks  map[processIdentity]*trackedProcess
}

func NewProcessWatcher(options ProcessWatchOptions) *ProcessWatcher {
	return &ProcessWatcher{
		options: options,
		tracks:  make(map[processIdentity]*trackedProcess),
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

	seen := make(map[processIdentity]bool, len(processes))
	for _, proc := range processes {
		if proc.PID <= 0 {
			continue
		}
		key := processIdentity{
			pid:     proc.PID,
			ppid:    proc.PPID,
			command: proc.Command,
		}
		seen[key] = true

		track, ok := w.tracks[key]
		if !ok {
			track = &trackedProcess{}
			w.tracks[key] = track
		}

		track.info = proc
		track.currentAbove = proc.CPU >= w.options.CPUThreshold

		if track.currentAbove {
			if track.firstAbove.IsZero() {
				track.firstAbove = now
			}
			if now.Sub(track.firstAbove) >= w.options.Window && track.triggeredAt.IsZero() {
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

func (w *ProcessWatcher) Snapshot() []ProcessAlert {
	if w == nil || !w.options.Enabled {
		return nil
	}

	alerts := make([]ProcessAlert, 0, len(w.tracks))
	for _, track := range w.tracks {
		if !track.currentAbove || track.triggeredAt.IsZero() {
			continue
		}

		alerts = append(alerts, ProcessAlert{
			PID:         track.info.PID,
			Name:        track.info.Name,
			Command:     track.info.Command,
			CPU:         track.info.CPU,
			Threshold:   w.options.CPUThreshold,
			Window:      w.options.Window.String(),
			TriggeredAt: track.triggeredAt,
			Status:      "active",
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
