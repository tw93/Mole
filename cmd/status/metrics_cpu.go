package main

import (
	"errors"
	"math"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v4/cpu"
	"github.com/shirou/gopsutil/v4/load"
)

const (
	cpuSampleInterval = 100 * time.Millisecond
)

func collectCPU() (CPUStatus, error) {
	return collectCPUWithOptions(true)
}

func collectCPUFast() (CPUStatus, error) {
	return collectCPUWithOptions(false)
}

func collectCPUWithOptions(includeSlowFallbacks bool) (CPUStatus, error) {
	counts, countsErr := cpu.Counts(false)
	if countsErr != nil || counts == 0 {
		counts = runtime.NumCPU()
	}

	logical, logicalErr := cpu.Counts(true)
	if logicalErr != nil || logical == 0 {
		logical = runtime.NumCPU()
	}
	if logical <= 0 {
		logical = 1
	}

	var percents []float64
	var err error
	var totalPercent float64
	sampled := false
	if includeSlowFallbacks {
		// Explicit two-snapshot sampling on the full refresh path. On Apple
		// Silicon, host_processor_info stops accumulating idle ticks for a
		// parked core, so busy/(busy+idle) over the raw deltas reports a
		// mostly-sleeping E-core as 90-100% (#1237). sampleCPUPercents floors
		// each core's denominator at the wall-clock window, which counts the
		// missing parked time as idle; on Intel the ticks already cover the
		// window and the result is unchanged.
		warmUpCPU()
		percents, totalPercent, err = sampleCPUPercents(cpuSampleInterval)
		sampled = err == nil && len(percents) > 0
	}
	if !sampled {
		percents, err = cpu.Percent(0, true)
	}
	perCoreEstimated := false
	if !sampled && (err != nil || len(percents) == 0) {
		if includeSlowFallbacks {
			if err != nil {
				return CPUStatus{}, err
			}
			return CPUStatus{}, errors.New("no cpu times available")
		}
		// Fast path: estimate zeroed per-core usage. The next full refresh
		// corrects it.
		percents = make([]float64, logical)
		perCoreEstimated = true
	} else if !sampled {
		for _, v := range percents {
			totalPercent += v
		}
		totalPercent /= float64(len(percents))
	}

	var loadAvg load.AvgStat
	if loadStats, _ := load.Avg(); loadStats != nil {
		loadAvg = *loadStats
	}

	pCores, eCores := readHybridCores("/")
	freqAvg, freqMax := readCPUFrequency("/")

	return CPUStatus{
		PCoreCount:       pCores,
		ECoreCount:       eCores,
		FreqAvgMHz:       freqAvg,
		FreqMaxMHz:       freqMax,
		Usage:            totalPercent,
		PerCore:          percents,
		PerCoreEstimated: perCoreEstimated,
		Load1:            loadAvg.Load1,
		Load5:            loadAvg.Load5,
		Load15:           loadAvg.Load15,
		CoreCount:        counts,
		LogicalCPU:       logical,
	}, nil
}

func warmUpCPU() {
	cpu.Percent(0, true) //nolint:errcheck
}

// sampleCPUPercents measures per-core and total CPU usage over one wall-clock
// window using two cpu.Times snapshots.
func sampleCPUPercents(interval time.Duration) ([]float64, float64, error) {
	before, err := cpu.Times(true)
	if err != nil {
		return nil, 0, err
	}
	start := time.Now()
	time.Sleep(interval)
	after, err := cpu.Times(true)
	if err != nil {
		return nil, 0, err
	}
	return perCoreUsageFromTimes(before, after, time.Since(start).Seconds())
}

// perCoreUsageFromTimes converts two per-core cpu.Times snapshots into per-core
// percentages and a tick-weighted total.
//
// Each core's denominator is floored at the elapsed wall-clock time: a parked
// Apple Silicon core stops accumulating idle ticks, so its raw delta covers
// only the sliver of the window it was awake for and busy/(busy+idle) reads
// ~100% while the core mostly slept (#1237). Treating the missing ticks as
// idle time yields the fraction of the window the core actually worked. The
// total is busy-over-window across cores, not the mean of per-core
// percentages, so a core that barely ran cannot drag the total upward.
func perCoreUsageFromTimes(before, after []cpu.TimesStat, elapsed float64) ([]float64, float64, error) {
	if len(before) == 0 || len(before) != len(after) {
		return nil, 0, errors.New("mismatched cpu times snapshots")
	}
	if elapsed <= 0 {
		return nil, 0, errors.New("non-positive sampling window")
	}

	percents := make([]float64, len(before))
	var busySum, windowSum float64
	for i := range before {
		busy := cpuBusyTime(after[i]) - cpuBusyTime(before[i])
		if busy < 0 {
			busy = 0
		}
		total := busy + (after[i].Idle - before[i].Idle)
		window := total
		if window < elapsed {
			window = elapsed
		}
		usage := busy / window * 100
		if usage < 0 {
			usage = 0
		} else if usage > 100 {
			usage = 100
		}
		percents[i] = usage
		busySum += busy
		windowSum += window
	}
	if windowSum <= 0 {
		return nil, 0, errors.New("empty cpu sampling window")
	}
	total := busySum / windowSum * 100
	if total < 0 {
		total = 0
	} else if total > 100 {
		total = 100
	}
	return percents, total, nil
}

func cpuBusyTime(t cpu.TimesStat) float64 {
	return t.User + t.System + t.Nice + t.Irq + t.Softirq + t.Steal
}

// readCPUFrequency averages scaling_cur_freq (kHz) over the CPUs that have
// cpufreq, and reports the highest. A VM usually has none: both stay 0.
func readCPUFrequency(root string) (avgMHz, maxMHz float64) {
	matches, _ := filepath.Glob(filepath.Join(root, "sys/devices/system/cpu/cpu[0-9]*/cpufreq/scaling_cur_freq"))
	var sum float64
	n := 0
	for _, path := range matches {
		khz, ok := readInt(path)
		if !ok || khz <= 0 {
			continue
		}
		mhz := float64(khz) / 1000
		sum += mhz
		maxMHz = max(maxMHz, mhz)
		n++
	}
	if n == 0 {
		return 0, 0
	}
	return math.Round(sum / float64(n)), math.Round(maxMHz)
}

// readHybridCores counts the physical performance and efficiency cores of an
// Intel hybrid CPU from the PMU device lists cpu_core and cpu_atom. A P-core
// with Hyper-Threading lists two logical CPUs; they share one core_id within a
// package, so cores are counted by (package, core id). Without both lists
// (AMD, older Intel, VMs) it reports 0, 0.
func readHybridCores(root string) (pCores, eCores int) {
	count := func(pmu string) int {
		cpus := parseCPUList(readTrimmed(filepath.Join(root, "sys/devices", pmu, "cpus")))
		seen := map[string]bool{}
		for _, cpu := range cpus {
			topo := filepath.Join(root, "sys/devices/system/cpu", "cpu"+strconv.Itoa(cpu), "topology")
			pkg := readTrimmed(filepath.Join(topo, "physical_package_id"))
			core := readTrimmed(filepath.Join(topo, "core_id"))
			if core == "" {
				core = "cpu" + strconv.Itoa(cpu)
			}
			seen[pkg+"/"+core] = true
		}
		return len(seen)
	}
	pCores, eCores = count("cpu_core"), count("cpu_atom")
	if pCores == 0 || eCores == 0 {
		return 0, 0
	}
	return pCores, eCores
}

// parseCPUList reads the kernel's cpulist format: "0-11,16,18-19".
func parseCPUList(list string) []int {
	var cpus []int
	for part := range strings.SplitSeq(list, ",") {
		part = strings.TrimSpace(part)
		if part == "" {
			continue
		}
		lo, hi, isRange := strings.Cut(part, "-")
		start, err := strconv.Atoi(lo)
		if err != nil {
			return nil
		}
		end := start
		if isRange {
			if end, err = strconv.Atoi(hi); err != nil || end < start || end-start > 4096 {
				return nil
			}
		}
		for c := start; c <= end; c++ {
			cpus = append(cpus, c)
		}
	}
	return cpus
}
