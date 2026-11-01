package main

import (
	"os"
	"path/filepath"
	"sort"
	"strings"
	"sync"
)

// mountTable answers the one mount question every walker asks: is this
// directory where another filesystem starts? It is read from
// /proc/self/mountinfo once per process, so a scan never stats or wakes a
// mounted filesystem to find out.
//
// The walkers (the tree scan, the live scan, the fast fallback walk) and the du
// probe behind the overview all use this one rule, so a folder's overview size
// and its drill-in total agree.
type mountTable struct {
	byPoint map[string]mountInfo // the visible (last) mount at each mountpoint
	points  []string             // mountpoints, longest first
	foreign []string             // foreign mountpoints, sorted
}

func newMountTable(mounts []mountInfo) *mountTable {
	t := &mountTable{byPoint: make(map[string]mountInfo, len(mounts))}
	for _, m := range mounts {
		if !strings.HasPrefix(m.Mountpoint, "/") {
			continue
		}
		point := filepath.Clean(m.Mountpoint)
		// A later line mounted over an earlier one at the same path hides it.
		t.byPoint[point] = m
	}
	for point := range t.byPoint {
		t.points = append(t.points, point)
	}
	sort.Slice(t.points, func(i, j int) bool {
		if len(t.points[i]) != len(t.points[j]) {
			return len(t.points[i]) > len(t.points[j])
		}
		return t.points[i] < t.points[j]
	})
	for _, point := range t.points {
		if t.isForeignMount(point) {
			t.foreign = append(t.foreign, point)
		}
	}
	sort.Strings(t.foreign)
	return t
}

func pathWithin(path, dir string) bool {
	return dir == "/" || path == dir || strings.HasPrefix(path, dir+"/")
}

// mountAt returns the mount that holds path: the deepest mountpoint at or
// above it.
func (t *mountTable) mountAt(path string) (mountInfo, bool) {
	if t == nil {
		return mountInfo{}, false
	}
	path = filepath.Clean(path)
	for _, point := range t.points {
		if pathWithin(path, point) {
			return t.byPoint[point], true
		}
	}
	return mountInfo{}, false
}

// sameFilesystem reports whether two mounts show the same filesystem. The
// mountinfo device number is the superblock's, so every btrfs subvolume of
// one filesystem shares it even though stat gives each subvolume its own
// st_dev; btrfs mounts with the same source device count as one filesystem
// as well, matching the overview's rule.
func sameFilesystem(a, b mountInfo) bool {
	if a.Major == b.Major && a.Minor == b.Minor {
		return true
	}
	return a.FSType == "btrfs" && b.FSType == "btrfs" && a.Source != "" && a.Source == b.Source
}

// localDiskMount reports a filesystem on a local block device (ext4, xfs,
// btrfs, f2fs, vfat, exfat, NTFS through fuseblk, LUKS/dm mappings). These are
// walked like any folder, so analyzing / counts a separate /home or /boot.
// Network shares, FUSE, 9p/virtiofs, overlay, tmpfs, squashfs and pseudo
// filesystems are not: their source is not a /dev node (virtiofs has a tag,
// tmpfs a name), and squashfs on /dev/loopN is caught by type.
func localDiskMount(m mountInfo) bool {
	return strings.HasPrefix(m.Source, "/dev/") && !skipMountFS(m.FSType)
}

// isForeignMount reports whether path is a mountpoint the walk must not enter:
// another filesystem that is not a local disk (a network share, a FUSE mount,
// 9p or virtiofs, an overlay, tmpfs, squashfs, a pseudo filesystem). A local
// disk mounted there is walked, and btrfs subvolumes of the same filesystem
// (@home, @log, @pkg) are the same filesystem anyway.
func (t *mountTable) isForeignMount(path string) bool {
	if t == nil {
		return false
	}
	path = filepath.Clean(path)
	if path == "/" {
		return false
	}
	m, ok := t.byPoint[path]
	if !ok || localDiskMount(m) {
		return false
	}
	parent, ok := t.mountAt(filepath.Dir(path))
	if !ok {
		return true
	}
	return !sameFilesystem(m, parent)
}

// foreignMountsUnder lists the foreign mountpoints strictly inside root, for
// du to exclude. Mounts below a foreign mount are covered by its exclusion.
func (t *mountTable) foreignMountsUnder(root string) []string {
	if t == nil {
		return nil
	}
	root = filepath.Clean(root)
	var kept []string
	for _, p := range t.foreign {
		if p == root || !pathWithin(p, root) {
			continue
		}
		// Mounts inside an excluded mount are covered by its exclusion.
		if len(kept) > 0 && pathWithin(p, kept[len(kept)-1]) {
			continue
		}
		kept = append(kept, p)
	}
	return kept
}

// noAccessTime reports whether the filesystem holding path is mounted with
// noatime, where a file's access time is never updated after it is written
// and cannot say whether the file is still used.
func (t *mountTable) noAccessTime(path string) bool {
	m, ok := t.mountAt(path)
	if !ok {
		return false
	}
	return strings.Contains(","+m.Options+",", ",noatime,")
}

// currentMountTable is a var so tests can supply a fixture table.
var currentMountTable = sync.OnceValue(func() *mountTable {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return nil
	}
	return newMountTable(parseMountInfo(string(data)))
})

func isForeignMountPath(path string) bool {
	return currentMountTable().isForeignMount(path)
}
