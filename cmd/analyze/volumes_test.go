package main

import "testing"

// A Linux desktop with btrfs subvolumes, a data disk, an NTFS-3g disk, a
// removable stick, and the runtime/pseudo mounts that must never be listed.
const sampleMountInfo = `22 1 0:21 /@ / rw,noatime - btrfs /dev/nvme0n1p2 rw,ssd,subvol=/@
23 22 0:21 /@home /home rw,noatime - btrfs /dev/nvme0n1p2 rw,ssd,subvol=/@home
24 22 0:21 /@snapshots /.snapshots rw,noatime - btrfs /dev/nvme0n1p2 rw,ssd,subvol=/@snapshots
25 22 0:5 / /dev rw,nosuid shared:2 - devtmpfs devtmpfs rw,size=4096k
26 22 0:23 / /proc rw,nosuid,nodev,noexec - proc proc rw
27 22 0:24 / /sys rw,nosuid,nodev,noexec - sysfs sysfs rw
28 22 0:25 / /run rw,nosuid,nodev shared:5 - tmpfs tmpfs rw
29 22 0:26 / /tmp rw,nosuid,nodev - tmpfs tmpfs rw
30 22 0:27 / /sys/fs/cgroup rw - cgroup2 cgroup2 rw
31 22 259:1 / /boot rw,relatime shared:30 - vfat /dev/nvme0n1p1 rw,fmask=0022
32 22 8:17 / /mnt/data rw,relatime - ext4 /dev/sdb1 rw
33 22 8:33 / /mnt/windows\040disk rw,relatime - fuseblk /dev/sdc1 rw,user_id=0
34 22 0:40 / /run/media/me/STICK rw,nosuid,nodev - exfat /dev/sdd1 rw
35 22 8:17 /backup /mnt/bind rw,relatime - ext4 /dev/sdb1 rw
36 22 0:41 / /mnt/nas rw,relatime - nfs4 nas:/export rw
37 22 0:42 / /mnt/share rw,relatime - cifs //nas/share rw
38 22 0:43 / /run/user/1000/doc rw,nosuid,nodev - fuse.portal portal rw
39 22 0:44 / /run/user/1000/gvfs rw,nosuid,nodev - fuse.gvfsd-fuse gvfsd-fuse rw
40 22 7:0 / /var/lib/snapd/snap/core/1 ro,nodev,relatime - squashfs /dev/loop0 ro
41 22 7:1 / /mnt/iso ro,relatime - iso9660 /dev/sr0 ro
42 22 0:21 /@data /mnt/btrfs-data rw,noatime - btrfs /dev/nvme0n1p2 rw,subvol=/@data
43 22 0:50 / /mnt/second rw - btrfs /dev/sde1 rw,subvol=/
44 22 0:51 /sub /mnt/second-sub rw - btrfs /dev/sde1 rw,subvol=/sub
`

func TestParseMountInfoReadsFieldsAndEscapes(t *testing.T) {
	mounts := parseMountInfo(sampleMountInfo)
	if len(mounts) != 23 {
		t.Fatalf("parsed %d mounts, want 23", len(mounts))
	}
	first := mounts[0]
	if first.Mountpoint != "/" || first.FSType != "btrfs" || first.Source != "/dev/nvme0n1p2" ||
		first.Root != "/@" || first.Major != "0" || first.Minor != "21" {
		t.Fatalf("first mount = %+v", first)
	}
	var found bool
	for _, m := range mounts {
		if m.Mountpoint == "/mnt/windows disk" {
			found = m.FSType == "fuseblk"
		}
	}
	if !found {
		t.Fatal("octal-escaped mount point /mnt/windows\\040disk was not decoded to a space")
	}
}

func TestParseMountInfoIgnoresMalformedLines(t *testing.T) {
	text := "garbage\n\n1 2 3 /\n22 1 0:21 / / rw - ext4 /dev/sda1 rw\n36 35 98:0 /mnt1 /mnt2 rw a:1 b:2 c:3 - ext3 /dev/root rw\n"
	mounts := parseMountInfo(text)
	if len(mounts) != 2 || mounts[1].Mountpoint != "/mnt2" || mounts[1].FSType != "ext3" {
		t.Fatalf("parsed %+v, want the two well-formed lines", mounts)
	}
}

func TestOverviewEntriesForMounts(t *testing.T) {
	entries := overviewEntriesForMounts(parseMountInfo(sampleMountInfo))
	var got []string
	for _, entry := range entries {
		if !entry.IsDir || entry.Size != -1 {
			t.Errorf("entry %+v is not a pending directory row", entry)
		}
		got = append(got, entry.Path)
	}
	want := []string{"/boot", "/mnt/data", "/mnt/windows disk", "/run/media/me/STICK", "/mnt/second"}
	if len(got) != len(want) {
		t.Fatalf("overview rows = %q, want %q", got, want)
	}
	for i := range want {
		if got[i] != want[i] {
			t.Fatalf("overview rows = %q, want %q", got, want)
		}
	}
	if entries[2].Name != "windows disk" {
		t.Errorf("row name = %q, want base name of the mount point", entries[2].Name)
	}
}

func TestOverviewEntriesShowOneBtrfsFilesystemOnce(t *testing.T) {
	// / and /home are two subvolumes of /dev/nvme0n1p2; /mnt/btrfs-data a third.
	for _, entry := range overviewEntriesForMounts(parseMountInfo(sampleMountInfo)) {
		switch entry.Path {
		case "/home", "/.snapshots", "/mnt/btrfs-data":
			t.Errorf("subvolume mount %s of the root filesystem was listed", entry.Path)
		case "/mnt/second-sub":
			t.Errorf("second subvolume of /dev/sde1 was listed besides /mnt/second")
		}
	}
}

func TestOverviewEntriesSkipPseudoNetworkAndRuntimeMounts(t *testing.T) {
	for _, fstype := range []string{
		"proc", "sysfs", "tmpfs", "devtmpfs", "cgroup", "cgroup2", "overlay", "squashfs",
		"autofs", "fuse.portal", "nsfs", "tracefs", "debugfs", "bpf", "mqueue", "configfs",
		"securityfs", "pstore", "efivarfs", "hugetlbfs", "ramfs", "binfmt_misc", "fusectl",
		"nfs", "nfs4", "cifs", "smb3", "sshfs", "fuse.sshfs", "fuse.gvfsd-fuse",
	} {
		if !skipMountFS(fstype) {
			t.Errorf("skipMountFS(%q) = false, want true", fstype)
		}
	}
	for _, fstype := range []string{"ext4", "xfs", "btrfs", "vfat", "exfat", "ntfs3", "fuseblk", "f2fs"} {
		if skipMountFS(fstype) {
			t.Errorf("skipMountFS(%q) = true, want false", fstype)
		}
	}
	if got := overviewEntriesForMounts(nil); len(got) != 0 {
		t.Fatalf("empty mount table produced %v", got)
	}
}

func TestOverviewEntriesSkipSnapshotAndContainerPaths(t *testing.T) {
	table := `1 0 8:1 / / rw - ext4 /dev/sda1 rw
2 1 8:2 / /.snapshots rw - ext4 /dev/sda2 rw
3 1 8:3 / /var/lib/docker/volumes rw - ext4 /dev/sda3 rw
4 1 8:4 / /snap/core rw - ext4 /dev/sda4 rw
5 1 8:5 / /srv/real rw - ext4 /dev/sda5 rw
`
	entries := overviewEntriesForMounts(parseMountInfo(table))
	if len(entries) != 1 || entries[0].Path != "/srv/real" {
		t.Fatalf("overview rows = %+v, want only /srv/real", entries)
	}
}
