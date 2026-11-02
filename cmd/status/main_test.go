package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"io"
	"os"
	"os/exec"
	"reflect"
	"strings"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
)

func TestShouldUseJSONOutput_ForceFlag(t *testing.T) {
	if !shouldUseJSONOutput(true, nil) {
		t.Fatalf("expected force JSON flag to enable JSON mode")
	}
}

func TestShouldUseJSONOutput_NilStdout(t *testing.T) {
	if shouldUseJSONOutput(false, nil) {
		t.Fatalf("expected nil stdout to keep TUI mode")
	}
}

func TestShouldUseJSONOutput_NonTTYPipe(t *testing.T) {
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatalf("create pipe: %v", err)
	}
	defer reader.Close()
	defer writer.Close()

	if !shouldUseJSONOutput(false, writer) {
		t.Fatalf("expected pipe stdout to use JSON mode")
	}
}

func TestShouldUseJSONOutput_NonTTYFile(t *testing.T) {
	tmpFile, err := os.CreateTemp("", "mole-status-stdout-*.txt")
	if err != nil {
		t.Fatalf("create temp file: %v", err)
	}
	defer os.Remove(tmpFile.Name())
	defer tmpFile.Close()

	if !shouldUseJSONOutput(false, tmpFile) {
		t.Fatalf("expected file stdout to use JSON mode")
	}
}

func TestProcessWatchOptionsFromFlags(t *testing.T) {
	oldThreshold := *procCPUThreshold
	oldWindow := *procCPUWindow
	oldAlerts := *procCPUAlerts
	defer func() {
		*procCPUThreshold = oldThreshold
		*procCPUWindow = oldWindow
		*procCPUAlerts = oldAlerts
	}()

	*procCPUThreshold = 125
	*procCPUWindow = 2 * time.Minute
	*procCPUAlerts = false

	opts := processWatchOptionsFromFlags()
	if opts.CPUThreshold != 125 {
		t.Fatalf("CPUThreshold = %v, want 125", opts.CPUThreshold)
	}
	if opts.Window != 2*time.Minute {
		t.Fatalf("Window = %v, want 2m", opts.Window)
	}
	if opts.Enabled {
		t.Fatal("Enabled = true, want false")
	}
}

func TestValidateFlags(t *testing.T) {
	oldThreshold := *procCPUThreshold
	oldWindow := *procCPUWindow
	defer func() {
		*procCPUThreshold = oldThreshold
		*procCPUWindow = oldWindow
	}()

	*procCPUThreshold = -1
	*procCPUWindow = 5 * time.Minute
	if err := validateFlags(); err == nil {
		t.Fatal("expected negative threshold to fail validation")
	}

	*procCPUThreshold = 100
	*procCPUWindow = 0
	if err := validateFlags(); err == nil {
		t.Fatal("expected zero window to fail validation")
	}
}

func TestParseWatchInterval(t *testing.T) {
	tests := []struct {
		name    string
		raw     string
		want    time.Duration
		wantErr bool
	}{
		{name: "default", raw: "", want: refreshInterval},
		{name: "duration", raw: "250ms", want: 250 * time.Millisecond},
		{name: "invalid", raw: "soon", wantErr: true},
		{name: "zero", raw: "0s", wantErr: true},
		{name: "negative", raw: "-1s", wantErr: true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := parseWatchInterval(tt.raw)
			if tt.wantErr {
				if err == nil {
					t.Fatalf("parseWatchInterval(%q) returned nil error", tt.raw)
				}
				return
			}
			if err != nil {
				t.Fatalf("parseWatchInterval(%q) error = %v", tt.raw, err)
			}
			if got != tt.want {
				t.Fatalf("parseWatchInterval(%q) = %v, want %v", tt.raw, got, tt.want)
			}
		})
	}
}

func TestCollectionScheduleUsesFastFirstThenPeriodicFull(t *testing.T) {
	now := time.Now()
	var schedule collectionSchedule
	if got := schedule.nextMode(now); got != collectionFast {
		t.Fatalf("initial collection = %v, want fast", got)
	}

	first := collectionResult{mode: collectionFast, completedAt: now, data: MetricsSnapshot{CollectedAt: now}}
	if delay := schedule.recordCompletion(first, refreshInterval); delay != 0 {
		t.Fatalf("initial enrichment delayed by %v", delay)
	}
	if got := schedule.nextMode(now); got != collectionFull {
		t.Fatalf("first enrichment = %v, want full", got)
	}

	full := collectionResult{mode: collectionFull, completedAt: now, data: first.data}
	if delay := schedule.recordCompletion(full, refreshInterval); delay != refreshInterval {
		t.Fatalf("full collection delay = %v, want %v", delay, refreshInterval)
	}
	for _, tc := range []struct {
		after time.Duration
		want  collectionMode
	}{
		{processWatchInterval - time.Nanosecond, collectionFast},
		{processWatchInterval, collectionProcess},
		{slowRefreshInterval - time.Nanosecond, collectionProcess},
		{slowRefreshInterval, collectionFull},
	} {
		if got := schedule.nextMode(now.Add(tc.after)); got != tc.want {
			t.Errorf("next collection after %v = %v, want %v", tc.after, got, tc.want)
		}
	}
}

func TestCollectionScheduleWaitsForMissingSnapshots(t *testing.T) {
	now := time.Now()
	var schedule collectionSchedule
	failed := collectionResult{mode: collectionFast, completedAt: now, err: errors.New("no snapshot")}
	for range 2 {
		if delay := schedule.recordCompletion(failed, refreshInterval); delay != refreshInterval {
			t.Fatalf("missing snapshot delay = %v, want %v", delay, refreshInterval)
		}
		if schedule.hasSnapshot || schedule.nextMode(now) != collectionFast {
			t.Fatal("missing snapshot advanced startup")
		}
	}

	// A partial snapshot is still useful. Enrich it immediately once, then
	// honor the normal interval even when the full collection also fails.
	failed.data.CollectedAt = now
	if delay := schedule.recordCompletion(failed, refreshInterval); delay != 0 {
		t.Fatalf("first usable snapshot delay = %v, want immediate enrichment", delay)
	}
	failed.mode = collectionFull
	if delay := schedule.recordCompletion(failed, refreshInterval); delay != refreshInterval {
		t.Fatalf("failed enrichment delay = %v, want %v", delay, refreshInterval)
	}
	if got := schedule.nextMode(now); got != collectionFast {
		t.Fatalf("failed enrichment next mode = %v, want fast", got)
	}
}

func TestFullCollectionUsesCompletionTimeWithoutMarkingErrorsFresh(t *testing.T) {
	startedAt := time.Now()
	completedAt := startedAt.Add(2 * slowRefreshInterval)
	for _, collectionErr := range []error{nil, errors.New("full collector failed")} {
		m := model{schedule: collectionSchedule{hasSnapshot: true}}
		updated, _ := m.Update(collectionResult{
			data:        MetricsSnapshot{CollectedAt: startedAt},
			err:         collectionErr,
			mode:        collectionFull,
			completedAt: completedAt,
		})
		got := updated.(model)
		if got.fullCollected != (collectionErr == nil) {
			t.Fatalf("fullCollected = %v after error %v", got.fullCollected, collectionErr)
		}
		if !got.lastUpdated.Equal(startedAt) || !got.metrics.CollectedAt.Equal(startedAt) {
			t.Fatal("attempt completion replaced the original sample timestamp")
		}
		if got.schedule.nextMode(completedAt) != collectionFast {
			t.Fatal("slow full collection immediately retried")
		}
		if got.schedule.nextMode(completedAt.Add(slowRefreshInterval-time.Nanosecond)) != collectionProcess {
			t.Fatal("full collection retried before its interval elapsed")
		}
		if got.schedule.nextMode(completedAt.Add(slowRefreshInterval)) != collectionFull {
			t.Fatal("full collection did not become eligible after its interval")
		}
	}
}

func TestProcessFailureDoesNotForceFullRefresh(t *testing.T) {
	now := time.Now()
	m := model{schedule: collectionSchedule{hasSnapshot: true, lastFullAttemptAt: now}, fullCollected: true}
	for second := 1; second < int(slowRefreshInterval/time.Second); second++ {
		completedAt := now.Add(time.Duration(second) * time.Second)
		updated, _ := m.Update(collectionResult{
			data:        MetricsSnapshot{CollectedAt: completedAt},
			err:         errors.New("process collector failed"),
			mode:        collectionProcess,
			completedAt: completedAt,
		})
		m = updated.(model)
		if !m.fullCollected || !m.schedule.lastFullAttemptAt.Equal(now) {
			t.Fatal("process failure changed the full collection state")
		}
		if got := m.schedule.nextMode(completedAt); got != collectionFast {
			t.Fatalf("process failure retried immediately: mode %v", got)
		}
	}
	if got := m.schedule.nextMode(now.Add(slowRefreshInterval)); got != collectionFull {
		t.Fatalf("full refresh suppressed after process errors: mode %v", got)
	}
}

func TestCollectionRecoveryKeepsReadinessAndSerializesTicks(t *testing.T) {
	var m model
	now := time.Now()
	for _, collectionErr := range []error{errors.New("probe failed"), nil, errors.New("probe failed again")} {
		started, command := m.Update(tickMsg{})
		m = started.(model)
		if command == nil || !m.collecting {
			t.Fatal("tick did not start collection")
		}
		if _, duplicate := m.Update(tickMsg{}); duplicate != nil {
			t.Fatal("a second tick started overlapping collection")
		}

		wasFullCollected := m.fullCollected
		updated, nextTick := m.Update(collectionResult{
			data:        MetricsSnapshot{CollectedAt: now, CPU: CPUStatus{Usage: 25}},
			err:         collectionErr,
			mode:        collectionFull,
			completedAt: now.Add(time.Second),
		})
		m = updated.(model)
		if m.collecting || nextTick == nil || !m.schedule.hasSnapshot {
			t.Fatal("completed collection did not publish its snapshot and schedule another tick")
		}
		if m.metrics.CPU.Usage != 25 || (m.errMessage != "") != (collectionErr != nil) {
			t.Fatal("partial data or collection error was lost")
		}
		if m.fullCollected != (wasFullCollected || collectionErr == nil) {
			t.Fatal("full collection readiness did not survive failure and recovery")
		}
		now = now.Add(slowRefreshInterval)
	}
}

func TestCollectorAppliesCachedEnrichmentToFastSnapshot(t *testing.T) {
	zeroZombies := 0
	parentsComplete := true
	collector := NewCollector(ProcessWatchOptions{})
	collector.hasEnrichment = true
	collector.enrichment = snapshotEnrichment{
		memoryCached:   512,
		memoryPressure: "warn",
		hardware:       HardwareInfo{Model: "ThinkPad X1", CPUModel: "Core i7", OSVersion: "Arch Linux"},
		memoryPSI:      &MemoryPressureStats{SomeAvg10: 12},
		restartReason:  "kernel replaced",
		gpu:            []GPUStatus{{Name: "Apple GPU", Usage: 12}},
		trashSize:      42,
		trashApprox:    true,
		proxy:          ProxyStatus{Enabled: true, Type: "HTTP", Host: "127.0.0.1:8080"},
		batteries:      []BatteryStatus{{Percent: 80, Capacity: 92}},
		thermal:        ThermalStatus{CPUTemp: 45},
		sensors:        []SensorReading{{Label: "Fan", Value: 1200, Unit: "rpm"}},
	}
	collector.cacheProcessEnrichment(MetricsSnapshot{
		CollectedAt: time.Now(),
		TopProcesses: []ProcessInfo{
			{PID: 42, Name: "Xcode", CPU: 82},
		},
		ZombieCount:           &zeroZombies,
		ZombieParentsComplete: &parentsComplete,
		ProcessAlerts: []ProcessAlert{
			{PID: 42, Name: "Xcode", CPU: 140, Status: "active"},
		},
	})

	next := MetricsSnapshot{
		UptimeSeconds: 60,
		Hardware:      HardwareInfo{TotalRAM: "16G", DiskSize: "1T"},
		CPU:           CPUStatus{Usage: 10},
		Memory:        MemoryStatus{UsedPercent: 30, Pressure: "normal"},
		Disks:         []DiskStatus{{Mount: "/", Total: 100, Used: 20, UsedPercent: 20}},
		DiskIO:        DiskIOStatus{ReadRate: 1, WriteRate: 1},
	}

	collector.applyEnrichment(&next, false)

	if next.Hardware.Model != "ThinkPad X1" {
		t.Fatalf("expected hardware details to be preserved, got %#v", next.Hardware)
	}
	if next.Memory.PSI == nil || next.Memory.PSI.SomeAvg10 != 12 || next.RestartReason != "kernel replaced" {
		t.Fatalf("expected PSI and restart reason to be preserved, got %#v / %q", next.Memory.PSI, next.RestartReason)
	}
	if next.Memory.Cached != 512 || next.Memory.Pressure != "warn" {
		t.Fatalf("expected slow memory annotations to be preserved, got %#v", next.Memory)
	}
	if next.TrashSize != 42 || !next.TrashApprox {
		t.Fatalf("expected trash metadata to be preserved, got size=%d approx=%v", next.TrashSize, next.TrashApprox)
	}
	if !next.Proxy.Enabled || next.Proxy.Host != "127.0.0.1:8080" {
		t.Fatalf("expected proxy metadata to be preserved, got %#v", next.Proxy)
	}
	if len(next.GPU) != 1 || next.GPU[0].Name != "Apple GPU" {
		t.Fatalf("expected GPU metadata to be preserved from cache, got %#v", next.GPU)
	}
	if len(next.Batteries) != 1 || next.Batteries[0].Capacity != 92 {
		t.Fatalf("expected battery metadata to be preserved, got %#v", next.Batteries)
	}
	if next.Thermal.CPUTemp != 45 {
		t.Fatalf("expected thermal metadata to be preserved, got %#v", next.Thermal)
	}
	if len(next.TopProcesses) != 1 || next.TopProcesses[0].Name != "Xcode" {
		t.Fatalf("expected top processes to be preserved, got %#v", next.TopProcesses)
	}
	if len(next.ProcessAlerts) != 1 || next.ProcessAlerts[0].Status != "active" {
		t.Fatalf("expected process alerts to be preserved, got %#v", next.ProcessAlerts)
	}
	if next.HealthScore == 0 || next.HealthScoreMsg == "" {
		t.Fatalf("expected health score to be recalculated, got %d %q", next.HealthScore, next.HealthScoreMsg)
	}
}

func TestCollectorAppliesZeroValueEnrichmentExactly(t *testing.T) {
	collector := NewCollector(ProcessWatchOptions{})
	collector.hasEnrichment = true

	next := MetricsSnapshot{
		Memory: MemoryStatus{
			Cached:   512,
			Pressure: "critical",
		},
	}

	collector.applyEnrichment(&next, false)

	if next.Memory.Cached != 0 || next.Memory.Pressure != "" {
		t.Fatalf("expected exact memory enrichment, got %#v", next.Memory)
	}
}

func TestCollectorOverridesFastDisksWithCorrectedCache(t *testing.T) {
	collector := NewCollector(ProcessWatchOptions{})
	collector.hasEnrichment = true
	collector.enrichment = snapshotEnrichment{
		hasDisks: true,
		disks: []DiskStatus{
			{Mount: "/", Total: 1000, Used: 600, UsedPercent: 60, External: false, SmartStatus: smartStatusVerified},
		},
	}

	// Fast path produced raw statfs numbers that ignore APFS purgeable space.
	next := MetricsSnapshot{
		Disks: []DiskStatus{
			{Mount: "/", Total: 1000, Used: 900, UsedPercent: 90, External: true, SmartStatus: smartStatusUnknown},
		},
	}

	collector.applyEnrichment(&next, false)

	if len(next.Disks) != 1 {
		t.Fatalf("expected one disk, got %#v", next.Disks)
	}
	if next.Disks[0].Used != 600 || next.Disks[0].UsedPercent != 60 ||
		next.Disks[0].External || next.Disks[0].SmartStatus != smartStatusVerified {
		t.Fatalf("expected corrected disk values from cache, got %#v", next.Disks[0])
	}
}

func TestCollectorKeepsFastDisksWhenCacheHasNone(t *testing.T) {
	collector := NewCollector(ProcessWatchOptions{})
	// First full refresh failed to enumerate disks; the cache should not blank
	// out the fast path's raw disks.
	collector.hasEnrichment = true

	next := MetricsSnapshot{
		Disks: []DiskStatus{
			{Mount: "/", Total: 1000, Used: 900, UsedPercent: 90},
		},
	}

	collector.applyEnrichment(&next, false)

	if len(next.Disks) != 1 || next.Disks[0].Used != 900 {
		t.Fatalf("expected raw fast disks to survive empty cache, got %#v", next.Disks)
	}
}

func TestCollectorKeepsLiveProcessDataWhenApplyingEnrichment(t *testing.T) {
	collector := NewCollector(ProcessWatchOptions{})
	zeroZombies := 0
	parentsComplete := true
	collector.cacheProcessEnrichment(MetricsSnapshot{
		CollectedAt:           time.Now(),
		TopProcesses:          []ProcessInfo{{PID: 1, Name: "old", CPU: 10}},
		ZombieCount:           &zeroZombies,
		ZombieParentsComplete: &parentsComplete,
		ProcessAlerts: []ProcessAlert{
			{PID: 1, Name: "old", Status: "active"},
		},
	})

	next := MetricsSnapshot{
		TopProcesses: []ProcessInfo{{PID: 2, Name: "new", CPU: 90}},
		ProcessAlerts: []ProcessAlert{
			{PID: 2, Name: "new", Status: "active"},
		},
	}

	collector.applyEnrichment(&next, true)

	if len(next.TopProcesses) != 1 || next.TopProcesses[0].Name != "new" {
		t.Fatalf("expected live top process data, got %#v", next.TopProcesses)
	}
	if len(next.ProcessAlerts) != 1 || next.ProcessAlerts[0].Name != "new" {
		t.Fatalf("expected live process alerts, got %#v", next.ProcessAlerts)
	}
}

func TestMetricsSnapshotFieldsHaveCollectionClassifications(t *testing.T) {
	classified := map[string]string{
		"RestartReason":         "enrichment",
		"CollectedAt":           "fast",
		"Host":                  "fast",
		"Platform":              "fast",
		"Uptime":                "fast",
		"UptimeSeconds":         "fast",
		"Procs":                 "fast",
		"Hardware":              "enrichment",
		"HealthScore":           "recomputed",
		"HealthScoreMsg":        "recomputed",
		"CPU":                   "mixed",
		"GPU":                   "enrichment",
		"Memory":                "mixed",
		"Disks":                 "enrichment",
		"TrashSize":             "enrichment",
		"TrashApprox":           "enrichment",
		"DiskIO":                "fast",
		"Network":               "fast",
		"NetworkHistory":        "fast",
		"Proxy":                 "enrichment",
		"Batteries":             "enrichment",
		"Peripherals":           "enrichment",
		"Thermal":               "enrichment",
		"Sensors":               "enrichment",
		"TopProcesses":          "live-or-enrichment",
		"TopApps":               "live-or-enrichment",
		"ProcessCollectedAt":    "live-or-enrichment",
		"ProcessStale":          "live-or-enrichment",
		"ZombieCount":           "live-or-enrichment",
		"ZombieParents":         "live-or-enrichment",
		"ZombieParentsComplete": "live-or-enrichment",
		"ProcessWatch":          "config",
		"ProcessAlerts":         "live-or-enrichment",
	}

	typ := reflect.TypeFor[MetricsSnapshot]()
	for field := range typ.Fields() {
		name := field.Name
		if _, ok := classified[name]; !ok {
			t.Fatalf("MetricsSnapshot.%s has no collection classification", name)
		}
	}
	if len(classified) != typ.NumField() {
		t.Fatalf("field classification count = %d, want %d", len(classified), typ.NumField())
	}
}

// Run the real one-shot JSON path in a child so os.Exit and stdout stay
// isolated. External commands are disabled and the process probe fails.
func TestStatusJSONProcess(t *testing.T) {
	if os.Getenv("MOLE_STATUS_JSON_TEST") == "" {
		t.Skip("json subprocess helper")
	}
	runCmd = func(context.Context, string, ...string) (string, error) {
		return "", errors.New("optional metric unavailable")
	}
	commandExists = func(string) bool { return false }
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{{Device: "/dev/disk3s1", Mountpoint: "/", Fstype: "apfs"}}, nil
	}
	diskUsageFunc = func(string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Total: 2 << 30, Used: 1 << 30, Free: 1 << 30, UsedPercent: 50}, nil
	}
	collectProcessesFunc = func() (processSample, error) {
		return processSample{}, errors.New("process probe failed")
	}
	scenario := os.Getenv("MOLE_STATUS_JSON_TEST")
	if scenario != "1" {
		collectCPUFunc = func() (CPUStatus, error) { return CPUStatus{}, errors.New("cpu probe failed") }
		collectMemoryFunc = func() (MemoryStatus, error) { return MemoryStatus{}, errors.New("memory probe failed") }
		diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) { return nil, errors.New("disk probe failed") }
		switch scenario {
		case "cpu":
			collectCPUFunc = func() (CPUStatus, error) { return CPUStatus{LogicalCPU: 2}, nil }
		case "memory":
			collectMemoryFunc = func() (MemoryStatus, error) { return MemoryStatus{Total: 8 << 30}, nil }
		case "processes":
			collectProcessesFunc = func() (processSample, error) { return processSample{}, nil }
		}
	}
	runJSONMode()
	os.Exit(0)
}

func TestJSONModePrintsPartialSnapshotWhenOneCollectorFails(t *testing.T) {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestStatusJSONProcess$")
	cmd.Env = append(os.Environ(), "MOLE_STATUS_JSON_TEST=1", "HOME="+t.TempDir(), "MOLE_TEST_NO_AUTH=1")
	var stdout, stderr bytes.Buffer
	cmd.Stdout, cmd.Stderr = &stdout, &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("json mode exited with %v; stderr: %s", err, &stderr)
	}
	if !strings.Contains(stderr.String(), "process probe failed") {
		t.Fatalf("collector failure not reported on stderr: %q", &stderr)
	}

	var snapshot MetricsSnapshot
	if err := json.Unmarshal(stdout.Bytes(), &snapshot); err != nil {
		t.Fatalf("stdout is not one JSON snapshot: %v\n%s", err, &stdout)
	}
	if snapshot.CollectedAt.IsZero() || len(snapshot.Disks) != 1 || snapshot.Disks[0].Total != 2<<30 {
		t.Fatalf("successful metrics missing: collected_at=%v disks=%+v", snapshot.CollectedAt, snapshot.Disks)
	}
	// The failed group stays marked the way README documents it: no sample time.
	if snapshot.ProcessCollectedAt != nil || snapshot.ZombieCount != nil {
		t.Fatalf("failed process probe reported a sample: %+v", snapshot)
	}
}

func TestWriteJSONSnapshotFailsWhenNothingWasCollected(t *testing.T) {
	for _, collectErr := range []error{errors.New("cpu probe failed"), nil} {
		var stdout, stderr bytes.Buffer
		if code := writeJSONSnapshot(&stdout, &stderr, MetricsSnapshot{}, collectErr); code != 1 {
			t.Fatalf("empty snapshot exit = %d, want 1", code)
		}
		if stdout.Len() != 0 {
			t.Fatalf("empty snapshot printed JSON: %q", &stdout)
		}
		if !strings.Contains(stderr.String(), "status: collect failed:") {
			t.Fatalf("empty snapshot gave no reason: %q", &stderr)
		}
	}
}

func TestJSONModeCollectorAvailability(t *testing.T) {
	for _, scenario := range []string{"none", "cpu", "memory", "processes"} {
		t.Run(scenario, func(t *testing.T) {
			ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
			defer cancel()
			cmd := exec.CommandContext(ctx, os.Args[0], "-test.run=^TestStatusJSONProcess$")
			cmd.Env = append(os.Environ(), "MOLE_STATUS_JSON_TEST="+scenario, "HOME="+t.TempDir(), "MOLE_TEST_NO_AUTH=1")
			var stdout, stderr bytes.Buffer
			cmd.Stdout, cmd.Stderr = &stdout, &stderr
			err := cmd.Run()
			if scenario == "none" {
				var exitErr *exec.ExitError
				if !errors.As(err, &exitErr) || exitErr.ExitCode() != 1 || stdout.Len() != 0 {
					t.Fatalf("all failed: err=%v stdout=%q stderr=%q", err, &stdout, &stderr)
				}
			} else {
				if err != nil {
					t.Fatalf("partial snapshot failed: %v, %s", err, &stderr)
				}
				var snapshot MetricsSnapshot
				if err := json.Unmarshal(stdout.Bytes(), &snapshot); err != nil {
					t.Fatal(err)
				}
				if snapshot.CollectedAt.IsZero() {
					t.Fatal("missing collection time")
				}
				switch scenario {
				case "cpu":
					if snapshot.CPU.LogicalCPU != 2 || snapshot.CPU.Usage != 0 {
						t.Fatalf("idle CPU sample lost: %+v", snapshot.CPU)
					}
				case "memory":
					if snapshot.Memory.Total != 8<<30 {
						t.Fatalf("memory sample lost: %+v", snapshot.Memory)
					}
				case "processes":
					if snapshot.ProcessCollectedAt == nil || len(snapshot.TopProcesses) != 0 {
						t.Fatalf("empty process sample lost: %+v", snapshot)
					}
				}
			}
			if !strings.Contains(stderr.String(), "probe failed") {
				t.Fatalf("missing collector errors: %q", &stderr)
			}
		})
	}
}

func TestWriteJSONSnapshotReportsOutputFailure(t *testing.T) {
	reader, writer := io.Pipe()
	_ = reader.Close()
	defer writer.Close()
	var stderr bytes.Buffer
	data := MetricsSnapshot{Memory: MemoryStatus{Total: 8 << 30}}
	if code := writeJSONSnapshot(writer, &stderr, data, nil); code != 1 {
		t.Fatalf("output failure exit = %d, want 1", code)
	}
	if !strings.Contains(stderr.String(), "error encoding JSON:") {
		t.Fatalf("missing output error: %q", &stderr)
	}
}
