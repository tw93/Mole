package main

import (
	"os"
	"path/filepath"
	"strings"
)

// mountInfo is one parsed line of /proc/self/mountinfo.
type mountInfo struct {
	Major, Minor string
	Root         string // path within the filesystem that forms this mount's root
	Mountpoint   string
	Options      string
	FSType       string
	Source       string
}

// Read the mount table, without probing or waking mounted filesystems.
// The existing overview workers size eligible volumes after the first paint.
func mountedVolumeOverviewEntries() []dirEntry {
	data, err := os.ReadFile("/proc/self/mountinfo")
	if err != nil {
		return nil
	}
	return overviewEntriesForMounts(parseMountInfo(string(data)))
}

// unescapeMountField decodes the octal escapes (\040 for a space, \011, \012,
// \134) the kernel writes into mountinfo path fields.
func unescapeMountField(s string) string {
	if !strings.Contains(s, `\`) {
		return s
	}
	var b strings.Builder
	for i := 0; i < len(s); i++ {
		if s[i] == '\\' && i+4 <= len(s) {
			if v, ok := octalByte(s[i+1 : i+4]); ok {
				b.WriteByte(v)
				i += 3
				continue
			}
		}
		b.WriteByte(s[i])
	}
	return b.String()
}

func octalByte(s string) (byte, bool) {
	if len(s) != 3 {
		return 0, false
	}
	v := 0
	for i := 0; i < 3; i++ {
		if s[i] < '0' || s[i] > '7' {
			return 0, false
		}
		v = v*8 + int(s[i]-'0')
	}
	if v > 255 {
		return 0, false
	}
	return byte(v), true
}

// parseMountInfo parses proc(5) mountinfo text. Lines it cannot read are
// dropped; the optional fields before the "-" separator vary in number.
func parseMountInfo(text string) []mountInfo {
	var mounts []mountInfo
	for line := range strings.Lines(text) {
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
		dev := strings.SplitN(fields[2], ":", 2)
		if len(dev) != 2 {
			continue
		}
		mounts = append(mounts, mountInfo{
			Major:      dev[0],
			Minor:      dev[1],
			Root:       unescapeMountField(fields[3]),
			Mountpoint: unescapeMountField(fields[4]),
			Options:    fields[5],
			FSType:     fields[sep+1],
			Source:     unescapeMountField(fields[sep+2]),
		})
	}
	return mounts
}

var pseudoFSTypes = map[string]bool{
	"proc": true, "sysfs": true, "tmpfs": true, "devtmpfs": true, "devpts": true,
	"overlay": true, "squashfs": true, "autofs": true, "nsfs": true,
	"tracefs": true, "debugfs": true, "bpf": true, "mqueue": true,
	"configfs": true, "securityfs": true, "pstore": true, "efivarfs": true,
	"hugetlbfs": true, "ramfs": true, "binfmt_misc": true, "fusectl": true,
	"fuse.portal": true, "rpc_pipefs": true, "selinuxfs": true,
}

var networkFSTypes = map[string]bool{
	"cifs": true, "smb3": true, "sshfs": true, "fuse.sshfs": true,
	"ncpfs": true, "9p": true, "afs": true, "ceph": true, "glusterfs": true,
	"fuse.glusterfs": true,
}

// skipMountFS reports filesystem types that never belong in the overview.
// fuseblk (NTFS-3g, exFAT over FUSE) is a real local disk and stays.
func skipMountFS(fstype string) bool {
	switch {
	case fstype == "fuseblk":
		return false
	case pseudoFSTypes[fstype], networkFSTypes[fstype]:
		return true
	case strings.HasPrefix(fstype, "cgroup"), strings.HasPrefix(fstype, "nfs"):
		return true
	case strings.HasPrefix(fstype, "fuse."):
		// gvfsd-fuse, portal, rclone, s3fs and similar user-space mounts.
		return true
	}
	return false
}

var skipMountPrefixes = []string{
	"/proc", "/sys", "/dev", "/snap", "/var/lib/docker", "/var/lib/containers",
	"/var/lib/flatpak/runtime", "/run/user", "/run/snapd", "/.snapshots", "/timeshift",
}

func mountPathSkipped(path string) bool {
	for _, p := range skipMountPrefixes {
		if path == p || strings.HasPrefix(path, p+"/") {
			return true
		}
	}
	return false
}

// overviewEntriesForMounts turns the mount table into overview rows. The root
// filesystem has its own rows (Home, /usr, /var), so it only registers itself
// to keep other mounts of the same btrfs filesystem from listing again.
func overviewEntriesForMounts(mounts []mountInfo) []dirEntry {
	var entries []dirEntry
	seenPath := make(map[string]bool)
	seenBtrfs := make(map[string]bool)
	for _, mount := range mounts {
		path := mount.Mountpoint
		// Each btrfs subvolume mount reports its own st_dev, but they are one
		// filesystem: decide by source and type, not by device number.
		btrfsKey := mount.FSType + "\x00" + mount.Source
		if mount.FSType == "btrfs" && seenBtrfs[btrfsKey] {
			continue
		}
		if path == "/" {
			seenBtrfs[btrfsKey] = true
			continue
		}
		// Local writable volumes only. Read-only images, bind mounts of a
		// directory (root other than "/"; btrfs subvolumes legitimately have
		// one), runtime trees and snapshot mounts do not belong in overview.
		if skipMountFS(mount.FSType) ||
			strings.Contains(","+mount.Options+",", ",ro,") ||
			(mount.FSType != "btrfs" && mount.Root != "/") ||
			!strings.HasPrefix(path, "/") || filepath.Clean(path) != path ||
			mountPathSkipped(path) || seenPath[path] {
			continue
		}
		if mount.FSType == "btrfs" {
			seenBtrfs[btrfsKey] = true
		}
		seenPath[path] = true
		entries = append(entries, dirEntry{Name: filepath.Base(path), Path: path, IsDir: true, Size: -1})
	}
	return entries
}
