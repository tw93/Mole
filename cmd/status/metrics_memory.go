package main

import (
	"context"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/mem"
)

func collectMemory() (MemoryStatus, error) {
	vm, err := mem.VirtualMemory()
	if err != nil {
		return MemoryStatus{}, err
	}

	swap, _ := mem.SwapMemory()
	pressure := getMemoryPressure()

	// On macOS, vm.Cached is 0, so we calculate from file-backed pages.
	cached := vm.Cached
	if runtime.GOOS == "darwin" && cached == 0 {
		cached = getFileBackedMemory()
	}

	return MemoryStatus{
		Used:        vm.Used,
		Total:       vm.Total,
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

func getMemoryPressure() string {
	if runtime.GOOS != "darwin" {
		return ""
	}
	ctx, cancel := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancel()
	out, err := runCmd(ctx, "memory_pressure")
	if err != nil {
		return ""
	}
	lower := strings.ToLower(out)
	if strings.Contains(lower, "critical") {
		return "critical"
	}
	if strings.Contains(lower, "warn") {
		return "warn"
	}
	if strings.Contains(lower, "normal") {
		return "normal"
	}
	return ""
}
