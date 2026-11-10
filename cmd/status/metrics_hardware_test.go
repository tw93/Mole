package main

import (
	"context"
	"errors"
	"runtime"
	"sync"
	"sync/atomic"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
)

// The hardware subprocesses must run inside the full collection burst, not as
// a serial tail after it. The process probe blocks until sw_vers starts; when
// hardware only runs after the burst, that wait times out.
func TestCollectFullRunsHardwareInsideConcurrentBurst(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("hardware subprocesses only run on darwin")
	}
	origRunCmd := runCmd
	origCommandExists := commandExists
	origPartitions := diskPartitionsFunc
	origUsage := diskUsageFunc
	origCPU := collectCPUFunc
	origMemory := collectMemoryFunc
	origProcesses := collectProcessesFunc
	t.Cleanup(func() {
		runCmd = origRunCmd
		commandExists = origCommandExists
		diskPartitionsFunc = origPartitions
		diskUsageFunc = origUsage
		collectCPUFunc = origCPU
		collectMemoryFunc = origMemory
		collectProcessesFunc = origProcesses
	})
	t.Setenv("HOME", t.TempDir())

	hwStarted := make(chan struct{})
	var startOnce sync.Once
	var swVersCalls atomic.Int32
	runCmd = func(_ context.Context, name string, _ ...string) (string, error) {
		if name == "sw_vers" {
			swVersCalls.Add(1)
			startOnce.Do(func() { close(hwStarted) })
			return "15.0\n", nil
		}
		return "", errors.New("optional metric unavailable")
	}
	commandExists = func(string) bool { return false }
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{{Device: "/dev/disk3s1", Mountpoint: "/", Fstype: "apfs"}}, nil
	}
	diskUsageFunc = func(string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Total: 2 << 30, Used: 1 << 30, Free: 1 << 30, UsedPercent: 50}, nil
	}
	collectCPUFunc = func() (CPUStatus, error) { return CPUStatus{LogicalCPU: 2}, nil }
	collectMemoryFunc = func() (MemoryStatus, error) { return MemoryStatus{Total: 8 << 30}, nil }
	var overlapped atomic.Bool
	collectProcessesFunc = func() (processSample, error) {
		select {
		case <-hwStarted:
			overlapped.Store(true)
		case <-time.After(3 * time.Second):
		}
		return processSample{}, nil
	}

	collector := NewCollector(ProcessWatchOptions{})
	snapshot, _ := collector.Collect()
	if !overlapped.Load() {
		t.Fatal("hardware subprocesses did not run inside the concurrent burst")
	}
	hw := snapshot.Hardware
	if hw.OSVersion != "macOS 15.0" || hw.TotalRAM != humanBytes(8<<30) || hw.DiskSize != humanBytes(2<<30) {
		t.Fatalf("hardware info = %+v", hw)
	}

	// Within the 10 minute window the cached card is reused without new probes.
	collectProcessesFunc = func() (processSample, error) { return processSample{}, nil }
	again, _ := collector.Collect()
	if swVersCalls.Load() != 1 {
		t.Fatalf("sw_vers calls = %d, want 1", swVersCalls.Load())
	}
	if again.Hardware != hw {
		t.Fatalf("cached hardware changed: %+v, want %+v", again.Hardware, hw)
	}
}

// The SPHardware, sw_vers and SPDisplays probes run at once: each stub blocks
// until all three have started, which a serial chain never reaches. The card
// still carries every field from its own probe.
func TestCollectHardwareStaticRunsProbesConcurrently(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("hardware subprocesses only run on darwin")
	}
	origRunCmd := runCmd
	t.Cleanup(func() { runCmd = origRunCmd })

	var started sync.WaitGroup
	started.Add(3)
	allStarted := make(chan struct{})
	go func() { started.Wait(); close(allStarted) }()
	var overlapped atomic.Int32
	wait := func() {
		started.Done()
		select {
		case <-allStarted:
			overlapped.Add(1)
		case <-time.After(900 * time.Millisecond):
		}
	}
	runCmd = func(_ context.Context, name string, args ...string) (string, error) {
		wait()
		switch {
		case name == "sw_vers":
			return "26.1\n", nil
		case name == "system_profiler" && len(args) == 1 && args[0] == "SPHardwareDataType":
			return "Hardware:\n\n    Hardware Overview:\n\n      Model Name: MacBook Pro\n      Chip: Apple M5 Pro\n", nil
		case name == "system_profiler" && len(args) == 3 && args[2] == "SPDisplaysDataType":
			return "Graphics/Displays:\n        Displays:\n          Color LCD:\n            Resolution: 3456 x 2234 Retina\n            UI Looks like: 1728 x 1117 @ 120.00Hz\n", nil
		}
		return "", errors.New("unexpected command")
	}

	hw := collectHardwareStatic()
	if overlapped.Load() != 3 {
		t.Fatalf("%d of 3 hardware probes overlapped, want all three to run concurrently", overlapped.Load())
	}
	want := HardwareInfo{Model: "MacBook Pro", CPUModel: "Apple M5 Pro", OSVersion: "macOS 26.1", RefreshRate: "120Hz"}
	if hw != want {
		t.Fatalf("collectHardwareStatic() = %+v, want %+v", hw, want)
	}
}
