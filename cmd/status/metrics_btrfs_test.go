package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/shirou/gopsutil/v4/disk"
)

const gib = uint64(1) << 30

// btrfsFixture builds /sys/fs/btrfs/<fsid> and the block sizes behind it.
// physical is the disk_total of data, metadata, system (single device, DUP
// metadata): data 1:1, metadata and system twice.
func btrfsFixture(t *testing.T, fsid string, devs map[string]uint64, dataTotal, dataUsed, metaTotal, metaUsed uint64) string {
	t.Helper()
	files := map[string]string{}
	base := "sys/fs/btrfs/" + fsid
	set := func(kind string, total, used, disk uint64) {
		files[base+"/allocation/"+kind+"/total_bytes"] = u(total) + "\n"
		files[base+"/allocation/"+kind+"/bytes_used"] = u(used) + "\n"
		files[base+"/allocation/"+kind+"/disk_total"] = u(disk) + "\n"
	}
	set("data", dataTotal, dataUsed, dataTotal)
	set("metadata", metaTotal, metaUsed, metaTotal*2)
	set("system", 8<<20, 16<<10, 16<<20)
	for name, bytes := range devs {
		files["sys/class/block/"+name+"/size"] = u(bytes/512) + "\n"
		files[base+"/devices/"+name+"/placeholder"] = ""
	}
	return writeTree(t, files)
}

func TestReadBtrfsAllocHealthyAndTight(t *testing.T) {
	// 100 GiB device, 60 data + 2*2 metadata + 16 MiB: plenty unallocated.
	root := btrfsFixture(t, "aaaa-1", map[string]uint64{"nvme0n1p2": 100 * gib}, 60*gib, 40*gib, 2*gib, 2*gib-(50<<20))
	a, ok := readBtrfsAlloc(root, "/dev/nvme0n1p2")
	if !ok || a.FSID != "aaaa-1" || a.DataTotal != 60*gib || a.DataUsed != 40*gib || a.MetadataTotal != 2*gib {
		t.Fatalf("alloc = %#v, %v", a, ok)
	}
	if !a.UnallocatedOK || a.MetadataTight {
		t.Fatalf("healthy volume flagged: %#v", a)
	}
	wantFree := 100*gib - 60*gib - 4*gib - 16<<20
	if a.Unallocated != wantFree {
		t.Fatalf("unallocated = %d, want %d", a.Unallocated, wantFree)
	}

	// Same metadata use, but data took the whole device: 100 - 95.5 - 4 < 1 GiB.
	root = btrfsFixture(t, "aaaa-2", map[string]uint64{"nvme0n1p2": 100 * gib}, 95*gib+gib/2, 90*gib, 2*gib, 2*gib-(50<<20))
	a, ok = readBtrfsAlloc(root, "/dev/nvme0n1p2")
	if !ok || !a.MetadataTight {
		t.Fatalf("tight volume not flagged: %#v, %v", a, ok)
	}
}

func TestBtrfsMetadataTightNeedsBothConditions(t *testing.T) {
	for name, tc := range map[string]struct {
		a    BtrfsAlloc
		want bool
	}{
		"full metadata, space left":   {BtrfsAlloc{MetadataTotal: 100, MetadataUsed: 99, Unallocated: 50 * gib, UnallocatedOK: true}, false},
		"metadata at 89 percent":      {BtrfsAlloc{MetadataTotal: 100, MetadataUsed: 89, Unallocated: 0, UnallocatedOK: true}, false},
		"metadata at 90 percent":      {BtrfsAlloc{MetadataTotal: 100, MetadataUsed: 90, Unallocated: gib - 1, UnallocatedOK: true}, true},
		"exactly 1 GiB unallocated":   {BtrfsAlloc{MetadataTotal: 100, MetadataUsed: 99, Unallocated: gib, UnallocatedOK: true}, false},
		"unknown unallocated":         {BtrfsAlloc{MetadataTotal: 100, MetadataUsed: 99, Unallocated: 0, UnallocatedOK: false}, false},
		"no metadata chunks reported": {BtrfsAlloc{UnallocatedOK: true}, false},
	} {
		if got := btrfsMetadataTight(tc.a); got != tc.want {
			t.Errorf("%s: tight = %v, want %v", name, got, tc.want)
		}
	}
}

func TestReadBtrfsAllocMatchesAnyMemberAndResolvesSymlinks(t *testing.T) {
	root := btrfsFixture(t, "bbbb-1", map[string]uint64{"sda": 50 * gib, "sdb": 50 * gib}, 10*gib, gib, gib, 1<<20)
	// A second filesystem must not be picked by mistake.
	addTree(t, root, map[string]string{"sys/fs/btrfs/cccc-9/devices/sdz/x": "", "sys/fs/btrfs/features/x": ""})
	for _, src := range []string{"/dev/sda", "/dev/sdb"} {
		a, ok := readBtrfsAlloc(root, src)
		if !ok || a.FSID != "bbbb-1" {
			t.Fatalf("%s -> %#v, %v", src, a, ok)
		}
		if !a.UnallocatedOK || a.Unallocated != 100*gib-10*gib-2*gib-16<<20 {
			t.Fatalf("%s unallocated = %d", src, a.Unallocated)
		}
	}
	// /dev/mapper/cryptroot -> ../dm-0, and the filesystem lists dm-0.
	root = btrfsFixture(t, "dddd-1", map[string]uint64{"dm-0": 20 * gib}, 5*gib, gib, gib, 1<<20)
	if err := os.MkdirAll(filepath.Join(root, "dev/mapper"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(root, "dev/dm-0"), nil, 0o644); err != nil {
		t.Fatal(err)
	}
	if err := os.Symlink("../dm-0", filepath.Join(root, "dev/mapper/cryptroot")); err != nil {
		t.Fatal(err)
	}
	if a, ok := readBtrfsAlloc(root, "/dev/mapper/cryptroot"); !ok || a.FSID != "dddd-1" {
		t.Fatalf("mapper = %#v, %v", a, ok)
	}
}

func TestReadBtrfsAllocRefusesWhatItCannotRead(t *testing.T) {
	root := btrfsFixture(t, "eeee-1", map[string]uint64{"sda": gib}, gib, 1, gib, 1)
	for _, src := range []string{"/dev/vda1", "tmpfs", "", "/dev/sdb"} {
		if _, ok := readBtrfsAlloc(root, src); ok {
			t.Fatalf("readBtrfsAlloc(%q) ok", src)
		}
	}
	// Missing metadata counters: no partial answer.
	os.Remove(filepath.Join(root, "sys/fs/btrfs/eeee-1/allocation/metadata/bytes_used"))
	if _, ok := readBtrfsAlloc(root, "/dev/sda"); ok {
		t.Fatal("answered without metadata counters")
	}
	// Unreadable device size: allocation still shows, but never warns.
	root = btrfsFixture(t, "ffff-1", map[string]uint64{"sda": gib}, gib, 1, gib, gib-1)
	os.Remove(filepath.Join(root, "sys/class/block/sda/size"))
	a, ok := readBtrfsAlloc(root, "/dev/sda")
	if !ok || a.UnallocatedOK || a.MetadataTight {
		t.Fatalf("no-size alloc = %#v, %v", a, ok)
	}
	// No /sys/fs/btrfs at all (kernel without btrfs).
	if _, ok := readBtrfsAlloc(t.TempDir(), "/dev/sda"); ok {
		t.Fatal("answered without /sys/fs/btrfs")
	}
}

func TestCollectDisksAttachesBtrfsAllocationToBtrfsOnly(t *testing.T) {
	origPartitions, origUsage, origRoot := diskPartitionsFunc, diskUsageFunc, sysRoot
	t.Cleanup(func() { diskPartitionsFunc, diskUsageFunc, sysRoot = origPartitions, origUsage, origRoot })
	sysRoot = btrfsFixture(t, "aaaa-1", map[string]uint64{"nvme0n1p2": 100 * gib}, 60*gib, 40*gib, 2*gib, gib)
	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{
			{Device: "/dev/nvme0n1p2", Mountpoint: "/", Fstype: "btrfs"},
			{Device: "/dev/sda1", Mountpoint: "/mnt/x", Fstype: "ext4"},
		}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		return &disk.UsageStat{Path: path, Total: 100 * gib, Used: 40 * gib, UsedPercent: 40}, nil
	}
	got, err := collectDisks()
	if err != nil || len(got) != 2 {
		t.Fatalf("collectDisks() = %#v, %v", got, err)
	}
	for _, d := range got {
		switch d.Fstype {
		case "btrfs":
			if d.Btrfs == nil || d.Btrfs.DataTotal != 60*gib {
				t.Fatalf("btrfs disk = %#v", d)
			}
		default:
			if d.Btrfs != nil {
				t.Fatalf("%s disk carries btrfs data: %#v", d.Fstype, d.Btrfs)
			}
		}
	}
}

func TestFormatBtrfsLine(t *testing.T) {
	if got := formatBtrfsLine(DiskStatus{}); got != "" {
		t.Fatalf("non-btrfs line = %q", got)
	}
	ok := formatBtrfsLine(DiskStatus{Btrfs: &BtrfsAlloc{DataUsed: 40 * gib, DataTotal: 60 * gib, MetadataUsed: gib, MetadataTotal: 2 * gib}})
	if !strings.Contains(ok, "BTRFS") || !strings.Contains(ok, "data 40") || !strings.Contains(ok, "meta 1") {
		t.Fatalf("line = %q", ok)
	}
	warn := formatBtrfsLine(DiskStatus{Btrfs: &BtrfsAlloc{MetadataUsed: 95, MetadataTotal: 100, Unallocated: 100 << 20, UnallocatedOK: true, MetadataTight: true}})
	if !strings.Contains(warn, "meta 95% full") || !strings.Contains(warn, "unallocated") {
		t.Fatalf("warning = %q", warn)
	}
	card := renderDiskCard([]DiskStatus{{Mount: "/", Fstype: "btrfs", Total: 100 * gib, Used: 40 * gib, UsedPercent: 40,
		Btrfs: &BtrfsAlloc{DataUsed: 1, DataTotal: 2, MetadataUsed: 1, MetadataTotal: 2}}}, DiskIOStatus{}, 0, false)
	found := false
	for _, l := range card.lines {
		found = found || strings.Contains(l, "BTRFS")
	}
	if !found {
		t.Fatalf("disk card lacks the BTRFS line: %q", card.lines)
	}
}
