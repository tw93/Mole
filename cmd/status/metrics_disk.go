package main

import (
	"context"
	"errors"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
)

var skipDiskMounts = map[string]bool{
	"/System/Volumes/VM":       true,
	"/System/Volumes/Preboot":  true,
	"/System/Volumes/Update":   true,
	"/System/Volumes/xarts":    true,
	"/System/Volumes/Hardware": true,
	"/System/Volumes/Data":     true,
	"/dev":                     true,
}

var skipDiskFSTypes = map[string]bool{
	"afpfs":   true,
	"autofs":  true,
	"cifs":    true,
	"devfs":   true,
	"fuse":    true,
	"fuseblk": true,
	"fusefs":  true,
	"macfuse": true,
	"nfs":     true,
	"osxfuse": true,
	"procfs":  true,
	"smbfs":   true,
	"tmpfs":   true,
	"webdav":  true,
}

func collectDisks() ([]DiskStatus, error) {
	partitions, err := disk.Partitions(false)
	if err != nil {
		return nil, err
	}

	var (
		disks      []DiskStatus
		seenDevice = make(map[string]bool)
		seenVolume = make(map[string]bool)
	)
	for _, part := range partitions {
		if shouldSkipDiskPartition(part) {
			continue
		}
		baseDevice := baseDeviceName(part.Device)
		if baseDevice == "" {
			baseDevice = part.Device
		}
		if seenDevice[baseDevice] {
			continue
		}
		usage, err := disk.Usage(part.Mountpoint)
		if err != nil || usage.Total == 0 {
			continue
		}
		total := usage.Total
		if runtime.GOOS == "darwin" {
			total = correctDiskTotalBytes(part.Mountpoint, total)
		}
		// Skip <1GB volumes.
		if total < 1<<30 {
			continue
		}
		// Use size-based dedupe key for shared pools.
		volKey := fmt.Sprintf("%s:%d", part.Fstype, total)
		if seenVolume[volKey] {
			continue
		}
		used := usage.Used
		usedPercent := usage.UsedPercent
		if runtime.GOOS == "darwin" && strings.ToLower(part.Fstype) == "apfs" {
			used, usedPercent = correctAPFSDiskUsage(part.Mountpoint, total, usage.Used)
		}

		disks = append(disks, DiskStatus{
			Mount:       part.Mountpoint,
			Device:      part.Device,
			Used:        used,
			Total:       total,
			UsedPercent: usedPercent,
			Fstype:      part.Fstype,
		})
		seenDevice[baseDevice] = true
		seenVolume[volKey] = true
	}

	annotateDiskTypes(disks)

	sort.Slice(disks, func(i, j int) bool {
		// First, prefer internal disks over external
		if disks[i].External != disks[j].External {
			return !disks[i].External
		}
		// Then sort by size (largest first)
		return disks[i].Total > disks[j].Total
	})

	if len(disks) > 3 {
		disks = disks[:3]
	}

	return disks, nil
}

func shouldSkipDiskPartition(part disk.PartitionStat) bool {
	if strings.HasPrefix(part.Device, "/dev/loop") {
		return true
	}
	if skipDiskMounts[part.Mountpoint] {
		return true
	}
	if strings.HasPrefix(part.Mountpoint, "/System/Volumes/") {
		return true
	}
	if strings.HasPrefix(part.Mountpoint, "/private/") {
		return true
	}

	fstype := strings.ToLower(part.Fstype)
	if skipDiskFSTypes[fstype] || strings.Contains(fstype, "fuse") {
		return true
	}

	// On macOS, local disks should come from /dev. This filters sshfs/macFUSE-style
	// mounts that can mirror the root volume and show up as duplicate internal disks.
	if runtime.GOOS == "darwin" && part.Device != "" && !strings.HasPrefix(part.Device, "/dev/") {
		return true
	}

	return false
}

var (
	// External disk cache.
	lastDiskCacheAt time.Time
	diskTypeCache   = make(map[string]bool)
	diskCacheTTL    = 2 * time.Minute

	// Finder startup disk usage cache (macOS APFS purgeable-aware).
	finderDiskCacheMu  sync.Mutex
	finderDiskCachedAt time.Time
	finderDiskFree     uint64
	finderDiskTotal    uint64
)

func annotateDiskTypes(disks []DiskStatus) {
	if len(disks) == 0 || runtime.GOOS != "darwin" || !commandExists("diskutil") {
		return
	}

	now := time.Now()
	// Clear stale cache.
	if now.Sub(lastDiskCacheAt) > diskCacheTTL {
		diskTypeCache = make(map[string]bool)
		lastDiskCacheAt = now
	}

	for i := range disks {
		base := baseDeviceName(disks[i].Device)
		if base == "" {
			base = disks[i].Device
		}

		if val, ok := diskTypeCache[base]; ok {
			disks[i].External = val
			continue
		}

		external, err := isExternalDisk(base)
		if err != nil {
			external = strings.HasPrefix(disks[i].Mount, "/Volumes/")
		}
		disks[i].External = external
		diskTypeCache[base] = external
	}
}

func baseDeviceName(device string) string {
	device = strings.TrimPrefix(device, "/dev/")
	if !strings.HasPrefix(device, "disk") {
		return device
	}
	for i := 4; i < len(device); i++ {
		if device[i] == 's' {
			return device[:i]
		}
	}
	return device
}

func isExternalDisk(device string) (bool, error) {
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()

	out, err := runCmd(ctx, "diskutil", "info", device)
	if err != nil {
		return false, err
	}
	var (
		found    bool
		external bool
	)
	for line := range strings.Lines(out) {
		trim := strings.TrimSpace(line)
		if strings.HasPrefix(trim, "Internal:") {
			found = true
			external = strings.Contains(trim, "No")
			break
		}
		if strings.HasPrefix(trim, "Device Location:") {
			found = true
			external = strings.Contains(trim, "External")
		}
	}
	if !found {
		return false, errors.New("diskutil info missing Internal field")
	}
	return external, nil
}

// correctDiskTotalBytes uses diskutil's plist output when macOS reports a
// meaningfully different disk size than gopsutil. This fixes external APFS
// volumes that can show doubled capacities through statfs/gopsutil.
func correctDiskTotalBytes(mountpoint string, rawTotal uint64) uint64 {
	if rawTotal == 0 || !commandExists("diskutil") {
		return rawTotal
	}

	diskutilTotal, err := getDiskutilTotalBytes(mountpoint)
	if err != nil || diskutilTotal == 0 {
		return rawTotal
	}

	if uint64AbsDiff(rawTotal, diskutilTotal) > 1<<30 {
		return diskutilTotal
	}

	return rawTotal
}

func getDiskutilTotalBytes(mountpoint string) (uint64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "diskutil", "info", "-plist", mountpoint)
	if err != nil {
		return 0, err
	}

	// Prefer TotalSize, but keep older/plainer keys as fallbacks.
	return extractPlistUint(out, "TotalSize", "DiskSize", "Size")
}

// correctAPFSDiskUsage returns Finder-accurate used bytes and percent for an
// APFS volume, accounting for purgeable caches and APFS local snapshots that
// statfs incorrectly counts as "used". Uses a three-tier fallback:
//  1. Finder via osascript (startup disk only) — exact match with macOS Finder
//  2. diskutil APFSContainerFree — corrects APFS snapshot space
//  3. Raw gopsutil values — original statfs-based calculation
func correctAPFSDiskUsage(mountpoint string, total, rawUsed uint64) (used uint64, usedPercent float64) {
	// Tier 1: Finder via osascript (startup disk at "/" only).
	if mountpoint == "/" && commandExists("osascript") {
		if finderFree, finderTotal, err := getFinderStartupDiskFreeBytes(); err == nil &&
			finderTotal > 0 && finderFree <= finderTotal {
			used = finderTotal - finderFree
			usedPercent = float64(used) / float64(finderTotal) * 100.0
			return
		}
	}

	// Tier 2: diskutil APFSContainerFree (corrects APFS local snapshots).
	if commandExists("diskutil") {
		if containerFree, err := getAPFSContainerFreeBytes(mountpoint); err == nil && containerFree <= total {
			corrected := total - containerFree
			// Only apply if it meaningfully differs (>1GB) from raw to avoid noise.
			if rawUsed > corrected && rawUsed-corrected > 1<<30 {
				used = corrected
				usedPercent = float64(used) / float64(total) * 100.0
				return
			}
		}
	}

	// Tier 3: fall back to raw gopsutil values.
	return rawUsed, float64(rawUsed) / float64(total) * 100.0
}

// getAPFSContainerFreeBytes returns the APFS container free space (including
// purgeable snapshot space) by parsing `diskutil info -plist`. This corrects
// for APFS local snapshots which statfs counts as used.
func getAPFSContainerFreeBytes(mountpoint string) (uint64, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "diskutil", "info", "-plist", mountpoint)
	if err != nil {
		return 0, err
	}

	return extractPlistUint(out, "APFSContainerFree")
}

// getFinderStartupDiskFreeBytes queries Finder via osascript for the startup
// disk free space. Finder's value includes purgeable caches and APFS snapshots,
// matching the "X GB of Y GB used" display. Results are cached for 2 minutes.
func getFinderStartupDiskFreeBytes() (free, total uint64, err error) {
	finderDiskCacheMu.Lock()
	defer finderDiskCacheMu.Unlock()

	if !finderDiskCachedAt.IsZero() && time.Since(finderDiskCachedAt) < diskCacheTTL {
		return finderDiskFree, finderDiskTotal, nil
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	// Single call returns both values as a comma-separated pair.
	out, err := runCmd(ctx, "osascript", "-e",
		`tell application "Finder" to return {free space of startup disk, capacity of startup disk}`)
	if err != nil {
		// Cache the failure timestamp so repeated calls within diskCacheTTL
		// return immediately instead of each waiting the full 5s timeout.
		finderDiskCachedAt = time.Now()
		return 0, 0, err
	}

	// Output format: "3.2489E+11, 4.9438E+11" or "324892202048, 494384795648"
	parts := strings.SplitN(strings.TrimSpace(out), ",", 2)
	if len(parts) != 2 {
		return 0, 0, fmt.Errorf("unexpected osascript output: %q", out)
	}

	freeF, err1 := strconv.ParseFloat(strings.TrimSpace(parts[0]), 64)
	totalF, err2 := strconv.ParseFloat(strings.TrimSpace(parts[1]), 64)
	if err1 != nil || err2 != nil || freeF <= 0 || totalF <= 0 {
		return 0, 0, fmt.Errorf("failed to parse osascript output: %q", out)
	}

	finderDiskFree = uint64(freeF)
	finderDiskTotal = uint64(totalF)
	finderDiskCachedAt = time.Now()
	return finderDiskFree, finderDiskTotal, nil
}

func extractPlistUint(plist string, keys ...string) (uint64, error) {
	for _, key := range keys {
		marker := "<key>" + key + "</key>"
		_, rest, found := strings.Cut(plist, marker)
		if !found {
			continue
		}

		_, rest, found = strings.Cut(rest, "<integer>")
		if !found {
			continue
		}

		value, _, found := strings.Cut(rest, "</integer>")
		if !found {
			continue
		}

		parsed, err := strconv.ParseUint(strings.TrimSpace(value), 10, 64)
		if err != nil {
			return 0, fmt.Errorf("failed to parse %s: %v", key, err)
		}
		return parsed, nil
	}

	return 0, fmt.Errorf("%s not found", strings.Join(keys, "/"))
}

func uint64AbsDiff(a, b uint64) uint64 {
	if a > b {
		return a - b
	}
	return b - a
}

func (c *Collector) collectDiskIO(now time.Time) DiskIOStatus {
	counters, err := disk.IOCounters()
	if err != nil || len(counters) == 0 {
		return DiskIOStatus{}
	}

	var total disk.IOCountersStat
	for _, v := range counters {
		total.ReadBytes += v.ReadBytes
		total.WriteBytes += v.WriteBytes
	}

	if c.lastDiskAt.IsZero() {
		c.prevDiskIO = total
		c.lastDiskAt = now
		return DiskIOStatus{}
	}

	elapsed := now.Sub(c.lastDiskAt).Seconds()
	if elapsed <= 0 {
		elapsed = 1
	}

	readRate := float64(total.ReadBytes-c.prevDiskIO.ReadBytes) / 1024 / 1024 / elapsed
	writeRate := float64(total.WriteBytes-c.prevDiskIO.WriteBytes) / 1024 / 1024 / elapsed

	c.prevDiskIO = total
	c.lastDiskAt = now

	if readRate < 0 {
		readRate = 0
	}
	if writeRate < 0 {
		writeRate = 0
	}

	return DiskIOStatus{ReadRate: readRate, WriteRate: writeRate}
}

// collectTrashSize returns the total size in bytes of ~/.Trash and whether
// the result is approximate (true when the 2s timeout was reached).
func collectTrashSize() (uint64, bool) {
	home, err := os.UserHomeDir()
	if err != nil {
		return 0, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var total uint64
	trashPath := filepath.Join(home, ".Trash")
	_ = filepath.WalkDir(trashPath, func(_ string, d fs.DirEntry, err error) error {
		if ctx.Err() != nil {
			return fs.SkipAll
		}
		if err != nil {
			return nil
		}
		if d.Type()&fs.ModeSymlink != 0 {
			return nil
		}
		if !d.IsDir() {
			if info, err := d.Info(); err == nil {
				total += uint64(info.Size())
			}
		}
		return nil
	})
	return total, ctx.Err() != nil
}
