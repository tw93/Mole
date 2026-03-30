//go:build darwin

package main

import (
	"context"
	"os/exec"
	"strings"
	"syscall"
	"time"
)

func collectHardware() hardwareProfile {
	hw := hardwareProfile{ThermalOK: true}

	// Global timeout for ALL hardware collection.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	out, err := exec.CommandContext(ctx, "system_profiler", "SPHardwareDataType").Output()
	if err == nil {
		spOutput := string(out)
		hw.Model = parseSystemProfilerValue(spOutput, "Model Name")
		modelID := parseSystemProfilerValue(spOutput, "Model Identifier")
		if modelID != "" {
			hw.Model += " (" + modelID + ")"
		}
		hw.Chip = parseSystemProfilerValue(spOutput, "Chip")
		hw.RAM = parseSystemProfilerValue(spOutput, "Memory")
	}

	var stat syscall.Statfs_t
	if err := syscall.Statfs("/", &stat); err == nil {
		total := stat.Blocks * uint64(stat.Bsize)
		free := stat.Bavail * uint64(stat.Bsize)
		hw.SSDTotal = humanizeBytes(int64(total))
		hw.SSDFree = humanizeBytes(int64(free))
	}

	if out, err := exec.CommandContext(ctx, "sw_vers", "-productVersion").Output(); err == nil {
		hw.MacOS = strings.TrimSpace(string(out))
	}
	if out, err := exec.CommandContext(ctx, "sw_vers", "-buildVersion").Output(); err == nil {
		hw.Build = strings.TrimSpace(string(out))
	}

	if out, err := exec.CommandContext(ctx, "pmset", "-g", "thermlog").Output(); err == nil {
		hw.ThermalOK = parseThermalOK(string(out))
	}

	return hw
}

func parseSystemProfilerValue(output, key string) string {
	for _, line := range strings.Split(output, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, key+":") {
			parts := strings.SplitN(trimmed, ":", 2)
			if len(parts) == 2 {
				return strings.TrimSpace(parts[1])
			}
		}
	}
	return ""
}

func parseThermalOK(output string) bool {
	if strings.Contains(output, "No thermal warning") {
		return true
	}
	if strings.Contains(output, "Speed Limit") ||
		strings.Contains(output, "CPU_Thermal") ||
		strings.Contains(output, "GPU_Thermal") ||
		strings.Contains(output, "thermal warning level") {
		return false
	}
	// Default true for unrecognized output — pmset may vary across macOS versions.
	return true
}
