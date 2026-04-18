package main

import (
	"fmt"
	"strings"
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

	// Battery.
	batteryCycleWarn   = 500
	batteryCycleDanger = 900
	batteryCapWarn     = 90
	batteryCapDanger   = 80

	// Uptime (seconds).
	uptimeWarnDays   = 7
	uptimeDangerDays = 14
	uptimeWarnSecs   = uptimeWarnDays * 86400
	uptimeDangerSecs = uptimeDangerDays * 86400
)

func calculateHealthScore(cpu CPUStatus, mem MemoryStatus, disks []DiskStatus, diskIO DiskIOStatus, thermal ThermalStatus, batteries []BatteryStatus, uptimeSecs uint64) (int, string) {
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
		issues = append(issues, t("High CPU", "Yüksek İşlemci"))
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
		issues = append(issues, t("High Memory", "Yüksek Bellek"))
	}

	// Memory pressure penalty.
	switch mem.Pressure {
	case "warn":
		score -= memPressureWarnPenalty
		issues = append(issues, t("Memory Pressure", "Bellek Baskısı"))
	case "critical":
		score -= memPressureCritPenalty
		issues = append(issues, t("Critical Memory", "Kritik Bellek"))
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
			issues = append(issues, t("Disk Almost Full", "Disk Dolmak Üzere"))
		}
	}

	// Thermal penalty.
	thermalPenalty := 0.0
	if thermal.CPUTemp > 0 {
		if thermal.CPUTemp > thermalNormalThreshold {
			if thermal.CPUTemp > thermalHighThreshold {
				thermalPenalty = healthThermalWeight
				issues = append(issues, t("Overheating", "Aşırı Isınma"))
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
			issues = append(issues, t("Heavy Disk IO", "Yoğun Disk İşlemi"))
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
			issues = append(issues, t("Battery Service Soon", "Pile Servis Gerekli"))
		case "warn":
			score -= 2
		}
	}

	// Uptime penalty (long uptime without restart).
	if uptimeSecs > uptimeDangerSecs {
		score -= 3
		issues = append(issues, t("Restart Recommended", "Yeniden Başlatma Önerilir"))
	} else if uptimeSecs > uptimeWarnSecs {
		score -= 1
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
	case score >= 90:
		msg = t("Excellent", "Mükemmel")
	case score >= 75:
		msg = t("Good", "İyi")
	case score >= 60:
		msg = t("Fair", "Orta")
	case score >= 40:
		msg = t("Poor", "Zayıf")
	default:
		msg = t("Critical", "Kritik")
	}

	if len(issues) > 0 {
		msg = msg + ": " + strings.Join(issues, ", ")
	}

	return int(score), msg
}

// batteryHealthLabel returns a human-readable health label and severity based on cycle count and capacity.
// Severity is "ok", "warn", or "danger".
func batteryHealthLabel(cycles int, capacity int) (string, string) {
	if cycles > batteryCycleDanger || (capacity > 0 && capacity < batteryCapDanger) {
		return t("Service Soon", "Servis Gerekli"), "danger"
	}
	if cycles > batteryCycleWarn || (capacity > 0 && capacity < batteryCapWarn) {
		return t("Fair", "Orta"), "warn"
	}
	return t("Healthy", "Sağlıklı"), "ok"
}

// uptimeSeverity returns "ok", "warn", or "danger" based on uptime seconds.
func uptimeSeverity(secs uint64) string {
	if secs > uptimeDangerSecs {
		return "danger"
	}
	if secs > uptimeWarnSecs {
		return "warn"
	}
	return "ok"
}

func formatUptime(secs uint64) string {
	days := secs / 86400
	hours := (secs % 86400) / 3600
	mins := (secs % 3600) / 60
	if days > 0 {
		return fmt.Sprintf(t("%dd %dh", "%dgn %dsa"), days, hours)
	}
	if hours > 0 {
		return fmt.Sprintf(t("%dh %dm", "%dsa %ddk"), hours, mins)
	}
	return fmt.Sprintf(t("%dm", "%ddk"), mins)
}
