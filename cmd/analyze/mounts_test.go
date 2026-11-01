package main

import (
	"context"
	"os"
	"path/filepath"
	"slices"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

// An Omarchy install: one btrfs filesystem with the @, @home, @log and @pkg
// subvolumes, the ESP, a tmpfs /tmp, plus an sshfs share in home and a Docker
// overlay under /var.
const omarchyMountInfo = `26 1 0:24 /@ / rw,noatime shared:1 - btrfs /dev/mapper/root rw,compress=zstd:3,ssd,subvol=/@
27 26 0:24 /@home /home rw,noatime shared:2 - btrfs /dev/mapper/root rw,compress=zstd:3,ssd,subvol=/@home
28 26 0:24 /@log /var/log rw,noatime shared:3 - btrfs /dev/mapper/root rw,compress=zstd:3,ssd,subvol=/@log
29 26 0:24 /@pkg /var/cache/pacman/pkg rw,noatime shared:4 - btrfs /dev/mapper/root rw,compress=zstd:3,ssd,subvol=/@pkg
30 26 259:1 / /boot rw,relatime shared:5 - vfat /dev/nvme0n1p1 rw,fmask=0022
31 26 0:25 / /tmp rw,nosuid,nodev shared:6 - tmpfs tmpfs rw
32 27 0:50 / /home/u/remote rw,nosuid,nodev,relatime - fuse.sshfs u@nas:/srv rw,user_id=1000
33 26 0:60 / /var/lib/docker/overlay2/abc/merged rw,relatime - overlay overlay rw,lowerdir=/x,upperdir=/y,workdir=/z
34 27 0:61 / /home/u/My\040Share rw,relatime - cifs //nas/share rw
35 32 0:62 / /home/u/remote/inner rw,relatime - tmpfs tmpfs rw
36 26 0:63 /@vm /home/u/vm rw,noatime - btrfs /dev/mapper/root rw,subvol=/@vm
`

func useMountTable(t *testing.T, table *mountTable) {
	t.Helper()
	previous := loadMountTable
	loadMountTable = func() *mountTable { return table }
	activeMountTable.Store(table)
	t.Cleanup(func() {
		loadMountTable = previous
		activeMountTable.Store(nil)
	})
}

// useMountInfo serves mountinfo text through readMountInfo, which the real
// loader reads once per scan, and counts the reads.
func useMountInfo(t *testing.T, text *string) *int32 {
	t.Helper()
	var reads int32
	previous := readMountInfo
	readMountInfo = func() (string, error) {
		atomic.AddInt32(&reads, 1)
		return *text, nil
	}
	activeMountTable.Store(nil)
	t.Cleanup(func() {
		readMountInfo = previous
		activeMountTable.Store(nil)
	})
	return &reads
}

func TestMountTableIsReadAgainForEachScan(t *testing.T) {
	root := t.TempDir()
	remote := filepath.Join(root, "remote")
	if err := os.Mkdir(remote, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFileOfSize(t, filepath.Join(remote, "big.bin"), 512*1024)
	text := "1 0 8:1 / / rw,relatime - ext4 /dev/sda1 rw\n"
	useMountInfo(t, &text)
	t.Setenv("HOME", t.TempDir())
	if isForeignMountPath(remote) {
		t.Fatal("nothing is mounted yet")
	}
	// A share mounted after the first read.
	text += "2 1 0:70 / " + remote + " rw,relatime - fuse.sshfs host:/srv rw\n"
	var files, dirs, bytes int64
	var current atomic.Value
	result, err := scanPathConcurrentAllEntries(context.Background(), root, &files, &dirs, &bytes, &current)
	if err != nil {
		t.Fatal(err)
	}
	if result.TotalSize >= 512*1024 {
		t.Fatalf("a mount that appeared after start was walked: total %d", result.TotalSize)
	}
	// du inside the scan uses the scan's table.
	size, err := getDirectorySizeFromDu(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	if size >= 512*1024 {
		t.Fatalf("du counted the mount the scan's table lists: %d", size)
	}
}

func TestOneScanReadsTheMountTableOnce(t *testing.T) {
	root := t.TempDir()
	for _, dir := range []string{"a/node_modules/x", "b/node_modules/y", "c/.git/objects", "d/.git/refs", "plain/sub"} {
		if err := os.MkdirAll(filepath.Join(root, dir), 0o755); err != nil {
			t.Fatal(err)
		}
		writeFileOfSize(t, filepath.Join(root, dir, "f.bin"), 16*1024)
	}
	text := "1 0 8:1 / / rw,relatime - ext4 /dev/sda1 rw\n"
	reads := useMountInfo(t, &text)
	t.Setenv("HOME", t.TempDir())
	var files, dirs, bytes int64
	var current atomic.Value
	if _, err := scanPathConcurrentAllEntries(context.Background(), root, &files, &dirs, &bytes, &current); err != nil {
		t.Fatal(err)
	}
	for _, sub := range []string{"a", "c"} {
		if _, err := scanPathConcurrentAllEntries(context.Background(), filepath.Join(root, sub), &files, &dirs, &bytes, &current); err != nil {
			t.Fatal(err)
		}
	}
	if got := atomic.LoadInt32(reads); got != 3 {
		t.Fatalf("three scans with folded node_modules and .git read mountinfo %d times, want 3 (once per scan)", got)
	}
}

func TestMountTableResolvesASymlinkedScanRoot(t *testing.T) {
	base := t.TempDir()
	realHome := filepath.Join(base, "var", "home")
	remote := filepath.Join(realHome, "u", "remote")
	if err := os.MkdirAll(remote, 0o755); err != nil {
		t.Fatal(err)
	}
	link := filepath.Join(base, "home")
	if err := os.Symlink(realHome, link); err != nil {
		t.Fatal(err)
	}
	realRemote, err := filepath.EvalSymlinks(remote)
	if err != nil {
		t.Fatal(err)
	}
	writeFileOfSize(t, filepath.Join(remote, "big.bin"), 512*1024)
	text := "1 0 8:1 / / rw,relatime - ext4 /dev/sda1 rw\n2 1 0:70 / " + realRemote + " rw,relatime - fuse.sshfs host:/srv rw\n"
	useMountInfo(t, &text)
	t.Setenv("HOME", t.TempDir())
	var files, dirs, bytes int64
	var current atomic.Value
	result, err := scanPathConcurrentAllEntries(context.Background(), link, &files, &dirs, &bytes, &current)
	if err != nil {
		t.Fatal(err)
	}
	if result.TotalSize >= 512*1024 {
		t.Fatalf("the share under the symlinked root was walked: total %d", result.TotalSize)
	}
	if !isForeignMountPath(filepath.Join(link, "u", "remote")) {
		t.Fatal("the link path must map to the mountpoint under the real path")
	}
	if got := currentMountTable().foreignMountsUnder(link); !slices.Equal(got, []string{filepath.Join(link, "u", "remote")}) {
		t.Fatalf("du excludes must use the path du walks: %q", got)
	}
}

func TestMountTableTreatsBtrfsSubvolumesAsOneFilesystem(t *testing.T) {
	table := newMountTable(parseMountInfo(omarchyMountInfo))
	cases := map[string]bool{
		"/":                                   false,
		"/home":                               false, // @home
		"/var/log":                            false, // @log
		"/var/cache/pacman/pkg":               false, // @pkg
		"/home/u/vm":                          false, // same source, other device number
		"/boot":                               false, // vfat on a local disk is walked
		"/tmp":                                true,
		"/home/u/remote":                      true,
		"/home/u/My Share":                    true,
		"/var/lib/docker/overlay2/abc/merged": true,
		"/home/u/remote/inner":                true,
		"/home/u/Documents":                   false, // not a mountpoint
		"/var":                                false,
	}
	for path, want := range cases {
		if got := table.isForeignMount(path); got != want {
			t.Errorf("isForeignMount(%q) = %v, want %v", path, got, want)
		}
	}
}

// A non-btrfs layout: / and a separate /home on ext4, the ESP on vfat, a
// LUKS-mapped xfs data disk, plus the mounts that must never be walked.
const ext4MountInfo = `1 0 8:2 / / rw,relatime - ext4 /dev/sda2 rw
2 1 8:3 / /home rw,relatime - ext4 /dev/sda3 rw
3 1 8:1 / /boot rw,relatime - vfat /dev/sda1 rw,fmask=0022
4 2 254:0 / /home/u/data rw,relatime - xfs /dev/mapper/luks-data rw
5 2 0:50 / /home/u/remote rw,relatime - fuse.sshfs u@nas:/srv rw
6 1 0:51 / /mnt/host rw,relatime - 9p hostshare rw
7 1 0:52 / /mnt/vfs rw,relatime - virtiofs share rw
8 1 7:0 / /var/lib/snapd/snap/core/1 ro,relatime - squashfs /dev/loop0 ro
9 1 0:53 / /tmp rw - tmpfs tmpfs rw
10 1 0:54 / /proc rw - proc proc rw
11 1 0:55 / /var/lib/docker/overlay2/abc/merged rw - overlay overlay rw
12 2 0:56 / /home/u/share rw - nfs4 nas:/export rw
`

func TestMountTableWalksLocalDisksButNotSharesOrMemory(t *testing.T) {
	table := newMountTable(parseMountInfo(ext4MountInfo))
	walked := []string{"/home", "/boot", "/home/u/data"}
	skipped := []string{"/home/u/remote", "/mnt/host", "/mnt/vfs", "/var/lib/snapd/snap/core/1", "/tmp", "/proc", "/var/lib/docker/overlay2/abc/merged", "/home/u/share"}
	for _, path := range walked {
		if table.isForeignMount(path) {
			t.Errorf("%s is a local disk and must be walked", path)
		}
	}
	for _, path := range skipped {
		if !table.isForeignMount(path) {
			t.Errorf("%s must not be walked", path)
		}
	}
	got := table.foreignMountsUnder("/")
	for _, path := range walked {
		if slices.Contains(got, path) {
			t.Errorf("du excludes %s, so mo analyze / would miss it: %q", path, got)
		}
	}
	if !slices.Equal(table.foreignMountsUnder("/home"), []string{"/home/u/remote", "/home/u/share"}) {
		t.Fatalf("foreignMountsUnder(/home) = %q", table.foreignMountsUnder("/home"))
	}
}

func TestScanWalksLocalDiskMount(t *testing.T) {
	root := t.TempDir()
	disk := filepath.Join(root, "disk")
	if err := os.Mkdir(disk, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFileOfSize(t, filepath.Join(disk, "big.bin"), 512*1024)
	useMountTable(t, newMountTable(parseMountInfo("1 0 8:1 / / rw - ext4 /dev/sda1 rw\n2 1 8:17 / "+disk+" rw - ext4 /dev/sdb1 rw\n")))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", "")

	var files, dirs, bytes int64
	result, err := scanPathConcurrentWithOptions(context.Background(), root, &files, &dirs, &bytes, &atomic.Value{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	if result.TotalSize < 512*1024 {
		t.Fatalf("total %d leaves out the second disk mounted inside the root", result.TotalSize)
	}
	for _, e := range result.Entries {
		if e.Path == disk && e.Mounted {
			t.Fatal("a local disk mount was listed as not scanned")
		}
	}
	if _, err := os.Stat(duBinary); err == nil {
		if size, err := getDirectorySizeFromDu(context.Background(), root); err != nil || size < 512*1024 {
			t.Fatalf("du = %d, %v, want the local disk counted", size, err)
		}
	}
}

func TestForeignMountsUnderListsOnlyOtherFilesystems(t *testing.T) {
	table := newMountTable(parseMountInfo(omarchyMountInfo))
	if got, want := table.foreignMountsUnder("/var"), []string{"/var/lib/docker/overlay2/abc/merged"}; !slices.Equal(got, want) {
		t.Fatalf("foreignMountsUnder(/var) = %q, want %q (@log and @pkg are counted)", got, want)
	}
	// The tmpfs inside the sshfs mount is covered by excluding the sshfs one.
	if got, want := table.foreignMountsUnder("/home/u"), []string{"/home/u/My Share", "/home/u/remote"}; !slices.Equal(got, want) {
		t.Fatalf("foreignMountsUnder(/home/u) = %q, want %q", got, want)
	}
	if got := table.foreignMountsUnder("/home/u/remote"); !slices.Equal(got, []string{"/home/u/remote/inner"}) {
		t.Fatalf("an explicitly opened mount still excludes mounts inside it, got %q", got)
	}
	if got := table.foreignMountsUnder("/usr"); len(got) != 0 {
		t.Fatalf("foreignMountsUnder(/usr) = %q, want none", got)
	}
}

func TestMountTableNoAccessTimeFollowsTheHoldingMount(t *testing.T) {
	table := newMountTable(parseMountInfo(omarchyMountInfo))
	if !table.noAccessTime("/home/u/notes.txt") {
		t.Fatal("a file in @home (noatime) must use the modification time")
	}
	if table.noAccessTime("/boot/vmlinuz-linux") || table.noAccessTime("/home/u/remote/file") {
		t.Fatal("relatime mounts keep the access time")
	}
	var nilTable *mountTable
	if nilTable.noAccessTime("/x") || nilTable.isForeignMount("/x") || nilTable.foreignMountsUnder("/") != nil {
		t.Fatal("an unreadable mount table must change nothing")
	}
}

func TestDuSizeArgsDoNotStopAtSubvolumesAndExcludeForeignMounts(t *testing.T) {
	args := duSizeArgs("/home/u", []string{".gvfs"}, []string{"/home/u/remote", "/home/u/a*b[1]"})
	for _, arg := range args {
		if strings.HasPrefix(arg, "-") && !strings.HasPrefix(arg, "--") && strings.Contains(arg, "x") {
			t.Fatalf("du must not get -x (it stops at every btrfs subvolume): %q", args)
		}
	}
	want := []string{"-skP", "--exclude=.snapshots", "--exclude=.gvfs", "--exclude=/home/u/remote", `--exclude=/home/u/a\*b\[1\]`, "/home/u"}
	if !slices.Equal(args, want) {
		t.Fatalf("duSizeArgs = %q, want %q", args, want)
	}
}

// fixtureMountTable mounts another filesystem at each of mountpoints inside a
// real temp tree that itself sits on the root filesystem.
func fixtureMountTable(mountpoints ...string) *mountTable {
	var b strings.Builder
	b.WriteString("1 0 8:1 / / rw,relatime - ext4 /dev/sda1 rw\n")
	for i, point := range mountpoints {
		b.WriteString("2 1 0:" + string(rune('a'+i)) + " / " + strings.ReplaceAll(point, " ", `\040`) + " rw,relatime - fuse.sshfs host:/srv rw\n")
	}
	return newMountTable(parseMountInfo(b.String()))
}

func TestScanListsForeignMountWithoutWalkingIt(t *testing.T) {
	root := t.TempDir()
	remote := filepath.Join(root, "remote")
	local := filepath.Join(root, "local")
	for _, dir := range []string{remote, local} {
		if err := os.Mkdir(dir, 0o755); err != nil {
			t.Fatal(err)
		}
	}
	writeFileOfSize(t, filepath.Join(remote, "big.bin"), 512*1024)
	writeFileOfSize(t, filepath.Join(local, "small.bin"), 64*1024)
	useMountTable(t, fixtureMountTable(remote))
	t.Setenv("HOME", t.TempDir())
	t.Setenv("XDG_CACHE_HOME", "")

	var files, dirs, bytes int64
	result, err := scanPathConcurrentWithOptions(context.Background(), root, &files, &dirs, &bytes, &atomic.Value{}, 0)
	if err != nil {
		t.Fatal(err)
	}
	var mounted *dirEntry
	for i := range result.Entries {
		if result.Entries[i].Path == remote {
			mounted = &result.Entries[i]
		}
	}
	if mounted == nil || !mounted.Mounted || mounted.Size != 0 || mounted.State != scanComplete {
		t.Fatalf("mount entry = %+v, want a listed, unmeasured, complete row", mounted)
	}
	if result.TotalSize >= 512*1024 {
		t.Fatalf("total %d includes the mounted filesystem", result.TotalSize)
	}
	if hint := entryHintLabel(*mounted); !strings.Contains(hint, "mounted, not scanned") {
		t.Fatalf("hint = %q", hint)
	}

	initial, targets, err := readLiveScanInitialEntries(root, nil)
	if err != nil {
		t.Fatal(err)
	}
	for _, target := range targets {
		if target.path == remote {
			t.Fatal("live scan queued the mounted filesystem for walking")
		}
	}
	found := false
	for _, entry := range initial.Entries {
		found = found || (entry.Path == remote && entry.Mounted)
	}
	if !found {
		t.Fatal("live scan did not list the mount")
	}

	if size, err := calculateDirSizeFast(context.Background(), root, &files, &dirs, &bytes, nil); err != nil || size >= 512*1024 {
		t.Fatalf("fast walk = %d, %v, want the mount excluded", size, err)
	}
	if size, err := getDirectoryLogicalSizeWithExclude(context.Background(), root, "", nil); err != nil || size >= 512*1024 {
		t.Fatalf("logical walk = %d, %v, want the mount excluded", size, err)
	}
}

func TestDuProbeExcludesForeignMount(t *testing.T) {
	if _, err := os.Stat(duBinary); err != nil {
		t.Skip("GNU du not installed")
	}
	root := t.TempDir()
	remote := filepath.Join(root, "re[mote] *")
	if err := os.Mkdir(remote, 0o755); err != nil {
		t.Fatal(err)
	}
	writeFileOfSize(t, filepath.Join(remote, "big.bin"), 2*1024*1024)
	writeFileOfSize(t, filepath.Join(root, "small.bin"), 64*1024)

	useMountTable(t, newMountTable(nil))
	withMount, err := getDirectorySizeFromDu(context.Background(), root)
	if err != nil || withMount < 2*1024*1024 {
		t.Fatalf("baseline du = %d, %v", withMount, err)
	}
	useMountTable(t, fixtureMountTable(remote))
	without, err := getDirectorySizeFromDu(context.Background(), root)
	if err != nil {
		t.Fatal(err)
	}
	if without >= 2*1024*1024 {
		t.Fatalf("du = %d, still counts the mounted filesystem", without)
	}
}

func TestLastUsedTimeUsesModificationTimeOnlyOnNoatime(t *testing.T) {
	path := filepath.Join(t.TempDir(), "f")
	writeFileOfSize(t, path, 10)
	old := time.Now().Add(-400 * 24 * time.Hour)
	recent := time.Now().Add(-time.Hour)
	if err := os.Chtimes(path, old, recent); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if got := getLastUsedTimeFromInfo(info, false); !got.Equal(old) {
		t.Fatalf("relatime used time = %v, want the access time", got)
	}
	if got := getLastUsedTimeFromInfo(info, true); !got.Equal(recent) {
		t.Fatalf("noatime used time = %v, want the modification time", got)
	}
	if formatUnusedTime(getLastUsedTimeFromInfo(info, true)) != "" {
		t.Fatal("a file written an hour ago on a noatime mount must not read as unused")
	}
}

func writeFileOfSize(t *testing.T, path string, size int) {
	t.Helper()
	if err := os.WriteFile(path, make([]byte, size), 0o644); err != nil {
		t.Fatal(err)
	}
	// Zero-filled writes are still allocated on ext4/btrfs/tmpfs; force real
	// blocks anyway by writing non-zero bytes at the end.
	f, err := os.OpenFile(path, os.O_WRONLY, 0)
	if err != nil {
		t.Fatal(err)
	}
	defer f.Close()
	if size > 0 {
		if _, err := f.WriteAt([]byte{1}, int64(size-1)); err != nil {
			t.Fatal(err)
		}
	}
}
