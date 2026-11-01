package main

import (
	"math"
	"testing"

	"github.com/shirou/gopsutil/v4/cpu"
)

func almostEqual(a, b float64) bool {
	return math.Abs(a-b) < 0.01
}

// A parked Apple Silicon core stops accumulating idle ticks, so its raw delta
// only covers the sliver of the window it was awake for. The old
// busy/(busy+idle) math read such a core as ~100% busy (#1237); flooring the
// denominator at the wall-clock window must report the real fraction.
func TestPerCoreUsageParkedCoreIsNotInflated(t *testing.T) {
	before := []cpu.TimesStat{{CPU: "cpu0", User: 10, System: 5, Idle: 100}}
	// Awake for only 0.02s of a 0.1s window, all of it busy; no idle ticks.
	after := []cpu.TimesStat{{CPU: "cpu0", User: 10.01, System: 5.01, Idle: 100}}

	percents, total, err := perCoreUsageFromTimes(before, after, 0.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !almostEqual(percents[0], 20) {
		t.Fatalf("parked core should read 20%% of the window, got %.2f", percents[0])
	}
	if !almostEqual(total, 20) {
		t.Fatalf("total should read 20%%, got %.2f", total)
	}
}

// When the tick deltas already cover the window (Intel, awake cores), the
// wall-clock floor must not change the classic busy/(busy+idle) result.
func TestPerCoreUsageFullyCoveredWindowUnchanged(t *testing.T) {
	before := []cpu.TimesStat{{CPU: "cpu0", User: 1, System: 1, Idle: 10}}
	after := []cpu.TimesStat{{CPU: "cpu0", User: 1.03, System: 1.02, Idle: 10.05}}

	percents, total, err := perCoreUsageFromTimes(before, after, 0.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !almostEqual(percents[0], 50) {
		t.Fatalf("expected 50%%, got %.2f", percents[0])
	}
	if !almostEqual(total, 50) {
		t.Fatalf("expected 50%% total, got %.2f", total)
	}
}

// The total must be busy-over-window across cores, not the mean of the raw
// per-core percentages: a mostly-parked core contributes its true window, so
// it cannot drag the machine total toward 100%.
func TestPerCoreUsageTotalIsWindowWeighted(t *testing.T) {
	before := []cpu.TimesStat{
		{CPU: "cpu0", User: 10, Idle: 100},
		{CPU: "cpu1", User: 20, Idle: 200},
	}
	after := []cpu.TimesStat{
		// Parked: 0.01s busy, no idle ticks. Raw math would say 100%.
		{CPU: "cpu0", User: 10.01, Idle: 100},
		// Awake: 0.09s busy + 0.01s idle over the full window.
		{CPU: "cpu1", User: 20.09, Idle: 200.01},
	}

	percents, total, err := perCoreUsageFromTimes(before, after, 0.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if !almostEqual(percents[0], 10) {
		t.Fatalf("parked core expected 10%%, got %.2f", percents[0])
	}
	if !almostEqual(percents[1], 90) {
		t.Fatalf("busy core expected 90%%, got %.2f", percents[1])
	}
	// (0.01 + 0.09) busy over (0.1 + 0.1) window = 50%.
	if !almostEqual(total, 50) {
		t.Fatalf("window-weighted total expected 50%%, got %.2f", total)
	}
}

func TestPerCoreUsageClampsAndErrors(t *testing.T) {
	// Busy jitter slightly above the window clamps to 100.
	before := []cpu.TimesStat{{CPU: "cpu0", User: 1, Idle: 1}}
	after := []cpu.TimesStat{{CPU: "cpu0", User: 1.12, Idle: 1}}
	percents, total, err := perCoreUsageFromTimes(before, after, 0.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if percents[0] != 100 || total != 100 {
		t.Fatalf("expected clamp to 100, got %.2f / %.2f", percents[0], total)
	}

	if _, _, err := perCoreUsageFromTimes(before, nil, 0.1); err == nil {
		t.Fatal("mismatched snapshots must error")
	}
	if _, _, err := perCoreUsageFromTimes(before, after, 0); err == nil {
		t.Fatal("non-positive window must error")
	}
	// A counter reset (negative busy delta) degrades to 0, not garbage.
	reset := []cpu.TimesStat{{CPU: "cpu0", User: 0.5, Idle: 1.1}}
	percents, _, err = perCoreUsageFromTimes(before, reset, 0.1)
	if err != nil {
		t.Fatalf("unexpected error: %v", err)
	}
	if percents[0] != 0 {
		t.Fatalf("negative busy delta should clamp to 0, got %.2f", percents[0])
	}
}
