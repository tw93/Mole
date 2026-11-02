package main

import (
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// BtrfsAlloc is chunk allocation read from /sys/fs/btrfs/<fsid>/allocation,
// which is world-readable. statfs (the Used and Total of the disk line) cannot
// show it: a btrfs volume can report plenty free and still fail with ENOSPC
// because every byte is already handed out to chunks and the metadata chunks
// are full.
type BtrfsAlloc struct {
	FSID          string `json:"fsid"`
	DataTotal     uint64 `json:"data_total"`     // logical bytes allocated to data chunks
	DataUsed      uint64 `json:"data_used"`      // of which files use
	MetadataTotal uint64 `json:"metadata_total"` // the same for metadata chunks
	MetadataUsed  uint64 `json:"metadata_used"`
	SystemTotal   uint64 `json:"system_total"`
	SystemUsed    uint64 `json:"system_used"`
	Unallocated   uint64 `json:"unallocated"`    // device bytes no chunk owns yet; valid when UnallocatedOK
	UnallocatedOK bool   `json:"unallocated_ok"` // false when device sizes could not be read
	MetadataTight bool   `json:"metadata_tight"` // see btrfsMetadataTight
}

const (
	// btrfsMetadataWarnRatio and btrfsUnallocatedFloor decide the warning.
	// Metadata chunks are allocated in 1 GiB steps (256 MiB on small
	// filesystems), so a healthy volume sits at 85-95% inside the chunks it
	// has and simply allocates one more when needed. That only fails when no
	// device space is left to carve a new chunk from, so the warning needs both:
	// metadata at least 90% used inside its chunks and under 1 GiB unallocated.
	// Either alone is normal. Unknown unallocated space never warns.
	btrfsMetadataWarnRatio = 0.90
	btrfsUnallocatedFloor  = 1 << 30
)

// readBtrfsAlloc finds the filesystem behind a mount source such as
// /dev/nvme0n1p2 or /dev/mapper/cryptroot and reads its allocation. The map from
// mount to fsid goes through /sys/fs/btrfs/<fsid>/devices/<name>, one entry per
// member device named like its /sys/class/block entry: unlike
// /dev/disk/by-uuid (one link per filesystem, pointing at a single member) it
// still matches the second disk of a multi-device volume, and unlike statfs
// f_fsid (the uuid XOR-folded with the subvolume id) it is reversible. ok is
// false for a filesystem that is not btrfs, not found, or unreadable.
func readBtrfsAlloc(root, source string) (BtrfsAlloc, bool) {
	if !strings.HasPrefix(source, "/dev/") {
		return BtrfsAlloc{}, false
	}
	// The source may be a symlink (/dev/mapper/cryptroot -> ../dm-0).
	resolved := source
	if r, err := filepath.EvalSymlinks(filepath.Join(root, source)); err == nil {
		resolved = r
	}
	name := filepath.Base(resolved)
	entries, err := os.ReadDir(filepath.Join(root, "sys/fs/btrfs"))
	if err != nil {
		return BtrfsAlloc{}, false
	}
	for _, e := range entries {
		fsDir := filepath.Join(root, "sys/fs/btrfs", e.Name())
		if _, err := os.Stat(filepath.Join(fsDir, "devices", name)); err != nil {
			continue
		}
		return readBtrfsFS(root, fsDir, e.Name())
	}
	return BtrfsAlloc{}, false
}

func readBtrfsFS(root, fsDir, fsid string) (BtrfsAlloc, bool) {
	a := BtrfsAlloc{FSID: fsid}
	var physical uint64
	for _, kind := range []struct {
		name        string
		total, used *uint64
	}{
		{"data", &a.DataTotal, &a.DataUsed},
		{"metadata", &a.MetadataTotal, &a.MetadataUsed},
		{"system", &a.SystemTotal, &a.SystemUsed},
	} {
		dir := filepath.Join(fsDir, "allocation", kind.name)
		total, ok1 := readUintFile(filepath.Join(dir, "total_bytes"))
		used, ok2 := readUintFile(filepath.Join(dir, "bytes_used"))
		if !ok1 || !ok2 {
			if kind.name == "data" || kind.name == "metadata" {
				return BtrfsAlloc{}, false
			}
			continue // system chunks are tiny; a missing file is not a failure
		}
		*kind.total, *kind.used = total, used
		diskTotal, ok := readUintFile(filepath.Join(dir, "disk_total"))
		if !ok {
			diskTotal = total // single profile: logical equals physical
		}
		physical += diskTotal
	}
	var size uint64
	devs, err := os.ReadDir(filepath.Join(fsDir, "devices"))
	sized := err == nil && len(devs) > 0
	for _, d := range devs {
		sectors, ok := readUintFile(filepath.Join(root, "sys/class/block", d.Name(), "size"))
		if !ok {
			sized = false
			break
		}
		size += sectors * 512
	}
	if sized && size >= physical {
		a.Unallocated, a.UnallocatedOK = size-physical, true
	}
	a.MetadataTight = btrfsMetadataTight(a)
	return a, true
}

func btrfsMetadataTight(a BtrfsAlloc) bool {
	if a.MetadataTotal == 0 || !a.UnallocatedOK {
		return false
	}
	ratio := float64(a.MetadataUsed) / float64(a.MetadataTotal)
	return ratio >= btrfsMetadataWarnRatio && a.Unallocated < btrfsUnallocatedFloor
}

func readUintFile(path string) (uint64, bool) {
	v, err := strconv.ParseUint(readTrimmed(path), 10, 64)
	return v, err == nil
}
