package main

import (
	"context"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/mem"
)

func collectMemory() (MemoryStatus, error) {
	return collectMemoryWithOptions(true)
}

func collectMemoryFast() (MemoryStatus, error) {
	return collectMemoryWithOptions(false)
}

func collectMemoryWithOptions(includeSlowAnnotations bool) (MemoryStatus, error) {
	vm, err := mem.VirtualMemory()
	if err != nil {
		return MemoryStatus{}, err
	}

	swap, _ := mem.SwapMemory()
	if swap == nil {
		swap = &mem.SwapMemoryStat{}
	}
	var pressure string
	if includeSlowAnnotations {
		pressure = getMemoryPressure()
	}

	// On macOS, vm.Cached is 0, so we calculate from file-backed pages.
	cached := vm.Cached
	if includeSlowAnnotations && runtime.GOOS == "darwin" && cached == 0 {
		cached = getFileBackedMemory()
	}

	return MemoryStatus{
		Used:        vm.Used,
		Total:       vm.Total,
		Available:   vm.Available,
		UsedPercent: vm.UsedPercent,
		SwapUsed:    swap.Used,
		SwapTotal:   swap.Total,
		Cached:      cached,
		Pressure:    pressure,
	}, nil
}

func getFileBackedMemory() uint64 {
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := runCmd(ctx, "vm_stat")
	if err != nil {
		return 0
	}

	// Parse page size from first line: "Mach Virtual Memory Statistics: (page size of 16384 bytes)"
	var pageSize uint64 = 4096 // Default
	firstLine := true
	for line := range strings.Lines(out) {
		if firstLine {
			firstLine = false
			if strings.Contains(line, "page size of") {
				if _, after, found := strings.Cut(line, "page size of "); found {
					if before, _, found := strings.Cut(after, " bytes"); found {
						if size, err := strconv.ParseUint(strings.TrimSpace(before), 10, 64); err == nil {
							pageSize = size
						}
					}
				}
			}
		}

		// Parse "File-backed pages: 388975."
		if strings.Contains(line, "File-backed pages:") {
			if _, after, found := strings.Cut(line, ":"); found {
				numStr := strings.TrimSpace(after)
				numStr = strings.TrimSuffix(numStr, ".")
				if pages, err := strconv.ParseUint(numStr, 10, 64); err == nil {
					return pages * pageSize
				}
			}
		}
	}
	return 0
}

// getMemoryPressure reads the level the kernel publishes. The memory_pressure
// tool prints page counters and a free percentage but never names the level,
// so matching its output for "normal", "warn" or "critical" always came back
// empty (#1963).
func getMemoryPressure() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := runCmd(ctx, "/usr/sbin/sysctl", "-n", "kern.memorystatus_vm_pressure_level")
	if err != nil {
		return ""
	}
	return parseMemoryPressureLevel(out)
}

// parseMemoryPressureLevel maps kern.memorystatus_vm_pressure_level to the
// names status reports. The values are the DISPATCH_MEMORYPRESSURE_* levels:
// 1 normal, 2 warn, 4 critical. Anything else is unknown.
func parseMemoryPressureLevel(out string) string {
	switch strings.TrimSpace(out) {
	case "1":
		return "normal"
	case "2":
		return "warn"
	case "4":
		return "critical"
	}
	return ""
}
