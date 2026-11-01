package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/shirou/gopsutil/v4/disk"
)

func TestShouldSkipDiskPartition(t *testing.T) {
	tests := []struct {
		name string
		part disk.PartitionStat
		want bool
	}{
		{"keep ext4 root", disk.PartitionStat{Device: "/dev/vda2", Mountpoint: "/", Fstype: "ext4"}, false},
		{"keep btrfs home subvolume", disk.PartitionStat{Device: "/dev/nvme0n1p2", Mountpoint: "/home", Fstype: "btrfs"}, false},
		{"keep removable media", disk.PartitionStat{Device: "/dev/sdb1", Mountpoint: "/run/media/me/USB", Fstype: "exfat"}, false},
		{"keep ntfs-3g external", disk.PartitionStat{Device: "/dev/sdc1", Mountpoint: "/mnt/data", Fstype: "fuseblk"}, false},
		{"skip tmpfs", disk.PartitionStat{Device: "tmpfs", Mountpoint: "/tmp", Fstype: "tmpfs"}, true},
		{"skip proc", disk.PartitionStat{Device: "proc", Mountpoint: "/proc", Fstype: "proc"}, true},
		{"skip run tmpfs", disk.PartitionStat{Device: "tmpfs", Mountpoint: "/run/user/1000", Fstype: "tmpfs"}, true},
		{"skip docker overlay", disk.PartitionStat{Device: "overlay", Mountpoint: "/var/lib/docker/overlay2/x/merged", Fstype: "overlay"}, true},
		{"skip snap squashfs", disk.PartitionStat{Device: "/dev/loop3", Mountpoint: "/snap/core/1", Fstype: "squashfs"}, true},
		{"skip loop device", disk.PartitionStat{Device: "/dev/loop0", Mountpoint: "/mnt/img", Fstype: "ext4"}, true},
		{"skip sshfs", disk.PartitionStat{Device: "me@host:/", Mountpoint: "/mnt/remote", Fstype: "fuse.sshfs"}, true},
		{"skip nfs", disk.PartitionStat{Device: "host:/export", Mountpoint: "/mnt/nfs", Fstype: "nfs4"}, true},
		{"skip cifs", disk.PartitionStat{Device: "//server/share", Mountpoint: "/mnt/share", Fstype: "cifs"}, true},
		{"skip devtmpfs", disk.PartitionStat{Device: "devtmpfs", Mountpoint: "/dev", Fstype: "devtmpfs"}, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldSkipDiskPartition(tt.part); got != tt.want {
				t.Fatalf("shouldSkipDiskPartition(%+v) = %v, want %v", tt.part, got, tt.want)
			}
		})
	}
}

func TestParseMountinfo(t *testing.T) {
	raw := strings.Join([]string{
		"22 1 253:1 / / rw,relatime shared:1 - ext4 /dev/mapper/vg-root rw,errors=remount-ro",
		"30 22 0:27 / /proc rw,nosuid,nodev,noexec,relatime shared:12 - proc proc rw",
		`41 22 8:17 / /mnt/My\040Disk rw,relatime - btrfs /dev/sdb1 rw,subvolid=5`,
		"garbage line",
	}, "\n")
	got := parseMountinfo(raw)
	if len(got) != 3 {
		t.Fatalf("parseMountinfo() = %d entries, want 3: %#v", len(got), got)
	}
	if got[0].Device != "/dev/mapper/vg-root" || got[0].Mountpoint != "/" || got[0].Fstype != "ext4" {
		t.Fatalf("root entry = %#v", got[0])
	}
	if got[2].Mountpoint != "/mnt/My Disk" || got[2].Fstype != "btrfs" || got[2].Device != "/dev/sdb1" {
		t.Fatalf("octal escape / btrfs entry = %#v", got[2])
	}
}

func TestReadMountinfoMissingFile(t *testing.T) {
	if _, err := readMountinfo(filepath.Join(t.TempDir(), "missing")); err == nil {
		t.Fatal("readMountinfo() on a missing file returned nil error")
	}
}

func TestCollectDisksDedupesBtrfsSubvolumesBySourceAndFstype(t *testing.T) {
	origPartitions, origUsage := diskPartitionsFunc, diskUsageFunc
	t.Cleanup(func() { diskPartitionsFunc, diskUsageFunc = origPartitions, origUsage })

	const total = uint64(100) << 30
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		// "/home" is listed before "/" to prove the root mount wins the dedupe.
		return []disk.PartitionStat{
			{Device: "/dev/nvme0n1p2", Mountpoint: "/home", Fstype: "btrfs"},
			{Device: "/dev/nvme0n1p2", Mountpoint: "/", Fstype: "btrfs"},
			{Device: "/dev/nvme0n1p2", Mountpoint: "/var/log", Fstype: "btrfs"},
			{Device: "/dev/nvme0n1p1", Mountpoint: "/boot", Fstype: "vfat"},
			{Device: "tmpfs", Mountpoint: "/tmp", Fstype: "tmpfs"},
			{Device: "/dev/sdb1", Mountpoint: "/mnt/other", Fstype: "ext4"},
		}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		size := total
		if path == "/boot" {
			size = 512 << 20
		}
		return &disk.UsageStat{Path: path, Total: size, Used: size / 2, UsedPercent: 50}, nil
	}

	got, err := collectDisks()
	if err != nil {
		t.Fatalf("collectDisks() error = %v", err)
	}
	if len(got) != 2 {
		t.Fatalf("collectDisks() = %d disks, want 2 (btrfs once, ext4 once): %#v", len(got), got)
	}
	if got[0].Mount != "/" || got[1].Mount != "/mnt/other" {
		t.Fatalf("mounts = %q, %q, want / then /mnt/other", got[0].Mount, got[1].Mount)
	}
}

func TestCollectDisksKeepsTwoDistinctSameSizeDisks(t *testing.T) {
	origPartitions, origUsage := diskPartitionsFunc, diskUsageFunc
	t.Cleanup(func() { diskPartitionsFunc, diskUsageFunc = origPartitions, origUsage })

	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{
			{Device: "/dev/sda1", Mountpoint: "/", Fstype: "ext4"},
			{Device: "/dev/sdb1", Mountpoint: "/data", Fstype: "ext4"},
		}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Path: path, Total: 1 << 40, Used: 1 << 39, UsedPercent: 50}, nil
	}
	got, err := collectDisks()
	if err != nil || len(got) != 2 {
		t.Fatalf("collectDisks() = %#v, %v; want both identical-size disks", got, err)
	}
}

func TestCollectDisksDoesNotRunExternalCommands(t *testing.T) {
	origPartitions, origUsage := diskPartitionsFunc, diskUsageFunc
	origRunCmd, origCommandExists := runCmd, commandExists
	t.Cleanup(func() {
		diskPartitionsFunc, diskUsageFunc = origPartitions, origUsage
		runCmd, commandExists = origRunCmd, origCommandExists
	})
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{{Device: "/dev/vda2", Mountpoint: "/", Fstype: "ext4"}}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Path: path, Total: 2 << 30, Used: 1 << 30, UsedPercent: 50}, nil
	}
	commandExists = func(name string) bool {
		t.Fatalf("collectDisks() checked external command %q", name)
		return false
	}
	runCmd = func(context.Context, string, ...string) (string, error) {
		t.Fatal("collectDisks() ran an external command")
		return "", errors.New("unexpected command")
	}
	for _, collect := range []func() ([]DiskStatus, error){collectDisks, collectDisksFast} {
		got, err := collect()
		if err != nil || len(got) != 1 {
			t.Fatalf("collect() = %#v, %v", got, err)
		}
		if got[0].SmartStatus != smartStatusUnknown || got[0].External {
			t.Fatalf("collect() = %#v, want internal disk with unknown SMART", got[0])
		}
	}
}

func TestIsExternalMount(t *testing.T) {
	for mount, want := range map[string]bool{
		"/": false, "/home": false, "/run/media/me/USB": true, "/media/me/USB": true, "/mnt/data": false,
	} {
		if got := isExternalMount(mount); got != want {
			t.Fatalf("isExternalMount(%q) = %v, want %v", mount, got, want)
		}
	}
}

func TestIsPhysicalDiskNameCountsWholeDisksOnly(t *testing.T) {
	root := t.TempDir()
	for _, name := range []string{"sda", "nvme0n1", "dm-0", "loop0", "md0", "vda"} {
		if err := os.MkdirAll(filepath.Join(root, "sys/block", name), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	for name, want := range map[string]bool{
		"sda": true, "nvme0n1": true, "vda": true,
		"sda1": false, "nvme0n1p1": false, // partitions have no /sys/block entry
		"dm-0": false, "loop0": false, "md0": false,
	} {
		if got := isPhysicalDiskName(name, root); got != want {
			t.Fatalf("isPhysicalDiskName(%q) = %v, want %v", name, got, want)
		}
	}
}

func TestTrashSizeCountsXDGTrashFiles(t *testing.T) {
	data := t.TempDir()
	t.Setenv("XDG_DATA_HOME", data)
	files := filepath.Join(data, "Trash", "files")
	if err := os.MkdirAll(files, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(files, "a.bin"), make([]byte, 1500), 0o644); err != nil {
		t.Fatal(err)
	}
	size, approx := scanTrashSize()
	if size != 1500 || approx {
		t.Fatalf("scanTrashSize() = %d, %v; want 1500, false", size, approx)
	}
}

func TestDiskStatusJSONAndNDJSONAlwaysIncludeSMARTStatus(t *testing.T) {
	snapshot := MetricsSnapshot{
		Disks: []DiskStatus{{Mount: "/", SmartStatus: smartStatusUnsupported}},
	}

	oneShot, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	if !strings.Contains(string(oneShot), `"smart_status":"unsupported"`) {
		t.Fatalf("JSON missing smart_status: %s", oneShot)
	}

	var stream bytes.Buffer
	encoder := json.NewEncoder(&stream)
	if err := encoder.Encode(snapshot); err != nil {
		t.Fatalf("first NDJSON encode error = %v", err)
	}
	snapshot.Disks[0].SmartStatus = smartStatusUnknown
	if err := encoder.Encode(snapshot); err != nil {
		t.Fatalf("second NDJSON encode error = %v", err)
	}
	lines := strings.Split(strings.TrimSpace(stream.String()), "\n")
	if len(lines) != 2 || !strings.Contains(lines[0], `"smart_status":"unsupported"`) ||
		!strings.Contains(lines[1], `"smart_status":"unknown"`) {
		t.Fatalf("NDJSON smart_status lines = %q", lines)
	}
}

func TestCounterDeltaClampsCounterReset(t *testing.T) {
	if got := counterDelta(150, 100); got != 50 {
		t.Fatalf("counterDelta increasing = %d, want 50", got)
	}
	if got := counterDelta(10, 100); got != 0 {
		t.Fatalf("counterDelta reset = %d, want 0", got)
	}
}
