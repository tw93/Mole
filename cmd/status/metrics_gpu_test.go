package main

import (
	"sync"
	"testing"
)

// TestGPUHistoryConcurrentAccess exercises the GPU mutex: concurrent pushes and
// snapshots must not race (run with -race). It mirrors how the dedicated GPU
// tick and the main collection goroutine touch the same buffers.
func TestGPUHistoryConcurrentAccess(t *testing.T) {
	c := NewCollector(ProcessWatchOptions{})

	var wg sync.WaitGroup
	for range 4 {
		wg.Go(func() {
			for range 200 {
				c.gpuMu.Lock()
				c.pushGPUHistory(gpuUsageSample{device: 5, renderer: 3, tiler: 1})
				c.gpuMu.Unlock()
				_ = c.gpuHistorySnapshot()
			}
		})
	}
	wg.Wait()

	if got := c.gpuHistorySnapshot(); len(got.DeviceHistory) == 0 {
		t.Fatal("expected device history to be populated after concurrent pushes")
	}
}

// TestGPUDeviceUtilRegex checks we extract "Device Utilization %" from a realistic
// ioreg PerformanceStatistics dict (as emitted by `ioreg -r -c AGXAccelerator`).
func TestGPUDeviceUtilRegex(t *testing.T) {
	sample := `      "PerformanceStatistics" = {"In use system memory"=1268629504,"Tiler Utilization %"=12,` +
		`"Renderer Utilization %"=9,"Device Utilization %"=42,"Alloc system memory"=7270154240}`

	m := gpuDeviceUtilRe.FindStringSubmatch(sample)
	if len(m) < 2 {
		t.Fatalf("regex did not match sample: %q", sample)
	}
	if m[1] != "42" {
		t.Errorf("Device Utilization %% = %q, want %q", m[1], "42")
	}
}

// TestGPUDeviceUtilRegexAbsent ensures we don't false-match when the key is missing.
func TestGPUDeviceUtilRegexAbsent(t *testing.T) {
	if gpuDeviceUtilRe.MatchString(`"Renderer Utilization %"=9`) {
		t.Error("regex matched a dict without a Device Utilization entry")
	}
}
