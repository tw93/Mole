package main

import (
	"context"
	"fmt"
	"runtime"
	"strings"
	"sync"
	"time"
)

// collectHardwareStatic runs the slow subprocess half of the hardware card.
// collectFull schedules it inside its concurrent burst; finishHardware fills
// the fields that depend on that burst's memory and disk results.
func collectHardwareStatic() HardwareInfo {
	if runtime.GOOS != "darwin" {
		return HardwareInfo{
			Model:       "Unknown",
			CPUModel:    runtime.GOARCH,
			OSVersion:   runtime.GOOS,
			RefreshRate: "",
		}
	}

	// The three probes are independent, so they run at once; each keeps its
	// own timeout and the card waits only for the slowest one.
	var (
		model, cpuModel, osVersion, refreshRate string
		wg                                      sync.WaitGroup
	)

	// Model and CPU from system_profiler.
	wg.Go(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		defer cancel()
		out, err := runCmd(ctx, "system_profiler", "SPHardwareDataType")
		if err == nil {
			model, cpuModel = parseHardwareModel(out)
		}
	})

	wg.Go(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 1*time.Second)
		defer cancel()
		out, err := runCmd(ctx, "sw_vers", "-productVersion")
		if err == nil {
			osVersion = "macOS " + strings.TrimSpace(out)
		}
	})

	// Get refresh rate from display info (use mini detail to keep it fast).
	wg.Go(func() {
		ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
		defer cancel()
		out, err := runCmd(ctx, "system_profiler", "-detailLevel", "mini", "SPDisplaysDataType")
		if err == nil {
			refreshRate = parseRefreshRate(out)
		}
	})

	wg.Wait()

	return HardwareInfo{
		Model:       model,
		CPUModel:    cpuModel,
		OSVersion:   osVersion,
		RefreshRate: refreshRate,
	}
}

// parseHardwareModel reads the model name and chip (or Intel processor name)
// from `system_profiler SPHardwareDataType`.
func parseHardwareModel(out string) (model, cpuModel string) {
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
	return model, cpuModel
}

func finishHardware(hw HardwareInfo, totalRAM uint64, disks []DiskStatus) HardwareInfo {
	hw.TotalRAM = humanBytes(totalRAM)
	hw.DiskSize = "Unknown"
	if runtime.GOOS == "darwin" && len(disks) > 0 {
		hw.DiskSize = humanBytes(disks[0].Total)
	}
	return hw
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
	if _, err := fmt.Sscanf(cleaned, "%d", &num); err != nil {
		return 0
	}
	return num
}
