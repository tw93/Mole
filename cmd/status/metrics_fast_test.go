package main

import (
	"context"
	"encoding/json"
	"errors"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
	gopsutilnet "github.com/shirou/gopsutil/v4/net"
)

func TestCollectFastAvoidsExternalCommands(t *testing.T) {
	origRunCmd := runCmd
	origCommandExists := commandExists
	origPartitions := diskPartitionsFunc
	origUsage := diskUsageFunc
	origIOCounters := ioCountersFunc
	t.Cleanup(func() {
		runCmd = origRunCmd
		commandExists = origCommandExists
		diskPartitionsFunc = origPartitions
		diskUsageFunc = origUsage
		ioCountersFunc = origIOCounters
	})

	var externalCalls atomic.Int32
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		externalCalls.Add(1)
		return "", errors.New("unexpected command")
	}
	commandExists = func(name string) bool {
		externalCalls.Add(1)
		return false
	}
	diskPartitionsFunc = func(all bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{
			{Device: "/dev/disk3s1s1", Mountpoint: "/", Fstype: "apfs"},
		}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		return &disk.UsageStat{
			Path:        path,
			Fstype:      "apfs",
			Total:       2 * 1024 * 1024 * 1024,
			Used:        1024 * 1024 * 1024,
			UsedPercent: 50,
		}, nil
	}
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return []gopsutilnet.IOCountersStat{
			{Name: "en0", BytesRecv: 1024, BytesSent: 2048},
		}, nil
	}

	collector := NewCollector(ProcessWatchOptions{})
	if _, err := collector.CollectFast(); err != nil {
		t.Fatalf("CollectFast() error = %v", err)
	}
	if externalCalls.Load() != 0 {
		t.Fatalf("CollectFast() made %d external command calls", externalCalls.Load())
	}
}

func TestCollectProcessesKeepsLiveProcessesWithCachedEnrichment(t *testing.T) {
	origPartitions := diskPartitionsFunc
	origUsage := diskUsageFunc
	origIOCounters := ioCountersFunc
	origCollectProcesses := collectProcessesFunc
	t.Cleanup(func() {
		diskPartitionsFunc = origPartitions
		diskUsageFunc = origUsage
		ioCountersFunc = origIOCounters
		collectProcessesFunc = origCollectProcesses
	})

	diskPartitionsFunc = func(all bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{
			{Device: "/dev/disk3s1s1", Mountpoint: "/", Fstype: "apfs"},
		}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		return &disk.UsageStat{
			Path:        path,
			Fstype:      "apfs",
			Total:       2 * 1024 * 1024 * 1024,
			Used:        1024 * 1024 * 1024,
			UsedPercent: 50,
		}, nil
	}
	ioCountersFunc = func(bool) ([]gopsutilnet.IOCountersStat, error) {
		return []gopsutilnet.IOCountersStat{{Name: "en0", BytesRecv: 1024, BytesSent: 2048}}, nil
	}
	collectProcessesFunc = func() (processSample, error) {
		return processSample{processes: []ProcessInfo{
			{PID: 200, PPID: 1, Name: "new-hot-process", Command: "/usr/bin/new-hot-process", CPU: 240, Memory: 1.5},
			{PID: 201, PPID: 200, State: "Z+", Name: "defunct-child", Command: "defunct-child"},
		}, parentsAvailable: true}, nil
	}

	collector := NewCollector(ProcessWatchOptions{Enabled: true, CPUThreshold: 50})
	cachedZombieCount := 7
	cachedParentsComplete := true
	cached := MetricsSnapshot{
		CollectedAt: time.Now(),
		TopProcesses: []ProcessInfo{
			{PID: 100, Name: "old-process", CPU: 10},
		},
		ZombieCount: &cachedZombieCount,
		ZombieParents: []ZombieParent{
			{PID: 100, Name: "old-process", Count: 7},
		},
		ZombieParentsComplete: &cachedParentsComplete,
		ProcessAlerts: []ProcessAlert{
			{PID: 100, Name: "old-process", Status: "active"},
		},
	}
	collector.hasEnrichment = true
	collector.enrichment = snapshotEnrichment{hardware: HardwareInfo{Model: "MacBook Pro"}, trashSize: 99}
	collector.cacheProcessEnrichment(cached)

	snapshot, err := collector.CollectProcesses()
	if err != nil {
		t.Fatalf("CollectProcesses() error = %v", err)
	}

	if snapshot.Hardware.Model != "MacBook Pro" || snapshot.TrashSize != 99 {
		t.Fatalf("expected cached enrichment to be preserved, got hardware=%#v trash=%d", snapshot.Hardware, snapshot.TrashSize)
	}
	if len(snapshot.TopProcesses) < 1 || snapshot.TopProcesses[0].Name != "new-hot-process" {
		t.Fatalf("expected live top process data, got %#v", snapshot.TopProcesses)
	}
	if len(snapshot.ProcessAlerts) != 1 || snapshot.ProcessAlerts[0].Name != "new-hot-process" {
		t.Fatalf("expected live process alert data, got %#v", snapshot.ProcessAlerts)
	}
	if snapshot.ZombieCount == nil || *snapshot.ZombieCount != 1 || len(snapshot.ZombieParents) != 1 || snapshot.ZombieParents[0].PID != 200 {
		t.Fatalf("expected live zombie summary, got count=%v parents=%#v", snapshot.ZombieCount, snapshot.ZombieParents)
	}
	if snapshot.ZombieParentsComplete == nil || !*snapshot.ZombieParentsComplete {
		t.Fatalf("expected complete live parent attribution, got %v", snapshot.ZombieParentsComplete)
	}
	if snapshot.ProcessCollectedAt == nil || snapshot.ProcessStale == nil || *snapshot.ProcessStale {
		t.Fatalf("live process freshness = collected_at %v stale %v", snapshot.ProcessCollectedAt, snapshot.ProcessStale)
	}
	processCollectedAt := *snapshot.ProcessCollectedAt

	fastSnapshot, err := collector.CollectFast()
	if err != nil {
		t.Fatalf("CollectFast() error = %v", err)
	}
	if fastSnapshot.ZombieCount == nil || *fastSnapshot.ZombieCount != 1 ||
		len(fastSnapshot.ZombieParents) != 1 || fastSnapshot.ZombieParents[0].PID != 200 {
		t.Fatalf("fast refresh restored stale zombies: count=%v parents=%#v", fastSnapshot.ZombieCount, fastSnapshot.ZombieParents)
	}
	if fastSnapshot.ProcessCollectedAt == nil || !fastSnapshot.ProcessCollectedAt.Equal(processCollectedAt) ||
		fastSnapshot.ProcessStale == nil || !*fastSnapshot.ProcessStale {
		t.Fatalf("cached process freshness = collected_at %v stale %v", fastSnapshot.ProcessCollectedAt, fastSnapshot.ProcessStale)
	}
}

func TestSlowEnrichmentDoesNotReplaceLatestProcessSummary(t *testing.T) {
	collector := NewCollector(ProcessWatchOptions{})
	measured := 3
	complete := true
	collector.cacheProcessEnrichment(MetricsSnapshot{
		CollectedAt: time.Now(),
		ZombieCount: &measured,
		ZombieParents: []ZombieParent{
			{PID: 42, Name: "Chrome", Count: 3},
		},
		ZombieParentsComplete: &complete,
	})

	collector.hasEnrichment = true
	collector.enrichment = snapshotEnrichment{hardware: HardwareInfo{Model: "newer enrichment"}}
	var snapshot MetricsSnapshot
	collector.applyEnrichment(&snapshot, false)

	if snapshot.ZombieCount == nil || *snapshot.ZombieCount != 3 {
		t.Fatalf("latest measured zombie count was not preserved: %v", snapshot.ZombieCount)
	}
	if len(snapshot.ZombieParents) != 1 || snapshot.ZombieParents[0].PID != 42 {
		t.Fatalf("latest measured zombie parents were not preserved: %#v", snapshot.ZombieParents)
	}
	if snapshot.ZombieParentsComplete == nil || !*snapshot.ZombieParentsComplete {
		t.Fatalf("latest parent completeness was not preserved: %v", snapshot.ZombieParentsComplete)
	}
}

func TestCachedProcessSummaryKeepsOwnTimestampAndIsMarkedStale(t *testing.T) {
	collector := NewCollector(ProcessWatchOptions{})
	sampledAt := time.Date(2026, time.August, 29, 12, 30, 0, 0, time.UTC)
	count := 2
	complete := true
	collector.cacheProcessEnrichment(MetricsSnapshot{
		CollectedAt:           sampledAt,
		ZombieCount:           &count,
		ZombieParentsComplete: &complete,
	})

	next := MetricsSnapshot{CollectedAt: sampledAt.Add(5 * time.Minute)}
	collector.applyEnrichment(&next, false)
	payload, err := json.Marshal(next)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	wantTime, _ := json.Marshal(sampledAt)
	if !strings.Contains(string(payload), `"process_collected_at":`+string(wantTime)) {
		t.Fatalf("cached process timestamp missing from snapshot: %s", payload)
	}
	if !strings.Contains(string(payload), `"process_stale":true`) {
		t.Fatalf("cached process summary was not marked stale: %s", payload)
	}
}

func TestCollectFullKeepsCachedProcessSummaryWhenProcessCollectionFails(t *testing.T) {
	origCollectProcesses := collectProcessesFunc
	t.Cleanup(func() {
		collectProcessesFunc = origCollectProcesses
	})
	collectProcessesFunc = func() (processSample, error) {
		return processSample{}, errors.New("transient process collection failure")
	}

	collector := NewCollector(ProcessWatchOptions{})
	sampledAt := time.Date(2026, time.August, 29, 14, 0, 0, 0, time.UTC)
	count := 2
	complete := true
	collector.cacheProcessEnrichment(MetricsSnapshot{
		CollectedAt: sampledAt,
		TopProcesses: []ProcessInfo{
			{PID: 42, Name: "cached-process", CPU: 12},
		},
		ZombieCount: &count,
		ZombieParents: []ZombieParent{
			{PID: 42, Name: "cached-process", Count: 2},
		},
		ZombieParentsComplete: &complete,
	})

	snapshot, err := collector.Collect()
	if err == nil {
		t.Fatal("Collect() error = nil, want process collection failure")
	}
	if len(snapshot.TopProcesses) != 1 || snapshot.TopProcesses[0].Name != "cached-process" {
		t.Fatalf("cached top processes were not preserved: %#v", snapshot.TopProcesses)
	}
	if snapshot.ZombieCount == nil || *snapshot.ZombieCount != 2 ||
		len(snapshot.ZombieParents) != 1 || snapshot.ZombieParents[0].PID != 42 {
		t.Fatalf("cached zombie summary was not preserved: count=%v parents=%#v", snapshot.ZombieCount, snapshot.ZombieParents)
	}
	if snapshot.ProcessCollectedAt == nil || !snapshot.ProcessCollectedAt.Equal(sampledAt) ||
		snapshot.ProcessStale == nil || !*snapshot.ProcessStale {
		t.Fatalf("cached process freshness = collected_at %v stale %v", snapshot.ProcessCollectedAt, snapshot.ProcessStale)
	}
}

func TestFullCollectionPublishesIndependentEnrichment(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("memory pressure is a macOS probe")
	}
	for _, failure := range []string{"error", "panic"} {
		t.Run(failure, func(t *testing.T) {
			t.Setenv("HOME", t.TempDir())
			origRunCmd, origCommandExists := runCmd, commandExists
			origPartitions, origUsage := diskPartitionsFunc, diskUsageFunc
			origProcesses := collectProcessesFunc
			t.Cleanup(func() {
				runCmd, commandExists = origRunCmd, origCommandExists
				diskPartitionsFunc, diskUsageFunc = origPartitions, origUsage
				collectProcessesFunc = origProcesses
			})

			level, total, failDisk := "1", uint64(2<<30), false
			runCmd = func(_ context.Context, name string, args ...string) (string, error) {
				if name == "/usr/sbin/sysctl" && strings.Join(args, " ") == "-n kern.memorystatus_vm_pressure_level" {
					return level + "\n", nil
				}
				return "", errors.New("optional metric unavailable")
			}
			commandExists = func(string) bool { return false }
			diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
				if failDisk {
					if failure == "panic" {
						panic("disk probe failed")
					}
					return nil, errors.New("disk probe failed")
				}
				return []disk.PartitionStat{{Device: "/dev/disk3s1", Mountpoint: "/", Fstype: "apfs"}}, nil
			}
			diskUsageFunc = func(string) (*disk.UsageStat, error) {
				return &disk.UsageStat{Total: total, Used: total / 2, Free: total / 2, UsedPercent: 50}, nil
			}
			collectProcessesFunc = func() (processSample, error) {
				return processSample{parentsAvailable: true}, nil
			}
			assertMetrics := func(snapshot MetricsSnapshot, wantPressure string, wantTotal uint64) {
				t.Helper()
				if snapshot.Memory.Pressure != wantPressure || len(snapshot.Disks) != 1 || snapshot.Disks[0].Total != wantTotal {
					t.Fatalf("pressure=%q disks=%+v, want %q and %d bytes", snapshot.Memory.Pressure, snapshot.Disks, wantPressure, wantTotal)
				}
			}

			collector := NewCollector(ProcessWatchOptions{})
			first, err := collector.Collect()
			if err != nil {
				t.Fatal(err)
			}
			assertMetrics(first, "normal", 2<<30)
			// Published slices must not share ownership with the cache.
			first.Disks[0].Total = 1

			level, failDisk = "2", true
			for _, collect := range []func() (MetricsSnapshot, error){collector.Collect, collector.CollectProcesses, collector.CollectFast} {
				snapshot, err := collect()
				if err == nil || !strings.Contains(err.Error(), "disk probe failed") {
					t.Fatalf("disk failure lost: %v", err)
				}
				assertMetrics(snapshot, "warn", 2<<30)
			}

			level, total, failDisk = "1", 4<<30, false
			for _, collect := range []func() (MetricsSnapshot, error){collector.Collect, collector.CollectProcesses, collector.CollectFast} {
				snapshot, err := collect()
				if err != nil {
					t.Fatal(err)
				}
				assertMetrics(snapshot, "normal", 4<<30)
			}
		})
	}
}
