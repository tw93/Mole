package main

import (
	"context"
	"io/fs"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
	"github.com/tw93/mole/internal/xdgtrash"
)

// skipDiskFSTypes are pseudo, overlay, read-only image and network filesystems.
// fuseblk is deliberately absent: it is a block device behind ntfs-3g or exfat,
// i.e. a real external disk. Other fuse.* mounts (sshfs, rclone, gvfs) are
// skipped by prefix in shouldSkipDiskPartition.
var skipDiskFSTypes = map[string]bool{
	"autofs": true, "binfmt_misc": true, "bpf": true, "cgroup": true, "cgroup2": true,
	"configfs": true, "debugfs": true, "devpts": true, "devtmpfs": true, "efivarfs": true,
	"fusectl": true, "hugetlbfs": true, "mqueue": true, "nsfs": true, "overlay": true,
	"proc": true, "pstore": true, "ramfs": true, "rpc_pipefs": true, "securityfs": true,
	"selinuxfs": true, "squashfs": true, "erofs": true, "iso9660": true, "sysfs": true,
	"tmpfs": true, "tracefs": true, "aufs": true,
	// Network and remote filesystems.
	"nfs": true, "nfs4": true, "cifs": true, "smb3": true, "smbfs": true, "9p": true,
	"afs": true, "ceph": true, "glusterfs": true, "sshfs": true, "davfs": true,
}

// skipDiskMountPrefixes are mount trees that never hold the user's data.
var skipDiskMountPrefixes = []string{
	"/proc", "/sys", "/dev", "/snap", "/var/lib/docker", "/var/lib/containers",
	"/var/lib/kubelet", "/var/snap",
}

var (
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return readMountinfo("/proc/self/mountinfo")
	}
	diskUsageFunc = disk.Usage
	// sysRoot is the tree /sys/fs/btrfs and /sys/class/block are read from;
	// tests point it at a fixture.
	sysRoot = "/"
)

const (
	smartStatusVerified    = "verified"
	smartStatusFailing     = "failing"
	smartStatusUnsupported = "unsupported"
	smartStatusUnknown     = "unknown"
)

func collectDisks() ([]DiskStatus, error) {
	return collectDisksFromMounts()
}

func collectDisksFast() ([]DiskStatus, error) {
	return collectDisksFromMounts()
}

func collectDisksFromMounts() ([]DiskStatus, error) {
	partitions, err := diskPartitionsFunc(false)
	if err != nil {
		return nil, err
	}
	// "/" first so a btrfs subvolume or bind mount of the same source is shown
	// under the root mount, not under whichever mount id came first.
	sort.SliceStable(partitions, func(i, j int) bool {
		return partitions[i].Mountpoint == "/" && partitions[j].Mountpoint != "/"
	})

	var (
		disks []DiskStatus
		seen  = make(map[string]bool)
	)
	for _, part := range partitions {
		if shouldSkipDiskPartition(part) {
			continue
		}
		// Same mount source and fstype is the same filesystem: btrfs mounts
		// each subvolume separately with a different st_dev, and a bind mount
		// repeats the source. Two distinct disks never share a source.
		key := part.Device + "\x00" + strings.ToLower(part.Fstype)
		if seen[key] {
			continue
		}
		usage, err := diskUsageFunc(part.Mountpoint)
		if err != nil || usage.Total == 0 {
			continue
		}
		// Skip <1GB volumes (EFI partitions, tiny boot filesystems).
		if usage.Total < 1<<30 {
			continue
		}
		var btrfs *BtrfsAlloc
		if strings.EqualFold(part.Fstype, "btrfs") {
			if a, ok := readBtrfsAlloc(sysRoot, part.Device); ok {
				btrfs = &a
			}
		}
		disks = append(disks, DiskStatus{
			Btrfs:       btrfs,
			Mount:       part.Mountpoint,
			Device:      part.Device,
			Used:        usage.Used,
			Total:       usage.Total,
			UsedPercent: usage.UsedPercent,
			Fstype:      part.Fstype,
			External:    isExternalMount(part.Mountpoint),
			SmartStatus: smartStatusUnknown,
		})
		seen[key] = true
	}

	sort.SliceStable(disks, func(i, j int) bool {
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

// isExternalMount treats removable media mounted by the desktop as external.
func isExternalMount(mount string) bool {
	return strings.HasPrefix(mount, "/run/media/") || strings.HasPrefix(mount, "/media/")
}

func shouldSkipDiskPartition(part disk.PartitionStat) bool {
	if strings.HasPrefix(part.Device, "/dev/loop") || strings.HasPrefix(part.Device, "/dev/ram") {
		return true
	}
	for _, prefix := range skipDiskMountPrefixes {
		if part.Mountpoint == prefix || strings.HasPrefix(part.Mountpoint, prefix+"/") {
			return true
		}
	}
	// /run is runtime tmpfs, except where the desktop mounts removable media.
	if (part.Mountpoint == "/run" || strings.HasPrefix(part.Mountpoint, "/run/")) && !strings.HasPrefix(part.Mountpoint, "/run/media/") {
		return true
	}

	fstype := strings.ToLower(part.Fstype)
	if skipDiskFSTypes[fstype] || strings.HasPrefix(fstype, "fuse.") || fstype == "fuse" {
		return true
	}
	return false
}

// readMountinfo parses /proc/self/mountinfo. Each line is
//
//	id parent major:minor root mountpoint options [optional fields...] - fstype source super-options
//
// Spaces and other awkward bytes in paths are written as octal escapes.
func readMountinfo(path string) ([]disk.PartitionStat, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	return parseMountinfo(string(data)), nil
}

func parseMountinfo(raw string) []disk.PartitionStat {
	var parts []disk.PartitionStat
	for line := range strings.Lines(raw) {
		fields := strings.Fields(line)
		sep := -1
		for i, f := range fields {
			if f == "-" {
				sep = i
				break
			}
		}
		if sep < 6 || len(fields) < sep+3 {
			continue
		}
		parts = append(parts, disk.PartitionStat{
			Device:     unescapeMountField(fields[sep+2]),
			Mountpoint: unescapeMountField(fields[4]),
			Fstype:     fields[sep+1],
			Opts:       strings.Split(fields[5], ","),
		})
	}
	return parts
}

// unescapeMountField decodes the kernel's \NNN octal escapes (\040 is a space).
func unescapeMountField(s string) string {
	if !strings.Contains(s, "\\") {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+3 < len(s) {
			if v, err := strconv.ParseUint(s[i+1:i+4], 8, 8); err == nil {
				b.WriteByte(byte(v))
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

// isPhysicalDiskName reports whether a /proc/diskstats name is a whole physical
// block device. IOCounters also lists partitions (sda1) and stacked devices
// (dm-0, md0), whose bytes are already counted on the disk underneath, plus
// loop and ram devices that never touch hardware.
func isPhysicalDiskName(name, root string) bool {
	for _, prefix := range []string{"loop", "ram", "dm-", "md", "zram", "sr", "fd", "nbd"} {
		if strings.HasPrefix(name, prefix) {
			return false
		}
	}
	// Whole disks have /sys/block/<name>; partitions live below their disk.
	return pathExists(filepath.Join(root, "sys/block", name))
}

var (
	// Trash size cache. The Trash can contain deep trees, and status refreshes
	// every second; a short cache prevents repeated WalkDir work without
	// hiding changes for long.
	trashSizeCacheMu      sync.Mutex
	trashSizeCachedAt     time.Time
	trashSizeCachedValue  uint64
	trashSizeCachedApprox bool
	trashSizeCacheTTL     = 5 * time.Second
)

func (c *Collector) collectDiskIO(now time.Time) DiskIOStatus {
	counters, err := disk.IOCounters()
	if err != nil || len(counters) == 0 {
		return DiskIOStatus{}
	}

	var total disk.IOCountersStat
	for name, v := range counters {
		if !isPhysicalDiskName(name, "/") {
			continue
		}
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

	readRate := float64(counterDelta(total.ReadBytes, c.prevDiskIO.ReadBytes)) / 1024 / 1024 / elapsed
	writeRate := float64(counterDelta(total.WriteBytes, c.prevDiskIO.WriteBytes)) / 1024 / 1024 / elapsed

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

func counterDelta(current, previous uint64) uint64 {
	if current < previous {
		return 0
	}
	return current - previous
}

// collectTrashSize returns the total size in bytes of the home Trash and whether
// the result is approximate (true when the 2s timeout was reached).
func collectTrashSize() (uint64, bool) {
	trashSizeCacheMu.Lock()
	if !trashSizeCachedAt.IsZero() && time.Since(trashSizeCachedAt) < trashSizeCacheTTL {
		value := trashSizeCachedValue
		approx := trashSizeCachedApprox
		trashSizeCacheMu.Unlock()
		return value, approx
	}
	trashSizeCacheMu.Unlock()

	total, approx := scanTrashSize()

	trashSizeCacheMu.Lock()
	trashSizeCachedValue = total
	trashSizeCachedApprox = approx
	trashSizeCachedAt = time.Now()
	trashSizeCacheMu.Unlock()

	return total, approx
}

func scanTrashSize() (uint64, bool) {
	env, err := xdgtrash.DefaultEnv()
	if err != nil {
		return 0, false
	}
	ctx, cancel := context.WithTimeout(context.Background(), 2*time.Second)
	defer cancel()
	var total uint64
	trashPath := filepath.Join(env.HomeTrash(), "files")
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
