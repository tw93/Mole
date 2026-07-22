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
	macGPUUsageTTL        = 5 * time.Second
	powermetricsTimeout   = 2 * time.Second
	ioregTimeout          = 1 * time.Second
)

// Regex for GPU usage parsing.
var (
	gpuActiveResidencyRe = regexp.MustCompile(`GPU HW active residency:\s+([\d.]+)%`)
	gpuIdleResidencyRe   = regexp.MustCompile(`GPU idle residency:\s+([\d.]+)%`)
	// IOKit exposes GPU load without root: AGXAccelerator's PerformanceStatistics
	// dict carries three whole-device utilization figures. Apple does not expose
	// any per-core/per-SM breakdown, so these three are the finest granularity
	// available. Read via `ioreg`.
	gpuDeviceUtilRe   = regexp.MustCompile(`"Device Utilization %"\s*=\s*(\d+)`)
	gpuRendererUtilRe = regexp.MustCompile(`"Renderer Utilization %"\s*=\s*(\d+)`)
	gpuTilerUtilRe    = regexp.MustCompile(`"Tiler Utilization %"\s*=\s*(\d+)`)
)

// gpuUsageSample holds the whole-device GPU utilization figures. Renderer and
// Tiler are -1 when unknown (e.g. the powermetrics fallback only yields Device).
type gpuUsageSample struct {
	device   float64
	renderer float64
	tiler    float64
}

// unknownGPUUsage is the zero sample: nothing could be read.
var unknownGPUUsage = gpuUsageSample{device: -1, renderer: -1, tiler: -1}

func (c *Collector) collectGPU(now time.Time) ([]GPUStatus, error) {
	c.gpuMu.Lock()
	defer c.gpuMu.Unlock()

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
			usage := c.getMacGPUUsage(now)
			c.pushGPUHistory(usage)
			result := make([]GPUStatus, len(c.cachedGPU))
			copy(result, c.cachedGPU)
			// Apply usage to first GPU (Apple Silicon).
			if len(result) > 0 {
				result[0].Usage = usage.device
				result[0].Renderer = usage.renderer
				result[0].Tiler = usage.tiler
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
			Renderer:    -1, // not exposed outside Apple Silicon
			Tiler:       -1,
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
			Renderer:  -1,
			Tiler:     -1,
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

// gpuHistorySnapshot returns a copy of the GPU history buffers. It takes the
// GPU lock so it is safe to call from the main collection goroutine while the
// dedicated GPU tick pushes new samples.
func (c *Collector) gpuHistorySnapshot() GPUHistory {
	c.gpuMu.Lock()
	defer c.gpuMu.Unlock()
	return c.gpuHistoryLocked()
}

// gpuHistoryLocked reads the history buffers. The caller must hold gpuMu.
func (c *Collector) gpuHistoryLocked() GPUHistory {
	hist := GPUHistory{}
	if c.gpuDeviceHistBuf != nil {
		hist.DeviceHistory = c.gpuDeviceHistBuf.Slice()
	}
	if c.gpuRendererHistBuf != nil {
		hist.RendererHistory = c.gpuRendererHistBuf.Slice()
	}
	if c.gpuTilerHistBuf != nil {
		hist.TilerHistory = c.gpuTilerHistBuf.Slice()
	}
	return hist
}

// pushGPUHistory records one GPU utilization sample into the ring buffers.
// Unknown figures (-1) are stored as 0 so the sparkline stays well-formed.
// Buffers are lazily created to stay robust if a Collector was built directly.
func (c *Collector) pushGPUHistory(u gpuUsageSample) {
	if c.gpuDeviceHistBuf == nil {
		c.gpuDeviceHistBuf = NewRingBuffer(GPUHistorySize)
	}
	if c.gpuRendererHistBuf == nil {
		c.gpuRendererHistBuf = NewRingBuffer(GPUHistorySize)
	}
	if c.gpuTilerHistBuf == nil {
		c.gpuTilerHistBuf = NewRingBuffer(GPUHistorySize)
	}
	c.gpuDeviceHistBuf.Add(max(u.device, 0))
	c.gpuRendererHistBuf.Add(max(u.renderer, 0))
	c.gpuTilerHistBuf.Add(max(u.tiler, 0))
}

func (c *Collector) getMacGPUUsage(now time.Time) gpuUsageSample {
	if !c.lastGPUUsageAt.IsZero() && now.Sub(c.lastGPUUsageAt) < macGPUUsageTTL {
		return c.cachedGPUUsage
	}

	usage := getMacGPUUsage()
	c.cachedGPUUsage = usage
	c.lastGPUUsageAt = now
	return usage
}

// getMacGPUUsage returns the current GPU utilization figures, or unknownGPUUsage
// if none can be read. It prefers IOKit via ioreg (no root required) and falls
// back to powermetrics (which usually needs root) only when ioreg yields nothing.
func getMacGPUUsage() gpuUsageSample {
	if usage := getMacGPUUsageIOReg(); usage.device >= 0 {
		return usage
	}
	return getMacGPUUsagePowermetrics()
}

// getMacGPUUsageIOReg reads the Device/Renderer/Tiler utilization figures from
// AGXAccelerator's PerformanceStatistics dict, without elevated privileges. A
// figure whose key is absent stays -1.
func getMacGPUUsageIOReg() gpuUsageSample {
	ctx, cancel := context.WithTimeout(context.Background(), ioregTimeout)
	defer cancel()

	if !commandExists("ioreg") {
		return unknownGPUUsage
	}
	out, err := runCmd(ctx, "ioreg", "-r", "-c", "AGXAccelerator", "-d", "1")
	if err != nil {
		return unknownGPUUsage
	}

	return gpuUsageSample{
		device:   parseGPUUtil(gpuDeviceUtilRe, out),
		renderer: parseGPUUtil(gpuRendererUtilRe, out),
		tiler:    parseGPUUtil(gpuTilerUtilRe, out),
	}
}

// parseGPUUtil returns the first integer captured by re in text, or -1.
func parseGPUUtil(re *regexp.Regexp, text string) float64 {
	m := re.FindStringSubmatch(text)
	if len(m) >= 2 {
		if v, err := strconv.ParseFloat(m[1], 64); err == nil {
			return v
		}
	}
	return -1
}

// getMacGPUUsagePowermetrics reads GPU active residency from powermetrics. It
// only yields the overall device figure; Renderer/Tiler remain unknown.
func getMacGPUUsagePowermetrics() gpuUsageSample {
	ctx, cancel := context.WithTimeout(context.Background(), powermetricsTimeout)
	defer cancel()

	// powermetrics may require root.
	out, err := runCmd(ctx, "powermetrics", "--samplers", "gpu_power", "-i", "500", "-n", "1")
	if err != nil {
		return unknownGPUUsage
	}

	sample := unknownGPUUsage
	// Parse "GPU HW active residency: X.XX%".
	if m := gpuActiveResidencyRe.FindStringSubmatch(out); len(m) >= 2 {
		if usage, err := strconv.ParseFloat(m[1], 64); err == nil {
			sample.device = usage
			return sample
		}
	}
	// Fallback: parse idle residency and derive active.
	if m := gpuIdleResidencyRe.FindStringSubmatch(out); len(m) >= 2 {
		if idle, err := strconv.ParseFloat(m[1], 64); err == nil {
			sample.device = 100.0 - idle
			return sample
		}
	}
	return unknownGPUUsage
}
