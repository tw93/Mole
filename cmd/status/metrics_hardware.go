package main

import (
	"context"
	"fmt"
	"runtime"
	"strings"
	"time"
)

func collectHardware(totalRAM uint64, disks []DiskStatus) HardwareInfo {
	if runtime.GOOS != "darwin" {
		return HardwareInfo{
			Model:       "Unknown",
			CPUModel:    runtime.GOARCH,
			TotalRAM:    humanBytes(totalRAM),
			DiskSize:    "Unknown",
			OSVersion:   runtime.GOOS,
			RefreshRate: "",
		}
	}

	// Model and CPU from system_profiler.
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	var model, cpuModel, osVersion, refreshRate string

	out, err := runCmd(ctx, "system_profiler", "SPHardwareDataType")
	if err == nil {
		for line := range strings.Lines(out) {
			lower := strings.ToLower(strings.TrimSpace(line))
			// Prefer "Model Name" over "Model Identifier".
			if strings.Contains(lower, "model name:") {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					model = strings.TrimSpace(parts[1])
				}
			}
			if strings.Contains(lower, "chip:") {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					cpuModel = strings.TrimSpace(parts[1])
				}
			}
			if strings.Contains(lower, "processor name:") && cpuModel == "" {
				parts := strings.Split(line, ":")
				if len(parts) == 2 {
					cpuModel = strings.TrimSpace(parts[1])
				}
			}
		}
	}

	ctx2, cancel2 := context.WithTimeout(context.Background(), 1*time.Second)
	defer cancel2()
	out2, err := runCmd(ctx2, "sw_vers", "-productVersion")
	if err == nil {
		osVersion = "macOS " + strings.TrimSpace(out2)
	}

	// Get refresh rate from display info (use mini detail to keep it fast).
	ctx3, cancel3 := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel3()
	out3, err := runCmd(ctx3, "system_profiler", "-detailLevel", "mini", "SPDisplaysDataType")
	if err == nil {
		refreshRate = parseRefreshRate(out3)
	}

	diskSize := "Unknown"
	if len(disks) > 0 {
		diskSize = humanBytes(disks[0].Total)
	}

	return HardwareInfo{
		Model:       model,
		CPUModel:    cpuModel,
		TotalRAM:    humanBytes(totalRAM),
		DiskSize:    diskSize,
		OSVersion:   osVersion,
		RefreshRate: refreshRate,
	}
}

// parseRefreshRate extracts the highest refresh rate from system_profiler display output.
func parseRefreshRate(output string) string {
	maxHz := 0

	for line := range strings.Lines(output) {
		lower := strings.ToLower(line)
		// Look for patterns like "@ 60Hz", "@ 60.00Hz", or "Refresh Rate: 120 Hz".
		if strings.Contains(lower, "hz") {
			fields := strings.Fields(lower)
			for i, field := range fields {
				if field == "hz" && i > 0 {
					if hz := parseInt(fields[i-1]); hz > maxHz && hz < 500 {
						maxHz = hz
					}
					continue
				}
				if numStr, ok := strings.CutSuffix(field, "hz"); ok {
					if numStr == "" && i > 0 {
						numStr = fields[i-1]
					}
					if hz := parseInt(numStr); hz > maxHz && hz < 500 {
						maxHz = hz
					}
				}
			}
		}
	}

	if maxHz > 0 {
		return fmt.Sprintf("%dHz", maxHz)
	}
	return ""
}

// parseInt safely parses an integer from a string.
func parseInt(s string) int {
	// Trim away non-numeric padding, keep digits and '.' for decimals.
	cleaned := strings.TrimSpace(s)
	cleaned = strings.TrimLeftFunc(cleaned, func(r rune) bool {
		return (r < '0' || r > '9') && r != '.'
	})
	cleaned = strings.TrimRightFunc(cleaned, func(r rune) bool {
		return (r < '0' || r > '9') && r != '.'
	})
	if cleaned == "" {
		return 0
	}
	var num int
	fmt.Sscanf(cleaned, "%d", &num)
	return num
}
