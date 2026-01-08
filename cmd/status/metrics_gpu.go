package main

import (
	"context"
	"encoding/json"
	"errors"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
)

const (
	systemProfilerTimeout = 4 * time.Second
	macGPUInfoTTL         = 10 * time.Minute
	powermetricsTimeout   = 2 * time.Second
)

// Regex for GPU usage parsing.
var (
	gpuActiveResidencyRe = regexp.MustCompile(`GPU HW active residency:\s+([\d.]+)%`)
	gpuIdleResidencyRe   = regexp.MustCompile(`GPU idle residency:\s+([\d.]+)%`)
)

func (c *Collector) collectGPU(now time.Time) ([]GPUStatus, error) {
	if runtime.GOOS == "darwin" {
		// Static GPU info (cached 10 min).
		if len(c.cachedGPU) == 0 || c.lastGPUAt.IsZero() || now.Sub(c.lastGPUAt) >= macGPUInfoTTL {
			if gpus, err := readMacGPUInfo(); err == nil && len(gpus) > 0 {
				c.cachedGPU = gpus
				c.lastGPUAt = now
			}
		}

		// Real-time GPU usage.
		if len(c.cachedGPU) > 0 {
			usage := getMacGPUUsage()
			result := make([]GPUStatus, len(c.cachedGPU))
			copy(result, c.cachedGPU)
			// Apply usage to first GPU (Apple Silicon).
			if len(result) > 0 {
				result[0].Usage = usage
			}
			return result, nil
		}
	}

	ctx, cancel := context.WithTimeout(context.Background(), 600*time.Millisecond)
	defer cancel()

	if !commandExists("nvidia-smi") {
		return []GPUStatus{{
			Name: "No GPU metrics available",
			Note: "Install nvidia-smi or use platform-specific metrics",
		}}, nil
	}

	out, err := runCmd(ctx, "nvidia-smi", "--query-gpu=utilization.gpu,memory.used,memory.total,name", "--format=csv,noheader,nounits")
	if err != nil {
		return nil, err
	}

	var gpus []GPUStatus
	for line := range strings.Lines(strings.TrimSpace(out)) {
		fields := strings.Split(line, ",")
		if len(fields) < 4 {
			continue
		}
		util, _ := strconv.ParseFloat(strings.TrimSpace(fields[0]), 64)
		memUsed, _ := strconv.ParseFloat(strings.TrimSpace(fields[1]), 64)
		memTotal, _ := strconv.ParseFloat(strings.TrimSpace(fields[2]), 64)
		name := strings.TrimSpace(fields[3])

		gpus = append(gpus, GPUStatus{
			Name:        name,
			Usage:       util,
			MemoryUsed:  memUsed,
			MemoryTotal: memTotal,
		})
	}

	if len(gpus) == 0 {
		return []GPUStatus{{
			Name: "GPU read failed",
			Note: "Verify nvidia-smi availability",
		}}, nil
	}

	return gpus, nil
}

func readMacGPUInfo() ([]GPUStatus, error) {
	ctx, cancel := context.WithTimeout(context.Background(), systemProfilerTimeout)
	defer cancel()

	if !commandExists("system_profiler") {
		return nil, errors.New("system_profiler unavailable")
	}

	out, err := runCmd(ctx, "system_profiler", "-json", "SPDisplaysDataType")
	if err != nil {
		return nil, err
	}

	var data struct {
		Displays []struct {
			Name   string `json:"_name"`
			VRAM   string `json:"spdisplays_vram"`
			Vendor string `json:"spdisplays_vendor"`
			Metal  string `json:"spdisplays_metal"`
			Cores  string `json:"sppci_cores"`
		} `json:"SPDisplaysDataType"`
	}
	if err := json.Unmarshal([]byte(out), &data); err != nil {
		return nil, err
	}

	var gpus []GPUStatus
	for _, d := range data.Displays {
		if d.Name == "" {
			continue
		}
		noteParts := []string{}
		if d.VRAM != "" {
			noteParts = append(noteParts, "VRAM "+d.VRAM)
		}
		if d.Metal != "" {
			noteParts = append(noteParts, d.Metal)
		}
		if d.Vendor != "" {
			noteParts = append(noteParts, d.Vendor)
		}
		note := strings.Join(noteParts, " · ")
		coreCount, _ := strconv.Atoi(d.Cores)
		gpus = append(gpus, GPUStatus{
			Name:      d.Name,
			Usage:     -1, // Will be updated with real-time data
			CoreCount: coreCount,
			Note:      note,
		})
	}

	if len(gpus) == 0 {
		return []GPUStatus{{
			Name: "GPU info unavailable",
			Note: "Unable to parse system_profiler output",
		}}, nil
	}

	return gpus, nil
}

// getMacGPUUsage reads GPU active residency from powermetrics.
func getMacGPUUsage() float64 {
	ctx, cancel := context.WithTimeout(context.Background(), powermetricsTimeout)
	defer cancel()

	// powermetrics may require root.
	out, err := runCmd(ctx, "powermetrics", "--samplers", "gpu_power", "-i", "500", "-n", "1")
	if err != nil {
		return -1
	}

	// Parse "GPU HW active residency: X.XX%".
	matches := gpuActiveResidencyRe.FindStringSubmatch(out)
	if len(matches) >= 2 {
		usage, err := strconv.ParseFloat(matches[1], 64)
		if err == nil {
			return usage
		}
	}

	// Fallback: parse idle residency and derive active.
	matchesIdle := gpuIdleResidencyRe.FindStringSubmatch(out)
	if len(matchesIdle) >= 2 {
		idle, err := strconv.ParseFloat(matchesIdle[1], 64)
		if err == nil {
			return 100.0 - idle
		}
	}

	return -1
}
