package main

import (
	"context"
	"math"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strconv"
	"strings"
	"time"
)

const (
	gpuInfoTTL      = 10 * time.Minute
	lspciTimeout    = 800 * time.Millisecond
	nvidiaSMIWait   = 600 * time.Millisecond
	pciVendorNVIDIA = "0x10de"
)

// pciVendorNames covers GPUs by PCI vendor id, read from sysfs with no tool.
var pciVendorNames = map[string]string{
	"0x10de": "NVIDIA",
	"0x1002": "AMD",
	"0x8086": "Intel",
	"0x1af4": "Virtio",
	"0x1234": "QEMU",
	"0x1b36": "QEMU",
	"0x15ad": "VMware",
	"0x1414": "Microsoft",
	"0x106b": "Apple",
	"0x5143": "Qualcomm",
}

var drmCardDir = regexp.MustCompile(`^card[0-9]+$`)

// collectGPU lists display adapters. Names come from sysfs vendor ids, refined
// by lspci when it is installed; a machine with no DRM device reports none and
// the field stays empty. Usage is read live where the driver exposes it.
func (c *Collector) collectGPU(now time.Time) ([]GPUStatus, error) {
	if c.lastGPUAt.IsZero() || now.Sub(c.lastGPUAt) >= gpuInfoTTL {
		c.cachedGPU = readGPUs("/", lspciNames)
		c.lastGPUAt = now
	}
	result := make([]GPUStatus, len(c.cachedGPU))
	copy(result, c.cachedGPU)
	if c.gpuIdle == nil {
		c.gpuIdle = make(gpuIdleTracker)
	}
	refreshGPUUsage("/", result, c.gpuIdle, now)
	return result, nil
}

type drmGPU struct {
	vendorID string
	slot     string // PCI slot such as 00:02.0, empty when not PCI
	pciAddr  string // full PCI address such as 0000:01:00.0, empty when not PCI
	dir      string // root/sys/class/drm/cardN/device
}

func listDRMGPUs(root string) []drmGPU {
	entries, err := os.ReadDir(filepath.Join(root, "sys/class/drm"))
	if err != nil {
		return nil
	}
	var gpus []drmGPU
	for _, e := range entries {
		if !drmCardDir.MatchString(e.Name()) {
			continue
		}
		dev := filepath.Join(root, "sys/class/drm", e.Name(), "device")
		vendor := strings.ToLower(readTrimmed(filepath.Join(dev, "vendor")))
		if vendor == "" {
			continue
		}
		slot, addr := "", ""
		if target, err := os.Readlink(dev); err == nil {
			addr = filepath.Base(target)
			slot = strings.TrimPrefix(addr, "0000:")
		}
		gpus = append(gpus, drmGPU{vendorID: vendor, slot: slot, pciAddr: addr, dir: dev})
	}
	sort.Slice(gpus, func(i, j int) bool { return gpus[i].dir < gpus[j].dir })
	return gpus
}

// readGPUs builds the static GPU list under root. names, when non-nil, maps a
// PCI slot to a device name from lspci. Cards with an unknown vendor id are
// left out.
func readGPUs(root string, names func() map[string]string) []GPUStatus {
	cards := listDRMGPUs(root)
	if len(cards) == 0 {
		return nil
	}
	var lspci map[string]string
	if names != nil {
		lspci = names()
	}
	var gpus []GPUStatus
	for _, card := range cards {
		vendor := pciVendorNames[card.vendorID]
		if vendor == "" {
			continue // refreshGPUUsage skips the same cards to stay aligned
		}
		name := lspci[card.slot]
		switch {
		case name != "":
			// lspci names include the vendor in the bracketed marketing name
			// ("Intel Corporation ... [Iris Xe Graphics]"); keep it readable.
			if vendor != "" && !strings.Contains(strings.ToLower(name), strings.ToLower(vendor)) {
				name = vendor + " " + name
			}
		default:
			name = vendor + " graphics"
		}
		gpus = append(gpus, GPUStatus{Name: name, Usage: -1})
	}
	return gpus
}

// gpuIdleTracker keeps the last idle-residency reading per card, so busy
// time can be derived from the change between two collections.
type gpuIdleTracker map[string]gpuIdleSample

type gpuIdleSample struct {
	idleMS int64
	at     time.Time
}

// gpuSuspended reports a device the kernel has runtime-suspended. Reading its
// counters (gpu_busy_percent, rc6 residency, nvidia-smi) would wake it and
// cost a laptop's dGPU its power savings, so a sleeping card is reported idle
// without touching it.
func gpuSuspended(card drmGPU) bool {
	switch readTrimmed(filepath.Join(card.dir, "power/runtime_status")) {
	case "suspended", "suspending":
		return true
	}
	return false
}

// refreshGPUUsage fills Usage from gpu_busy_percent (amdgpu, some others),
// nvidia-smi for NVIDIA cards (each queried by its own PCI address), and
// Intel's idle residency counters; adapters without a counter stay at -1.
func refreshGPUUsage(root string, gpus []GPUStatus, idle gpuIdleTracker, now time.Time) {
	cards := listDRMGPUs(root)
	idx := 0
	for _, card := range cards {
		if pciVendorNames[card.vendorID] == "" {
			continue
		}
		if idx >= len(gpus) {
			return
		}
		gpu := &gpus[idx]
		idx++
		if gpuSuspended(card) {
			gpu.Usage = 0
			gpu.Note = "suspended"
			delete(idle, card.dir)
			continue
		}
		if v, ok := readInt(filepath.Join(card.dir, "gpu_busy_percent")); ok && v >= 0 && v <= 100 {
			gpu.Usage = float64(v)
		} else if card.vendorID == pciVendorNVIDIA && card.pciAddr != "" && commandExists("nvidia-smi") {
			applyNvidiaSMI(gpu, card.pciAddr)
		} else if card.vendorID == "0x8086" {
			if busy, ok := intelBusyPercent(card, idle, now); ok {
				gpu.Usage = busy
			}
		}
	}
}

// intelIdleResidencyMS reads the render GT's cumulative idle time: i915's
// rc6_residency_ms (gt/gt0, or power/ on older kernels) or xe's
// gtidle/idle_residency_ms. Both are world-readable.
func intelIdleResidencyMS(card drmGPU) (int64, bool) {
	cardDir := filepath.Dir(card.dir)
	for _, path := range []string{
		filepath.Join(cardDir, "gt/gt0/rc6_residency_ms"),
		filepath.Join(cardDir, "power/rc6_residency_ms"),
		filepath.Join(card.dir, "tile0/gt0/gtidle/idle_residency_ms"),
	} {
		if v, ok := readInt(path); ok && v >= 0 {
			return v, true
		}
	}
	return 0, false
}

// intelBusyPercent turns the idle residency change since the previous
// collection into a busy percentage. The first reading only primes the
// tracker.
func intelBusyPercent(card drmGPU, idle gpuIdleTracker, now time.Time) (float64, bool) {
	if idle == nil {
		return 0, false
	}
	ms, ok := intelIdleResidencyMS(card)
	if !ok {
		return 0, false
	}
	prev, had := idle[card.dir]
	idle[card.dir] = gpuIdleSample{idleMS: ms, at: now}
	if !had {
		return 0, false
	}
	wall := now.Sub(prev.at).Milliseconds()
	if wall < 200 || ms < prev.idleMS {
		return 0, false
	}
	busy := 100 - float64(ms-prev.idleMS)*100/float64(wall)
	return math.Round(math.Max(0, math.Min(100, busy))), true
}

// nvidiaBusID turns a sysfs PCI address (0000:01:00.0) into nvidia-smi's form
// (00000000:01:00.0).
func nvidiaBusID(pciAddr string) string {
	domain, rest, ok := strings.Cut(pciAddr, ":")
	if !ok {
		return pciAddr
	}
	return strings.ToUpper(strings.Repeat("0", max(0, 8-len(domain)))+domain) + ":" + strings.ToUpper(rest)
}

func applyNvidiaSMI(gpu *GPUStatus, pciAddr string) {
	ctx, cancel := context.WithTimeout(context.Background(), nvidiaSMIWait)
	defer cancel()
	busID := nvidiaBusID(pciAddr)
	out, err := runCmd(ctx, "nvidia-smi", "--id="+busID, "--query-gpu=pci.bus_id,utilization.gpu,memory.used,memory.total,name", "--format=csv,noheader,nounits")
	if err != nil {
		return
	}
	parseNvidiaSMI(gpu, busID, out)
}

// parseNvidiaSMI applies the line whose bus id matches this card, so one
// card's numbers are never copied onto another.
func parseNvidiaSMI(gpu *GPUStatus, busID, out string) {
	for line := range strings.Lines(out) {
		fields := strings.Split(strings.TrimSpace(line), ",")
		if len(fields) < 5 || !strings.EqualFold(strings.TrimSpace(fields[0]), busID) {
			continue
		}
		if v, err := strconv.ParseFloat(strings.TrimSpace(fields[1]), 64); err == nil {
			gpu.Usage = v
		}
		gpu.MemoryUsed, _ = strconv.ParseFloat(strings.TrimSpace(fields[2]), 64)
		gpu.MemoryTotal, _ = strconv.ParseFloat(strings.TrimSpace(fields[3]), 64)
		if name := strings.TrimSpace(fields[4]); name != "" {
			gpu.Name = name
		}
		return
	}
}

// lspciNames maps PCI slot to a device name for display controllers. It runs
// only when lspci is installed and always under the C locale.
func lspciNames() map[string]string {
	if !commandExists("lspci") {
		return nil
	}
	ctx, cancel := context.WithTimeout(context.Background(), lspciTimeout)
	defer cancel()
	out, err := runCmd(ctx, "lspci", "-mm")
	if err != nil {
		return nil
	}
	return parseLspciDisplays(out)
}

var bracketName = regexp.MustCompile(`\[([^\]]+)\]`)

// parseLspciDisplays reads machine-readable lines such as
//
//	00:02.0 "VGA compatible controller" "Intel Corporation" "Alder Lake-P GT2 [Iris Xe Graphics]" -r0c ...
//
// and keeps VGA, 3D and Display controllers, preferring the bracketed
// marketing name.
func parseLspciDisplays(raw string) map[string]string {
	names := map[string]string{}
	for line := range strings.Lines(raw) {
		slot, rest, ok := strings.Cut(strings.TrimSpace(line), " ")
		if !ok {
			continue
		}
		fields := splitQuoted(rest)
		if len(fields) < 3 {
			continue
		}
		class := strings.ToLower(fields[0])
		if !strings.Contains(class, "vga") && !strings.Contains(class, "3d controller") && !strings.Contains(class, "display controller") {
			continue
		}
		device := fields[2]
		if m := bracketName.FindStringSubmatch(device); m != nil {
			device = m[1]
		}
		if device = strings.TrimSpace(device); device != "" {
			names[strings.TrimPrefix(slot, "0000:")] = device
		}
	}
	return names
}

// splitQuoted returns the double-quoted fields of an lspci -mm line.
func splitQuoted(s string) []string {
	var fields []string
	for {
		start := strings.IndexByte(s, '"')
		if start < 0 {
			return fields
		}
		end := strings.IndexByte(s[start+1:], '"')
		if end < 0 {
			return fields
		}
		fields = append(fields, s[start+1:start+1+end])
		s = s[start+1+end+1:]
	}
}
