package main

import (
	"math"
	"os"
	"path/filepath"
	"strconv"
	"strings"

	"github.com/shirou/gopsutil/v4/mem"
)

// Pressure Stall Information thresholds, in percent of wall-clock time that
// tasks were stalled on memory. "some" means at least one task waited, "full"
// means every runnable task waited. The kernel documents sustained "some"
// above roughly 10% as the point where work visibly slows.
const (
	psiWarnSomeAvg10   = 10.0
	psiWarnSomeAvg60   = 5.0
	psiWarnFullAvg10   = 1.0
	psiCritSomeAvg10   = 40.0
	psiCritSomeAvg60   = 25.0
	psiCritFullAvg10   = 5.0
	procPressureMemory = "proc/pressure/memory"
)

// memoryPSIFunc is replaceable so tests can script memory pressure.
var memoryPSIFunc = func() (MemoryPressureStats, bool) { return readMemoryPSI("/") }

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
	status := MemoryStatus{
		Used:        vm.Used,
		Total:       vm.Total,
		Available:   vm.Available,
		UsedPercent: vm.UsedPercent,
		SwapUsed:    swap.Used,
		SwapTotal:   swap.Total,
		Cached:      vm.Cached,
		Zram:        readZram("/"),
	}
	if includeSlowAnnotations {
		if psi, ok := memoryPSIFunc(); ok {
			status.PSI = &psi
			status.Pressure = classifyMemoryPressure(psi)
		}
	}
	return status, nil
}

// readMemoryPSI parses root/proc/pressure/memory. It reports false when the
// kernel has no PSI (before 4.20, CONFIG_PSI off, or booted with psi=0).
func readMemoryPSI(root string) (MemoryPressureStats, bool) {
	data, err := os.ReadFile(filepath.Join(root, procPressureMemory))
	if err != nil {
		return MemoryPressureStats{}, false
	}
	return parseMemoryPSI(string(data))
}

// parseMemoryPSI reads lines like
// "some avg10=0.00 avg60=1.25 avg300=0.40 total=12345".
func parseMemoryPSI(raw string) (MemoryPressureStats, bool) {
	var stats MemoryPressureStats
	found := false
	for line := range strings.Lines(raw) {
		fields := strings.Fields(line)
		if len(fields) < 2 {
			continue
		}
		var avg10, avg60 *float64
		switch fields[0] {
		case "some":
			avg10, avg60 = &stats.SomeAvg10, &stats.SomeAvg60
		case "full":
			avg10, avg60 = &stats.FullAvg10, &stats.FullAvg60
		default:
			continue
		}
		for _, field := range fields[1:] {
			key, value, ok := strings.Cut(field, "=")
			if !ok {
				continue
			}
			parsed, err := strconv.ParseFloat(value, 64)
			if err != nil {
				continue
			}
			switch key {
			case "avg10":
				*avg10 = parsed
				found = true
			case "avg60":
				*avg60 = parsed
			}
		}
	}
	return stats, found
}

// classifyMemoryPressure maps PSI onto the normal/warn/critical vocabulary the
// card and the diagnosis line already use.
func classifyMemoryPressure(psi MemoryPressureStats) string {
	switch {
	case psi.FullAvg10 >= psiCritFullAvg10 || psi.SomeAvg10 >= psiCritSomeAvg10 || psi.SomeAvg60 >= psiCritSomeAvg60:
		return "critical"
	case psi.SomeAvg10 >= psiWarnSomeAvg10 || psi.SomeAvg60 >= psiWarnSomeAvg60 || psi.FullAvg10 >= psiWarnFullAvg10:
		return "warn"
	}
	return "normal"
}

// readZram totals every zram device under root/sys/block. mm_stat's first
// three fields are orig_data_size, compr_data_size and mem_used_total.
func readZram(root string) *ZramStatus {
	matches, _ := filepath.Glob(filepath.Join(root, "sys/block/zram*/mm_stat"))
	var z ZramStatus
	for _, path := range matches {
		fields := strings.Fields(readTrimmed(path))
		if len(fields) < 3 {
			continue
		}
		var vals [3]uint64
		ok := true
		for i := range vals {
			v, err := strconv.ParseUint(fields[i], 10, 64)
			if err != nil {
				ok = false
				break
			}
			vals[i] = v
		}
		if !ok {
			continue
		}
		z.Devices++
		z.Original += vals[0]
		z.Compressed += vals[1]
		z.MemUsed += vals[2]
	}
	if z.Original == 0 {
		return nil
	}
	if z.MemUsed > 0 {
		z.Ratio = math.Round(float64(z.Original)/float64(z.MemUsed)*10) / 10
	}
	return &z
}
