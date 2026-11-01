package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
)

// Exercise the actual streaming loop in a child so its stdout and collector
// probes stay isolated from other tests. All external commands are disabled.
func TestStatusWatchProcess(t *testing.T) {
	mode := os.Getenv("MOLE_STATUS_WATCH_TEST_MODE")
	if mode == "" {
		t.Skip("watch subprocess helper")
	}
	runCmd = func(context.Context, string, ...string) (string, error) {
		return "", errors.New("optional metric unavailable")
	}
	memoryPSIFunc = func() (MemoryPressureStats, bool) {
		if mode == "process-failed" {
			// This probe runs only during full collection. Count real
			// dispatches to ensure a process failure cannot restart it each tick.
			file, err := os.OpenFile(filepath.Join(os.Getenv("HOME"), "full-refreshes"), os.O_CREATE|os.O_APPEND|os.O_WRONLY, 0o600)
			if err != nil {
				return MemoryPressureStats{}, false
			}
			_, err = file.WriteString("full\n")
			file.Close()
			if err != nil {
				return MemoryPressureStats{}, false
			}
		}
		return MemoryPressureStats{}, true
	}
	commandExists = func(string) bool { return false }
	var calls atomic.Int32
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		attempt := calls.Add(1)
		if mode == "failed" || (mode == "recover" && attempt <= 2) {
			return nil, errors.New("partition probe failed")
		}
		return []disk.PartitionStat{{Device: "/dev/vda2", Mountpoint: "/", Fstype: "ext4"}}, nil
	}
	diskUsageFunc = func(string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Total: 2 << 30, Used: 1 << 30, Free: 1 << 30, UsedPercent: 50}, nil
	}
	collectProcessesFunc = func() (processSample, error) {
		if mode == "process-failed" {
			return processSample{}, errors.New("process probe failed")
		}
		return processSample{parentsAvailable: true}, nil
	}
	runWatchStdout(time.Second)
}

func TestWatchHonorsIntervalAfterInitialSnapshot(t *testing.T) {
	for _, mode := range []string{"healthy", "failed", "recover", "process-failed"} {
		t.Run(mode, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestStatusWatchProcess$")
			fixtureHome := t.TempDir()
			cmd.Env = append(os.Environ(), "MOLE_STATUS_WATCH_TEST_MODE="+mode, "HOME="+fixtureHome, "MOLE_TEST_NO_AUTH=1")
			var stderr bytes.Buffer
			cmd.Stderr = &stderr
			stdout, err := cmd.StdoutPipe()
			if err != nil {
				t.Fatal(err)
			}
			defer stdout.Close()
			if err := cmd.Start(); err != nil {
				t.Fatal(err)
			}
			defer func() {
				cancel()
				_ = cmd.Wait()
				if t.Failed() {
					t.Logf("watch stderr: %s", &stderr)
				}
			}()
			var snapshots [3]MetricsSnapshot
			decoder := json.NewDecoder(stdout)
			for i := range snapshots {
				if err := decoder.Decode(&snapshots[i]); err != nil {
					t.Fatalf("snapshot %d: %v", i, err)
				}
			}
			// Startup may enrich the first snapshot immediately. Every later
			// collection must wait, including repeated failures and recovery.
			if elapsed := snapshots[2].CollectedAt.Sub(snapshots[1].CollectedAt); elapsed < time.Second {
				t.Fatalf("next collection started after %v, want at least 1s", elapsed)
			}
			if mode == "failed" && len(snapshots[2].Disks) != 0 {
				t.Fatal("failed disk probe unexpectedly produced a disk")
			}
			if mode != "failed" && (len(snapshots[2].Disks) != 1 || snapshots[2].Disks[0].Total != 2<<30) {
				t.Fatalf("healthy or recovered disk missing: %+v", snapshots[2].Disks)
			}
			if mode == "process-failed" {
				for i, snapshot := range snapshots[1:] {
					if snapshot.Memory.Pressure != "normal" {
						t.Fatalf("snapshot %d lost successful memory pressure: %q", i+1, snapshot.Memory.Pressure)
					}
				}
				trace, err := os.ReadFile(filepath.Join(fixtureHome, "full-refreshes"))
				if err != nil {
					t.Fatal(err)
				}
				if calls := strings.Count(string(trace), "full\n"); calls != 1 {
					t.Fatalf("process failure triggered %d full refreshes, want one startup attempt", calls)
				}
			}
		})
	}
}
