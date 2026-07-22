package main

import (
	"errors"
	"os"
	"reflect"
	"testing"
	"time"
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

func TestNextCollectionModeUsesFastFirstThenPeriodicFull(t *testing.T) {
	now := time.Now()

	m := model{}
	if got := m.nextCollectionMode(now); got != collectionFast {
		t.Fatalf("new model nextCollectionMode() = %v, want fast", got)
	}

	m.ready = true
	if got := m.nextCollectionMode(now); got != collectionFull {
		t.Fatalf("ready model without full collection = %v, want full", got)
	}

	m.lastFullAt = now.Add(-slowRefreshInterval + time.Second)
	if got := m.nextCollectionMode(now); got != collectionProcess {
		t.Fatalf("fresh full without process collection mode = %v, want process", got)
	}

	m.lastProcessAt = now.Add(-processWatchInterval + time.Millisecond)
	if got := m.nextCollectionMode(now); got != collectionFast {
		t.Fatalf("fresh process collection mode = %v, want fast", got)
	}

	m.lastProcessAt = now.Add(-processWatchInterval)
	if got := m.nextCollectionMode(now); got != collectionProcess {
		t.Fatalf("stale process collection mode = %v, want process", got)
	}

	m.lastFullAt = now.Add(-slowRefreshInterval)
	if got := m.nextCollectionMode(now); got != collectionFull {
		t.Fatalf("expired full collection mode = %v, want full", got)
	}
}

func TestWatchStateUsesSharedCollectionCadence(t *testing.T) {
	now := time.Now()

	st := watchState{}
	if got := st.nextMode(now); got != collectionFast {
		t.Fatalf("new watchState nextMode() = %v, want fast", got)
	}

	st.ready = true
	if got := st.nextMode(now); got != collectionFull {
		t.Fatalf("ready watchState without full collection = %v, want full", got)
	}

	st.lastFullAt = now
	if got := st.nextMode(now); got != collectionProcess {
		t.Fatalf("fresh full without process collection mode = %v, want process", got)
	}

	st.lastProcessAt = now
	if got := st.nextMode(now); got != collectionFast {
		t.Fatalf("fresh process collection mode = %v, want fast", got)
	}
}

func TestFullCollectionErrorDoesNotMarkFullFresh(t *testing.T) {
	now := time.Now()
	lastFull := now.Add(-slowRefreshInterval)
	m := model{
		ready:      true,
		lastFullAt: lastFull,
	}

	updated, _ := m.Update(metricsMsg{
		data: MetricsSnapshot{
			CollectedAt: now,
		},
		err:  errors.New("full collector failed"),
		mode: collectionFull,
	})
	got := updated.(model)

	if !got.lastFullAt.Equal(lastFull) {
		t.Fatalf("full error updated lastFullAt = %v, want %v", got.lastFullAt, lastFull)
	}
	if got.nextCollectionMode(now) != collectionFull {
		t.Fatalf("full error should leave the next tick eligible for a full retry")
	}
}

func TestProcessCollectionUpdatesProcessFreshness(t *testing.T) {
	now := time.Now()
	m := model{ready: true}

	updated, _ := m.Update(metricsMsg{
		data: MetricsSnapshot{CollectedAt: now},
		mode: collectionProcess,
	})
	got := updated.(model)

	if !got.lastProcessAt.Equal(now) {
		t.Fatalf("process collection updated lastProcessAt = %v, want %v", got.lastProcessAt, now)
	}
	if !got.lastFullAt.IsZero() {
		t.Fatalf("process collection should not update lastFullAt, got %v", got.lastFullAt)
	}
}

func TestCollectorAppliesCachedEnrichmentToFastSnapshot(t *testing.T) {
	previous := MetricsSnapshot{
		CPU:         CPUStatus{PCoreCount: 8, ECoreCount: 4},
		Memory:      MemoryStatus{Cached: 512, Pressure: "warn"},
		Hardware:    HardwareInfo{Model: "MacBook Pro", CPUModel: "M3", OSVersion: "macOS 15", RefreshRate: "120Hz"},
		GPU:         []GPUStatus{{Name: "Apple GPU", Usage: 12}},
		TrashSize:   42,
		TrashApprox: true,
		Proxy:       ProxyStatus{Enabled: true, Type: "HTTP", Host: "127.0.0.1:8080"},
		Batteries:   []BatteryStatus{{Percent: 80, Capacity: 92}},
		Thermal:     ThermalStatus{CPUTemp: 45},
		Sensors:     []SensorReading{{Label: "Fan", Value: 1200, Unit: "rpm"}},
		Bluetooth:   []BluetoothDevice{{Name: "Keyboard", Connected: true}},
		TopProcesses: []ProcessInfo{
			{PID: 42, Name: "Xcode", CPU: 82},
		},
		ProcessAlerts: []ProcessAlert{
			{PID: 42, Name: "Xcode", CPU: 140, Status: "active"},
		},
	}

	collector := NewCollector(ProcessWatchOptions{})
	collector.cacheEnrichment(previous)
	previous.GPU[0].Name = "mutated"

	next := MetricsSnapshot{
		UptimeSeconds: 60,
		Hardware:      HardwareInfo{TotalRAM: "16G", DiskSize: "1T"},
		CPU:           CPUStatus{Usage: 10},
		Memory:        MemoryStatus{UsedPercent: 30, Pressure: "normal"},
		Disks:         []DiskStatus{{Mount: "/", Total: 100, Used: 20, UsedPercent: 20}},
		DiskIO:        DiskIOStatus{ReadRate: 1, WriteRate: 1},
	}

	collector.applyEnrichment(&next, false)

	if next.Hardware.Model != "MacBook Pro" {
		t.Fatalf("expected hardware details to be preserved, got %#v", next.Hardware)
	}
	if next.CPU.PCoreCount != 8 || next.CPU.ECoreCount != 4 {
		t.Fatalf("expected CPU topology to be preserved, got %#v", next.CPU)
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
	if len(next.Bluetooth) != 1 || next.Bluetooth[0].Name != "Keyboard" {
		t.Fatalf("expected Bluetooth metadata to be preserved, got %#v", next.Bluetooth)
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
	collector.cacheEnrichment(MetricsSnapshot{
		Memory: MemoryStatus{
			Cached:   0,
			Pressure: "",
		},
	})

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
	collector.cacheEnrichment(MetricsSnapshot{
		Disks: []DiskStatus{
			{Mount: "/", Total: 1000, Used: 600, UsedPercent: 60, External: false, SmartStatus: smartStatusVerified},
		},
	})

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
	collector.cacheEnrichment(MetricsSnapshot{Disks: nil})

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
	collector.cacheEnrichment(MetricsSnapshot{
		TopProcesses: []ProcessInfo{{PID: 1, Name: "old", CPU: 10}},
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
		"CollectedAt":    "fast",
		"Host":           "fast",
		"Platform":       "fast",
		"Uptime":         "fast",
		"UptimeSeconds":  "fast",
		"Procs":          "fast",
		"Hardware":       "enrichment",
		"HealthScore":    "recomputed",
		"HealthScoreMsg": "recomputed",
		"CPU":            "mixed",
		"GPU":            "enrichment",
		"GPUHistory":     "fast",
		"Memory":         "mixed",
		"Disks":          "enrichment",
		"TrashSize":      "enrichment",
		"TrashApprox":    "enrichment",
		"DiskIO":         "fast",
		"Network":        "fast",
		"NetworkHistory": "fast",
		"Proxy":          "enrichment",
		"Batteries":      "enrichment",
		"Thermal":        "enrichment",
		"Sensors":        "enrichment",
		"Bluetooth":      "enrichment",
		"TopProcesses":   "live-or-enrichment",
		"ProcessWatch":   "config",
		"ProcessAlerts":  "live-or-enrichment",
	}

	typ := reflect.TypeFor[MetricsSnapshot]()
	for i := 0; i < typ.NumField(); i++ {
		name := typ.Field(i).Name
		if _, ok := classified[name]; !ok {
			t.Fatalf("MetricsSnapshot.%s has no collection classification", name)
		}
	}
	if len(classified) != typ.NumField() {
		t.Fatalf("field classification count = %d, want %d", len(classified), typ.NumField())
	}
}
