package main

import (
	"context"
	"errors"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func setWalkTimeouts(t *testing.T, overview, json time.Duration) {
	t.Helper()
	previousOverview, previousJSON := overviewWalkTimeout, jsonWalkTimeout
	overviewWalkTimeout, jsonWalkTimeout = overview, json
	t.Cleanup(func() { overviewWalkTimeout, jsonWalkTimeout = previousOverview, previousJSON })
}

func overviewFixture(t *testing.T) string {
	t.Helper()
	dir := filepath.Join(t.TempDir(), "Fixture")
	if err := os.MkdirAll(dir, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "data.bin"), make([]byte, 4096), 0o644); err != nil {
		t.Fatal(err)
	}
	return dir
}

// An overview row is bounded by overviewWalkTimeout alone, and that limit is
// long: a normal walk of a large folder must not read as unknown.
func TestOverviewMeasurementUsesItsOwnWalkTimeout(t *testing.T) {
	dir := overviewFixture(t)

	setWalkTimeouts(t, time.Nanosecond, time.Hour)
	if _, err := measureOverviewSize(context.Background(), dir); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("overview err = %v; want the overview deadline", err)
	}

	setWalkTimeouts(t, time.Minute, time.Nanosecond)
	if _, err := measureOverviewSize(context.Background(), dir); err != nil {
		t.Fatalf("overview err = %v; the --json limit must not reach the TUI row", err)
	}
}

func TestOverviewWalkTimeoutOutlastsTheJSONLimit(t *testing.T) {
	if overviewWalkTimeout < 5*time.Minute || jsonWalkTimeout != 30*time.Second {
		t.Fatalf("overview %v, json %v; want 5m and 30s", overviewWalkTimeout, jsonWalkTimeout)
	}
}

// --json prints nothing until every row lands, so it keeps the short limit.
func TestJSONOverviewKeepsTheShortWalkTimeout(t *testing.T) {
	dir := overviewFixture(t)
	rows := []dirEntry{{Name: "Fixture", Path: dir, IsDir: true, Size: -1}}

	setWalkTimeouts(t, time.Minute, time.Nanosecond)
	got := measureOverviewEntriesForJSON(rows, measureOverviewSize)
	if got[0].State == scanComplete {
		t.Fatalf("--json row state = %v; want it cut by jsonWalkTimeout", got[0].State)
	}

	setWalkTimeouts(t, time.Minute, time.Minute)
	got = measureOverviewEntriesForJSON(rows, measureOverviewSize)
	if got[0].State != scanComplete || got[0].Size != 4096 {
		t.Fatalf("--json row = %v %d; want complete 4096", got[0].State, got[0].Size)
	}
}

// Quitting needs no child to be killed here: the walk runs inside the process
// and ends with it. What it does rely on is that cancelling a row's
// publication stops that row's walk.
func TestCancellingAnOverviewScanStopsItsWalk(t *testing.T) {
	dir := overviewFixture(t)
	ctx, cancel := context.WithCancel(context.Background())
	publication := newScanPublication(ctx, cancel)
	m := model{overviewScanningSet: map[string]*scanPublication{dir: publication}}

	m.cancelOverviewScans(nil)

	if _, err := measureOverviewSize(publication.ctx, dir); !errors.Is(err, context.Canceled) {
		t.Fatalf("err = %v; want the walk to stop on cancel", err)
	}
}
