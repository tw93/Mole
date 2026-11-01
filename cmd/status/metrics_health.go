package main

import (
	"fmt"
	"strings"
)

// Health score weights and thresholds.
//
// Score = 100 minus these penalties, clamped to 0..100:
//
//	CPU        up to 30   linear above 50% usage
//	memory     up to 25   linear above 60% "used" (Linux used excludes cache,
//	                      so 60% is already a busy machine)
//	pressure   5 / 15     PSI warn / critical (/proc/pressure/memory)
//	swap       up to 20   swapFrac * tightness, see swapPenalty
//	disk       up to 20   root filesystem above 80% full
//	thermal    up to 15   CPU temperature above 65 C
//	disk IO    up to 10   above 50 MB/s combined
//	battery    2 / 5      worn or high-cycle battery
//	restart    3          only when a pending kernel update is detected
//
// A VM at 72% memory used with swap 100% full scores
// 100 - 6.0 (memory) - 20 (swap) = 74, "Good" with "Swap Full", where the
// macOS-derived formula (70% threshold, no swap term) said 98.
const (
	// Weights.
	healthCPUWeight     = 30.0
	healthMemWeight     = 25.0
	healthDiskWeight    = 20.0
	healthThermalWeight = 15.0
	healthIOWeight      = 10.0

	// CPU.
	cpuNormalThreshold = 50.0
	cpuHighThreshold   = 85.0

	// Memory.
	memNormalThreshold     = 60.0
	memHighThreshold       = 85.0
	memPressureWarnPenalty = 5.0
	memPressureCritPenalty = 15.0

	// Swap: the share of swap in use only hurts when RAM is also tight, since
	// a mostly idle machine parks cold pages in swap harmlessly.
	healthSwapWeight   = 20.0
	swapIgnoreFraction = 0.20 // swap use below this is noise
	swapTightnessLow   = 30.0 // memory used% where swap stops mattering
	swapTightnessHigh  = 60.0 // memory used% where swap counts fully
	restartPenalty     = 3.0

	// Disk.
	diskWarnThreshold = 80.0
	diskCritThreshold = 93.0

	// Thermal.
	thermalNormalThreshold = 65.0
	thermalHighThreshold   = 85.0

	// Disk IO (MB/s).
	ioNormalThreshold = 50.0
	ioHighThreshold   = 150.0

	// Battery.
	batteryCycleWarn   = 800
	batteryCycleDanger = 900
	batteryCapWarn     = 80
	batteryCapDanger   = 60

	// Score display bands (shared with view.go score styling).
	scoreExcellentThreshold = 85
	scoreGoodThreshold      = 65
	scoreFairThreshold      = 45
)

func calculateHealthScore(cpu CPUStatus, mem MemoryStatus, disks []DiskStatus, diskIO DiskIOStatus, thermal ThermalStatus, batteries []BatteryStatus, restartReason string) (int, string) {
	score := 100.0
	issues := []string{}

	// CPU penalty.
	cpuPenalty := 0.0
	if cpu.Usage > cpuNormalThreshold {
		if cpu.Usage > cpuHighThreshold {
			// Scale across the remaining range up to 100% so the penalty keeps
			// growing with usage (matches the disk branch). Dividing by the raw
			// high threshold instead made the penalty drop past 85%, letting the
			// score rise as CPU load got worse.
			cpuPenalty = healthCPUWeight * (cpu.Usage - cpuNormalThreshold) / (100 - cpuNormalThreshold)
		} else {
			cpuPenalty = (healthCPUWeight / 2) * (cpu.Usage - cpuNormalThreshold) / (cpuHighThreshold - cpuNormalThreshold)
		}
	}
	score -= cpuPenalty
	if cpu.Usage > cpuHighThreshold {
		issues = append(issues, "High CPU")
	}

	// Memory penalty.
	memPenalty := 0.0
	if mem.UsedPercent > memNormalThreshold {
		if mem.UsedPercent > memHighThreshold {
			// Scale across the remaining range up to 100% so the penalty keeps
			// growing with usage (matches the disk branch). Dividing by the raw
			// normal threshold instead made the penalty drop past 88%, letting
			// the score rise as memory pressure got worse.
			memPenalty = healthMemWeight * (mem.UsedPercent - memNormalThreshold) / (100 - memNormalThreshold)
		} else {
			memPenalty = (healthMemWeight / 2) * (mem.UsedPercent - memNormalThreshold) / (memHighThreshold - memNormalThreshold)
		}
	}
	score -= memPenalty
	if mem.UsedPercent > memHighThreshold {
		issues = append(issues, "High Memory")
	}

	// Memory pressure penalty.
	switch mem.Pressure {
	case "warn":
		score -= memPressureWarnPenalty
		issues = append(issues, "Memory Pressure")
	case "critical":
		score -= memPressureCritPenalty
		issues = append(issues, "Critical Memory")
	}

	// Swap penalty.
	if penalty := swapPenalty(mem); penalty > 0 {
		score -= penalty
		if mem.SwapTotal > 0 && float64(mem.SwapUsed)/float64(mem.SwapTotal) >= 0.95 {
			issues = append(issues, "Swap Full")
		} else {
			issues = append(issues, "Heavy Swap")
		}
	}

	// Disk penalty.
	diskPenalty := 0.0
	if len(disks) > 0 {
		diskUsage := disks[0].UsedPercent
		if diskUsage > diskWarnThreshold {
			if diskUsage > diskCritThreshold {
				diskPenalty = healthDiskWeight * (diskUsage - diskWarnThreshold) / (100 - diskWarnThreshold)
			} else {
				diskPenalty = (healthDiskWeight / 2) * (diskUsage - diskWarnThreshold) / (diskCritThreshold - diskWarnThreshold)
			}
		}
		score -= diskPenalty
		if diskUsage > diskCritThreshold {
			issues = append(issues, "Disk Almost Full")
		}
	}
	for _, disk := range disks {
		if disk.SmartStatus == smartStatusFailing {
			if score > 44 {
				score = 44
			}
			issues = append(issues, "Disk SMART Failing")
			break
		}
	}

	// Thermal penalty.
	thermalPenalty := 0.0
	if thermal.CPUTemp > 0 {
		if thermal.CPUTemp > thermalNormalThreshold {
			if thermal.CPUTemp > thermalHighThreshold {
				thermalPenalty = healthThermalWeight
				issues = append(issues, "Overheating")
			} else {
				thermalPenalty = healthThermalWeight * (thermal.CPUTemp - thermalNormalThreshold) / (thermalHighThreshold - thermalNormalThreshold)
			}
		}
		score -= thermalPenalty
	}

	// Disk IO penalty.
	ioPenalty := 0.0
	totalIO := diskIO.ReadRate + diskIO.WriteRate
	if totalIO > ioNormalThreshold {
		if totalIO > ioHighThreshold {
			ioPenalty = healthIOWeight
			issues = append(issues, "Heavy Disk IO")
		} else {
			ioPenalty = healthIOWeight * (totalIO - ioNormalThreshold) / (ioHighThreshold - ioNormalThreshold)
		}
	}
	score -= ioPenalty

	// Battery health penalty (only when battery present).
	if len(batteries) > 0 {
		b := batteries[0]
		_, sev := batteryHealthLabel(b.CycleCount, b.Capacity)
		switch sev {
		case "danger":
			score -= 5
			issues = append(issues, "Battery Service Soon")
		case "warn":
			score -= 2
		}
	}

	// Restart penalty: only with a Linux-specific reason, never uptime alone.
	if restartReason != "" {
		score -= restartPenalty
		issues = append(issues, "Restart Recommended")
	}

	// Clamp score.
	if score < 0 {
		score = 0
	}
	if score > 100 {
		score = 100
	}

	// Build message.
	var msg string
	switch {
	case score >= scoreExcellentThreshold:
		msg = "Excellent"
	case score >= scoreGoodThreshold:
		msg = "Good"
	case score >= scoreFairThreshold:
		msg = "Fair"
	default:
		msg = "Needs Attention"
	}

	if len(issues) > 0 {
		msg = msg + ": " + strings.Join(issues, ", ")
	}

	return int(score), msg
}

// swapPenalty scales healthSwapWeight by how much of swap is in use (zero up
// to swapIgnoreFraction, full at 100%) and by how tight RAM is (zero at 30%
// used, full from 60%). Without swap there is nothing to penalize here; the
// memory term already covers a full machine.
func swapPenalty(mem MemoryStatus) float64 {
	if mem.SwapTotal == 0 {
		return 0
	}
	frac := float64(mem.SwapUsed) / float64(mem.SwapTotal)
	frac = (frac - swapIgnoreFraction) / (1 - swapIgnoreFraction)
	frac = max(0, min(1, frac))
	tight := (mem.UsedPercent - swapTightnessLow) / (swapTightnessHigh - swapTightnessLow)
	tight = max(0, min(1, tight))
	return healthSwapWeight * frac * tight
}

// batteryHealthLabel returns a human-readable health label and severity based on cycle count and capacity.
// Severity is "ok", "warn", "danger", or "unknown" (no label).
func batteryHealthLabel(cycles int, capacity int) (string, string) {
	if cycles > batteryCycleDanger || (capacity > 0 && capacity < batteryCapDanger) {
		return "Service Soon", "danger"
	}
	if cycles > batteryCycleWarn || (capacity > 0 && capacity < batteryCapWarn) {
		return "Fair", "warn"
	}
	if capacity <= 0 {
		return "", "unknown"
	}
	return "Healthy", "ok"
}

func formatUptime(secs uint64) string {
	days := secs / 86400
	hours := (secs % 86400) / 3600
	mins := (secs % 3600) / 60
	if days > 0 {
		// Only show days and hours when uptime is over 1 day (skip minutes for brevity)
		return fmt.Sprintf("%dd %dh", days, hours)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, mins)
	}
	return fmt.Sprintf("%dm", mins)
}
