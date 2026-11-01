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
	previous := currentMountTable
	currentMountTable = func() *mountTable { return table }
	t.Cleanup(func() { currentMountTable = previous })
}

func TestMountTableTreatsBtrfsSubvolumesAsOneFilesystem(t *testing.T) {
	table := newMountTable(parseMountInfo(omarchyMountInfo))
	cases := map[string]bool{
		"/":                                   false,
		"/home":                               false, // @home
		"/var/log":                            false, // @log
		"/var/cache/pacman/pkg":               false, // @pkg
		"/home/u/vm":                          false, // same source, other device number
		"/boot":                               true,
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
