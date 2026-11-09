//go:build darwin

package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

const slowDuKB = 2048

// useSlowDu installs a du that answers after 0.4 s and shortens the per-folder
// limit below that, the shape of #1956 without a 30-second test.
func useSlowDu(t *testing.T, folderLimit, overviewLimit time.Duration) string {
	t.Helper()
	stub := filepath.Join(t.TempDir(), "du")
	script := fmt.Sprintf("#!/bin/sh\nsleep 0.4\necho %d\n", slowDuKB)
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	useDuStub(t, stub)

	previousDu, previousOverview := duTimeout, overviewDuTimeout
	duTimeout, overviewDuTimeout = folderLimit, overviewLimit
	t.Cleanup(func() { duTimeout, overviewDuTimeout = previousDu, previousOverview })

	home := t.TempDir()
	t.Setenv("HOME", home)
	target := filepath.Join(home, "Library")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}
	return target
}

// An overview row outlasts the per-folder limit, a folder listing keeps it (#1956).
func TestOverviewMeasurementOutlastsThePerFolderDuTimeout(t *testing.T) {
	target := useSlowDu(t, 100*time.Millisecond, 10*time.Second)

	size, err := measureOverviewSize(context.Background(), target)
	if err != nil || size != slowDuKB*1024 {
		t.Fatalf("overview measurement = %d, %v; want %d", size, err, slowDuKB*1024)
	}

	if _, err := getDirectorySizeFromDu(context.Background(), target); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("folder du err = %v; want the per-folder deadline", err)
	}
}

func TestOverviewMeasurementStillHasADeadline(t *testing.T) {
	target := useSlowDu(t, 10*time.Second, 100*time.Millisecond)

	if _, err := measureOverviewSize(context.Background(), target); !errors.Is(err, context.DeadlineExceeded) {
		t.Fatalf("overview err = %v; want its own deadline", err)
	}
}

func TestOldDownloadsRowOutlastsThePerFolderDuTimeout(t *testing.T) {
	target := useSlowDu(t, 100*time.Millisecond, 10*time.Second)
	downloads := filepath.Join(filepath.Dir(target), "Downloads")
	old := filepath.Join(downloads, "old-folder")
	if err := os.MkdirAll(old, 0o755); err != nil {
		t.Fatal(err)
	}
	stamp := time.Now().AddDate(-1, 0, 0)
	if err := os.Chtimes(old, stamp, stamp); err != nil {
		t.Fatal(err)
	}

	size, err := measureInsightSize(context.Background(), downloads)
	if err != nil || size != slowDuKB*1024 {
		t.Fatalf("old downloads = %d, %v; want %d", size, err, slowDuKB*1024)
	}
}

// --json prints nothing until every row lands, so it keeps the short limit.
func TestJSONOverviewKeepsThePerFolderDuTimeout(t *testing.T) {
	target := useSlowDu(t, 100*time.Millisecond, 10*time.Second)

	result := performOverviewScanForJSONWithEntries("/", nil, []dirEntry{{
		Name: "Fixture", Path: target, IsDir: true, Size: -1,
	}})
	if result.TotalSize != 0 {
		t.Fatalf("--json total = %d; want no size for the timed-out row", result.TotalSize)
	}
}

func TestQuittingKillsARunningOverviewDu(t *testing.T) {
	dir := t.TempDir()
	pidFile := filepath.Join(dir, "pid")
	stub := filepath.Join(dir, "du")
	script := fmt.Sprintf("#!/bin/sh\necho $$ > %q.tmp\nmv %q.tmp %q\nexec sleep 30\n", pidFile, pidFile, pidFile)
	if err := os.WriteFile(stub, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	useDuStub(t, stub)
	home := t.TempDir()
	t.Setenv("HOME", home)
	target := filepath.Join(home, "Library")
	if err := os.Mkdir(target, 0o755); err != nil {
		t.Fatal(err)
	}

	ctx, cancel := context.WithCancel(context.Background())
	publication := newScanPublication(ctx, cancel)
	m := model{overviewScanningSet: map[string]*scanPublication{target: publication}}
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		_, _ = measureOverviewSizeWithPublication(publication.ctx, target, publication)
	}()

	var pid int
	for deadline := time.Now().Add(5 * time.Second); pid == 0; {
		if data, err := os.ReadFile(pidFile); err == nil {
			pid, _ = strconv.Atoi(strings.TrimSpace(string(data)))
		}
		if pid == 0 && time.Now().After(deadline) {
			t.Fatal("du stub never started")
		}
		time.Sleep(5 * time.Millisecond)
	}
	t.Cleanup(func() { _ = syscall.Kill(pid, syscall.SIGKILL) })

	m.stopMeasurementsForExit()

	if err := syscall.Kill(pid, 0); !errors.Is(err, syscall.ESRCH) {
		t.Fatalf("du %d survived quitting: signal 0 returned %v", pid, err)
	}
	<-finished
}
