package main

import (
	"fmt"
	"strings"

	molei18n "github.com/tw93/mole/internal/i18n"
)

// Health score weights and thresholds.
const (
	// Weights.
	healthCPUWeight     = 30.0
	healthMemWeight     = 25.0
	healthDiskWeight    = 20.0
	healthThermalWeight = 15.0
	healthIOWeight      = 10.0

	// CPU.
	cpuNormalThreshold = 30.0
	cpuHighThreshold   = 70.0

	// Memory.
	memNormalThreshold     = 50.0
	memHighThreshold       = 80.0
	memPressureWarnPenalty = 5.0
	memPressureCritPenalty = 15.0

	// Disk.
	diskWarnThreshold = 70.0
	diskCritThreshold = 90.0

	// Thermal.
	thermalNormalThreshold = 60.0
	thermalHighThreshold   = 85.0

	// Disk IO (MB/s).
	ioNormalThreshold = 50.0
	ioHighThreshold   = 150.0
)

func calculateHealthScore(cpu CPUStatus, mem MemoryStatus, disks []DiskStatus, diskIO DiskIOStatus, thermal ThermalStatus) (int, string) {
	score := 100.0
	issues := []string{}

	// CPU penalty.
	cpuPenalty := 0.0
	if cpu.Usage > cpuNormalThreshold {
		if cpu.Usage > cpuHighThreshold {
			cpuPenalty = healthCPUWeight * (cpu.Usage - cpuNormalThreshold) / cpuHighThreshold
		} else {
			cpuPenalty = (healthCPUWeight / 2) * (cpu.Usage - cpuNormalThreshold) / (cpuHighThreshold - cpuNormalThreshold)
		}
	}
	score -= cpuPenalty
	if cpu.Usage > cpuHighThreshold {
		issues = append(issues, molei18n.T("High CPU"))
	}

	// Memory penalty.
	memPenalty := 0.0
	if mem.UsedPercent > memNormalThreshold {
		if mem.UsedPercent > memHighThreshold {
			memPenalty = healthMemWeight * (mem.UsedPercent - memNormalThreshold) / memNormalThreshold
		} else {
			memPenalty = (healthMemWeight / 2) * (mem.UsedPercent - memNormalThreshold) / (memHighThreshold - memNormalThreshold)
		}
	}
	score -= memPenalty
	if mem.UsedPercent > memHighThreshold {
		issues = append(issues, molei18n.T("High Memory"))
	}

	// Memory pressure penalty.
	switch mem.Pressure {
	case "warn":
		score -= memPressureWarnPenalty
		issues = append(issues, molei18n.T("Memory Pressure"))
	case "critical":
		score -= memPressureCritPenalty
		issues = append(issues, molei18n.T("Critical Memory"))
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
			issues = append(issues, molei18n.T("Disk Almost Full"))
		}
	}

	// Thermal penalty.
	thermalPenalty := 0.0
	if thermal.CPUTemp > 0 {
		if thermal.CPUTemp > thermalNormalThreshold {
			if thermal.CPUTemp > thermalHighThreshold {
				thermalPenalty = healthThermalWeight
				issues = append(issues, molei18n.T("Overheating"))
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
			issues = append(issues, molei18n.T("Heavy Disk IO"))
		} else {
			ioPenalty = healthIOWeight * (totalIO - ioNormalThreshold) / (ioHighThreshold - ioNormalThreshold)
		}
	}
	score -= ioPenalty

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
	case score >= 90:
		msg = molei18n.T("Excellent")
	case score >= 75:
		msg = molei18n.T("Good")
	case score >= 60:
		msg = molei18n.T("Fair")
	case score >= 40:
		msg = molei18n.T("Poor")
	default:
		msg = molei18n.T("Critical")
	}

	if len(issues) > 0 {
		msg = msg + ": " + strings.Join(issues, ", ")
	}

	return int(score), msg
}

func formatUptime(secs uint64) string {
	days := secs / 86400
	hours := (secs % 86400) / 3600
	mins := (secs % 3600) / 60
	if molei18n.IsChinese() {
		if days > 0 {
			return fmt.Sprintf("%d天 %d小时", days, hours)
		}
		if hours > 0 {
			return fmt.Sprintf("%d小时 %d分钟", hours, mins)
		}
		return fmt.Sprintf("%d分钟", mins)
	}
	if days > 0 {
		// Only show days and hours when uptime is over 1 day (skip minutes for brevity)
		return fmt.Sprintf("%dd %dh", days, hours)
	}
	if hours > 0 {
		return fmt.Sprintf("%dh %dm", hours, mins)
	}
	return fmt.Sprintf("%dm", mins)
}
