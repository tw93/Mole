//go:build darwin

package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
	"time"
)

func checkPerformance() categoryResult {
	checks := []checkResult{
		checkRAMPressure(),
		checkSwapUsage(),
		checkUptime(),
	}
	return buildCategory("Performance", scorePerformance, checks)
}

func checkRAMPressure() checkResult {
	r := checkResult{Name: "RAM usage", MaxScore: 10}

	out, err := exec.Command("sysctl", "-n", "hw.memsize").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read memory info"
		return r
	}
	totalBytes, err2 := strconv.ParseInt(strings.TrimSpace(string(out)), 10, 64)
	if err2 != nil || totalBytes <= 0 {
		r.Status = statusSkipped
		r.Detail = "Could not parse memory size"
		return r
	}

	vmOut, err := exec.Command("vm_stat").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read vm_stat"
		return r
	}

	pageSize := int64(16384)
	psSizeOut, err := exec.Command("sysctl", "-n", "vm.pagesize").Output()
	if err == nil {
		ps, _ := strconv.ParseInt(strings.TrimSpace(string(psSizeOut)), 10, 64)
		if ps > 0 {
			pageSize = ps
		}
	}

	var freePages, inactivePages, wiredPages, compressedPages int64
	for line := range strings.SplitSeq(string(vmOut), "\n") {
		if strings.HasPrefix(line, "Pages free:") {
			freePages = parseVMStatValue(line)
		} else if strings.HasPrefix(line, "Pages inactive:") {
			inactivePages = parseVMStatValue(line)
		} else if strings.HasPrefix(line, "Pages wired down:") {
			wiredPages = parseVMStatValue(line)
		} else if strings.HasPrefix(line, "Pages occupied by compressor:") {
			compressedPages = parseVMStatValue(line)
		}
	}

	usedBytes := (wiredPages + compressedPages) * pageSize
	availableBytes := (freePages + inactivePages) * pageSize
	if usedBytes <= 0 {
		// Fallback: estimate used as total minus available.
		usedBytes = totalBytes - availableBytes
	} else {
		_ = availableBytes // used for fallback only
	}
	if usedBytes < 0 {
		usedBytes = 0
	}
	ratio := float64(usedBytes) / float64(totalBytes)

	totalGB := float64(totalBytes) / (1024 * 1024 * 1024)
	usedGB := float64(usedBytes) / (1024 * 1024 * 1024)
	r.Detail = fmt.Sprintf("%.1f/%.1f GB used", usedGB, totalGB)

	if ratio > ramHighUsage {
		r.Status = statusFail
		r.Score = 3
	} else if ratio > ramMediumUsage {
		r.Status = statusWarn
		r.Score = 7
	} else {
		r.Status = statusPass
		r.Score = 10
	}
	return r
}

func checkSwapUsage() checkResult {
	r := checkResult{Name: "Swap usage", MaxScore: 5}

	out, err := exec.Command("sysctl", "-n", "vm.swapusage").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read swap info"
		return r
	}

	var usedMB float64
	parts := strings.Fields(string(out))
	for i, p := range parts {
		if p == "used" && i+2 < len(parts) {
			raw := parts[i+2]
			val := strings.TrimRight(raw, "MmGgKkBb")
			parsed, parseErr := strconv.ParseFloat(val, 64)
			if parseErr != nil {
				break
			}
			switch {
			case strings.HasSuffix(raw, "G"):
				usedMB = parsed * 1024
			case strings.HasSuffix(raw, "K"):
				usedMB = parsed / 1024
			default:
				usedMB = parsed
			}
			break
		}
	}

	usedGB := usedMB / 1024
	r.Detail = fmt.Sprintf("%.1f GB swap used", usedGB)

	if usedGB > swapHighGB {
		r.Status = statusFail
		r.Score = 0
	} else if usedGB > swapMediumGB {
		r.Status = statusWarn
		r.Score = 3
	} else {
		r.Status = statusPass
		r.Score = 5
	}
	return r
}

func checkUptime() checkResult {
	r := checkResult{Name: "Uptime", MaxScore: 5}

	out, err := exec.Command("sysctl", "-n", "kern.boottime").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read boot time"
		return r
	}

	s := string(out)
	idx := strings.Index(s, "sec = ")
	if idx < 0 {
		r.Status = statusSkipped
		r.Detail = "Could not parse boot time"
		return r
	}

	secStr := s[idx+6:]
	commaIdx := strings.Index(secStr, ",")
	if commaIdx > 0 {
		secStr = secStr[:commaIdx]
	}
	sec, err3 := strconv.ParseInt(strings.TrimSpace(secStr), 10, 64)
	if err3 != nil || sec <= 0 {
		r.Status = statusSkipped
		r.Detail = "Could not parse boot time"
		return r
	}
	bootTime := time.Unix(sec, 0)
	days := int(time.Since(bootTime).Hours() / 24)

	r.Detail = fmt.Sprintf("%d days since last restart", days)

	if days > uptimeWarningDays {
		r.Status = statusWarn
		r.Score = 0
	} else if days > uptimeCautionDays {
		r.Status = statusWarn
		r.Score = 3
	} else {
		r.Status = statusPass
		r.Score = 5
	}
	return r
}

func parseVMStatValue(line string) int64 {
	parts := strings.SplitN(line, ":", 2)
	if len(parts) < 2 {
		return 0
	}
	s := strings.TrimSpace(parts[1])
	s = strings.TrimSuffix(s, ".")
	val, _ := strconv.ParseInt(s, 10, 64)
	return val
}
