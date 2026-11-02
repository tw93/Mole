package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"runtime"
	"strings"
	"testing"
	"time"

	"github.com/shirou/gopsutil/v4/disk"
)

func TestShouldSkipDiskPartition(t *testing.T) {
	tests := []struct {
		name string
		part disk.PartitionStat
		want bool
	}{
		{
			name: "keep local apfs root volume",
			part: disk.PartitionStat{
				Device:     "/dev/disk3s1s1",
				Mountpoint: "/",
				Fstype:     "apfs",
			},
			want: false,
		},
		{
			name: "skip macfuse mirror mount",
			part: disk.PartitionStat{
				Device:     "kaku-local:/",
				Mountpoint: "/Users/tw93/Library/Caches/dev.kaku/sshfs/kaku-local",
				Fstype:     "macfuse",
			},
			want: true,
		},
		{
			name: "skip smb share",
			part: disk.PartitionStat{
				Device:     "//server/share",
				Mountpoint: "/Volumes/share",
				Fstype:     "smbfs",
			},
			want: true,
		},
		{
			name: "skip system volume",
			part: disk.PartitionStat{
				Device:     "/dev/disk3s5",
				Mountpoint: "/System/Volumes/Data",
				Fstype:     "apfs",
			},
			want: true,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := shouldSkipDiskPartition(tt.part); got != tt.want {
				t.Fatalf("shouldSkipDiskPartition(%+v) = %v, want %v", tt.part, got, tt.want)
			}
		})
	}
}

func TestExtractPlistUint(t *testing.T) {
	t.Run("prefers first matching key", func(t *testing.T) {
		raw := `<plist><dict>
<key>TotalSize</key><integer>1099511627776</integer>
<key>DiskSize</key><integer>2199023255552</integer>
</dict></plist>`

		got, err := extractPlistUint(raw, "TotalSize", "DiskSize")
		if err != nil {
			t.Fatalf("extractPlistUint() error = %v", err)
		}
		if got != 1099511627776 {
			t.Fatalf("extractPlistUint() = %d, want %d", got, uint64(1099511627776))
		}
	})

	t.Run("falls back to later keys", func(t *testing.T) {
		raw := `<plist><dict><key>DiskSize</key><integer>1099511627776</integer></dict></plist>`

		got, err := extractPlistUint(raw, "TotalSize", "DiskSize", "Size")
		if err != nil {
			t.Fatalf("extractPlistUint() error = %v", err)
		}
		if got != 1099511627776 {
			t.Fatalf("extractPlistUint() = %d, want %d", got, uint64(1099511627776))
		}
	})

	t.Run("returns error for malformed integer", func(t *testing.T) {
		raw := `<plist><dict><key>TotalSize</key><integer>oops</integer></dict></plist>`

		if _, err := extractPlistUint(raw, "TotalSize"); err == nil {
			t.Fatalf("extractPlistUint() expected parse error")
		}
	})
}

func TestParseDiskMetadataSMARTStatuses(t *testing.T) {
	tests := []struct {
		name string
		raw  string
		want string
	}{
		{name: "verified", raw: "Verified", want: smartStatusVerified},
		{name: "failing", raw: "Failing", want: smartStatusFailing},
		{name: "unsupported", raw: "Not Supported", want: smartStatusUnsupported},
		{name: "unknown value", raw: "Unavailable", want: smartStatusUnknown},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			metadata, err := parseDiskMetadata("Internal: Yes\nSMART Status: " + tt.raw + "\n")
			if err != nil {
				t.Fatalf("parseDiskMetadata() error = %v", err)
			}
			if metadata.SmartStatus != tt.want {
				t.Fatalf("parseDiskMetadata() smart status = %q, want %q", metadata.SmartStatus, tt.want)
			}
			if metadata.External {
				t.Fatal("parseDiskMetadata() internal disk marked external")
			}
		})
	}
}

func TestParseDiskMetadataUsesDeviceLocationAndUnknownForMissingSMART(t *testing.T) {
	metadata, err := parseDiskMetadata("Device Location: External\n")
	if err != nil {
		t.Fatalf("parseDiskMetadata() error = %v", err)
	}
	if !metadata.External {
		t.Fatal("parseDiskMetadata() external location was not detected")
	}
	if metadata.SmartStatus != smartStatusUnknown {
		t.Fatalf("parseDiskMetadata() missing SMART = %q, want unknown", metadata.SmartStatus)
	}
}

func TestAnnotateDiskMetadataCachesDiskutilResult(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("diskutil metadata is macOS-only")
	}

	origRunCmd := runCmd
	origCommandExists := commandExists
	origCache := diskMetadataCache
	origCacheAt := lastDiskCacheAt
	t.Cleanup(func() {
		runCmd = origRunCmd
		commandExists = origCommandExists
		diskMetadataCache = origCache
		lastDiskCacheAt = origCacheAt
	})

	diskMetadataCache = make(map[string]diskMetadata)
	lastDiskCacheAt = time.Time{}
	commandExists = func(name string) bool { return name == "diskutil" }
	calls := 0
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		calls++
		return "Internal: No\nSMART Status: Verified\n", nil
	}

	first := []DiskStatus{{Device: "/dev/disk9s2", Mount: "/Volumes/Fast", SmartStatus: smartStatusUnknown}}
	second := []DiskStatus{{Device: "/dev/disk9s3", Mount: "/Volumes/Fast", SmartStatus: smartStatusUnknown}}
	annotateDiskMetadata(first)
	annotateDiskMetadata(second)

	if calls != 1 {
		t.Fatalf("diskutil calls = %d, want 1 cache miss", calls)
	}
	for _, disks := range [][]DiskStatus{first, second} {
		if !disks[0].External || disks[0].SmartStatus != smartStatusVerified {
			t.Fatalf("cached disk metadata = %#v", disks[0])
		}
	}
}

func TestAnnotateDiskMetadataKeepsUnknownWhenDiskutilFails(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("diskutil metadata is macOS-only")
	}

	origRunCmd := runCmd
	origCommandExists := commandExists
	origCache := diskMetadataCache
	origCacheAt := lastDiskCacheAt
	t.Cleanup(func() {
		runCmd = origRunCmd
		commandExists = origCommandExists
		diskMetadataCache = origCache
		lastDiskCacheAt = origCacheAt
	})

	diskMetadataCache = make(map[string]diskMetadata)
	lastDiskCacheAt = time.Time{}
	commandExists = func(name string) bool { return name == "diskutil" }
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		return "", errors.New("diskutil failed")
	}

	disks := []DiskStatus{{Device: "/dev/disk8s1", Mount: "/Volumes/Backup", SmartStatus: smartStatusUnknown}}
	annotateDiskMetadata(disks)
	if !disks[0].External {
		t.Fatal("failed diskutil query should keep the mount-based external fallback")
	}
	if disks[0].SmartStatus != smartStatusUnknown {
		t.Fatalf("failed diskutil query smart status = %q, want unknown", disks[0].SmartStatus)
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

func TestCollectDisksFastSkipsSlowCorrections(t *testing.T) {
	origPartitions := diskPartitionsFunc
	origUsage := diskUsageFunc
	origRunCmd := runCmd
	origCommandExists := commandExists
	t.Cleanup(func() {
		diskPartitionsFunc = origPartitions
		diskUsageFunc = origUsage
		runCmd = origRunCmd
		commandExists = origCommandExists
	})

	const rawTotal = uint64(2 * 1024 * 1024 * 1024)
	const rawUsed = uint64(1024 * 1024 * 1024)
	diskPartitionsFunc = func(all bool) ([]disk.PartitionStat, error) {
		if all {
			t.Fatalf("collectDisksFast() should request physical partitions only")
		}
		return []disk.PartitionStat{
			{Device: "/dev/disk3s1s1", Mountpoint: "/", Fstype: "apfs"},
		}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		if path != "/" {
			t.Fatalf("unexpected disk usage path %q", path)
		}
		return &disk.UsageStat{
			Path:        path,
			Fstype:      "apfs",
			Total:       rawTotal,
			Used:        rawUsed,
			UsedPercent: 50,
		}, nil
	}
	commandExists = func(name string) bool {
		t.Fatalf("collectDisksFast() should not check external command %q", name)
		return false
	}
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		t.Fatalf("collectDisksFast() should not run external command %q", name)
		return "", errors.New("unexpected command")
	}

	got, err := collectDisksFast()
	if err != nil {
		t.Fatalf("collectDisksFast() error = %v", err)
	}
	if len(got) != 1 {
		t.Fatalf("collectDisksFast() returned %d disks, want 1: %#v", len(got), got)
	}
	if got[0].Total != rawTotal || got[0].Used != rawUsed || got[0].UsedPercent != 50 {
		t.Fatalf("collectDisksFast() should keep raw usage, got %#v", got[0])
	}
	if got[0].SmartStatus != smartStatusUnknown {
		t.Fatalf("collectDisksFast() smart status = %q, want unknown", got[0].SmartStatus)
	}
}

// APFS volumes (including snapshot devices such as disk8s1s1) in one
// container share a diskN base. Independent containers have distinct bases,
// even when their filesystem types and capacities match.
func TestCollectDisksDeduplicatesByDevice(t *testing.T) {
	origPartitions, origUsage := diskPartitionsFunc, diskUsageFunc
	origRunCmd, origCommandExists := runCmd, commandExists
	origCache, origCacheAt := diskMetadataCache, lastDiskCacheAt
	t.Cleanup(func() {
		diskPartitionsFunc, diskUsageFunc = origPartitions, origUsage
		runCmd, commandExists = origRunCmd, origCommandExists
		diskMetadataCache, lastDiskCacheAt = origCache, origCacheAt
	})

	type volume struct {
		device, mount, fstype string
		gib                   uint64
	}
	tests := []struct {
		name    string
		volumes []volume
		want    []string
	}{
		{
			name: "independent equal capacity APFS containers",
			volumes: []volume{
				{"/dev/disk8s1", "/Volumes/One", "apfs", 100},
				{"/dev/disk9s1", "/Volumes/Two", "apfs", 100},
			},
			want: []string{"/dev/disk8s1", "/dev/disk9s1"},
		},
		{
			name: "independent equal capacity exFAT disks",
			volumes: []volume{
				{"/dev/disk8s1", "/Volumes/One", "exfat", 100},
				{"/dev/disk9s1", "/Volumes/Two", "exfat", 100},
			},
			want: []string{"/dev/disk8s1", "/dev/disk9s1"},
		},
		{
			name: "independent different capacity disks",
			volumes: []volume{
				{"/dev/disk8s1", "/Volumes/One", "apfs", 101},
				{"/dev/disk9s1", "/Volumes/Two", "apfs", 100},
			},
			want: []string{"/dev/disk8s1", "/dev/disk9s1"},
		},
		{
			name: "shared APFS container with equal volume totals",
			volumes: []volume{
				{"/dev/disk8s1s1", "/", "apfs", 100},
				{"/dev/disk8s2", "/Volumes/Shared", "apfs", 100},
			},
			want: []string{"/dev/disk8s1s1"},
		},
		{
			name: "shared APFS container with snapshot and different volume totals",
			volumes: []volume{
				{"/dev/disk8s1s1", "/", "apfs", 100},
				{"/dev/disk8s2", "/Volumes/Shared", "apfs", 101},
				{"/dev/disk9s1", "/Volumes/Independent", "apfs", 100},
			},
			want: []string{"/dev/disk8s1s1", "/dev/disk9s1"},
		},
		{
			name: "internal first then largest external with three disk cap",
			volumes: []volume{
				{"/dev/disk8s1", "/Volumes/Small", "apfs", 100},
				{"/dev/disk9s1", "/Volumes/Large", "apfs", 300},
				{"/dev/disk3s1s1", "/", "apfs", 100},
				{"/dev/disk10s1", "/Volumes/Medium", "apfs", 200},
			},
			want: []string{"/dev/disk3s1s1", "/dev/disk9s1", "/dev/disk10s1"},
		},
	}
	for _, mode := range []string{"fast", "diskutil unavailable", "diskutil failed", "diskutil available"} {
		for _, tt := range tests {
			t.Run(mode+"/"+tt.name, func(t *testing.T) {
				if mode != "fast" && mode != "diskutil unavailable" && runtime.GOOS != "darwin" {
					t.Skip("diskutil corrections are macOS-only")
				}
				diskMetadataCache = make(map[string]diskMetadata)
				var parts []disk.PartitionStat
				for _, v := range tt.volumes {
					parts = append(parts, disk.PartitionStat{Device: v.device, Mountpoint: v.mount, Fstype: v.fstype})
				}
				diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) { return parts, nil }
				diskUsageFunc = func(path string) (*disk.UsageStat, error) {
					for _, v := range tt.volumes {
						if v.mount == path {
							total := v.gib << 30
							return &disk.UsageStat{Total: total, Used: total / 2, Free: total / 2, UsedPercent: 50}, nil
						}
					}
					t.Fatalf("unexpected usage path %q", path)
					return nil, errors.New("unexpected usage path")
				}
				commandExists = func(name string) bool {
					if mode == "fast" {
						t.Fatalf("fast collection checked external command %q", name)
					}
					return name == "diskutil" && mode != "diskutil unavailable"
				}
				runCmd = func(_ context.Context, name string, args ...string) (string, error) {
					if mode == "fast" || mode == "diskutil unavailable" || name != "diskutil" {
						t.Fatalf("unexpected command %q %q", name, args)
					}
					if mode == "diskutil failed" {
						return "", errors.New("diskutil failed")
					}
					if len(args) == 3 && args[1] == "-plist" {
						usage, _ := diskUsageFunc(args[2])
						return fmt.Sprintf("<plist><dict><key>TotalSize</key><integer>%d</integer></dict></plist>", usage.Total), nil
					}
					if args[1] == "disk3" {
						return "Internal: Yes", nil
					}
					return "Internal: No", nil
				}
				want := tt.want
				if mode == "diskutil unavailable" && len(tt.volumes) > 3 {
					// Without metadata all entries retain their existing External=false
					// default, so only capacity determines their order.
					want = []string{"/dev/disk9s1", "/dev/disk10s1", "/dev/disk8s1"}
				}
				got, err := collectDisksWithCorrections(mode != "fast")
				if err != nil {
					t.Fatal(err)
				}
				if len(got) != len(want) {
					t.Fatalf("got %d disks, want %d: %#v", len(got), len(want), got)
				}
				for i, device := range want {
					if got[i].Device != device {
						t.Errorf("disk %d = %q, want %q", i, got[i].Device, device)
					}
				}
			})
		}
	}
}

func TestCorrectDiskTotalBytes(t *testing.T) {
	origRunCmd := runCmd
	origCommandExists := commandExists
	t.Cleanup(func() {
		runCmd = origRunCmd
		commandExists = origCommandExists
	})

	commandExists = func(name string) bool {
		return name == "diskutil"
	}

	t.Run("uses diskutil total when meaningfully different", func(t *testing.T) {
		runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
			if name != "diskutil" {
				return "", errors.New("unexpected command")
			}
			return `<plist><dict><key>TotalSize</key><integer>1099511627776</integer></dict></plist>`, nil
		}

		got := correctDiskTotalBytes("/Volumes/Backup", 2199023255552)
		if got != 1099511627776 {
			t.Fatalf("correctDiskTotalBytes() = %d, want %d", got, uint64(1099511627776))
		}
	})

	t.Run("keeps raw total for small differences", func(t *testing.T) {
		runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
			return `<plist><dict><key>TotalSize</key><integer>1000500000000</integer></dict></plist>`, nil
		}

		const rawTotal = 1000000000000
		got := correctDiskTotalBytes("/Volumes/FastSSD", rawTotal)
		if got != rawTotal {
			t.Fatalf("correctDiskTotalBytes() = %d, want %d", got, uint64(rawTotal))
		}
	})

	t.Run("keeps raw total when diskutil fails", func(t *testing.T) {
		runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
			return "", errors.New("diskutil failed")
		}

		const rawTotal = 1099511627776
		got := correctDiskTotalBytes("/Volumes/FastSSD", rawTotal)
		if got != rawTotal {
			t.Fatalf("correctDiskTotalBytes() = %d, want %d", got, uint64(rawTotal))
		}
	})
}

func TestCollectDisksReadsDiskutilPlistOncePerVolume(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("diskutil corrections are macOS-only")
	}
	origPartitions := diskPartitionsFunc
	origUsage := diskUsageFunc
	origRunCmd := runCmd
	origCommandExists := commandExists
	t.Cleanup(func() {
		diskPartitionsFunc = origPartitions
		diskUsageFunc = origUsage
		runCmd = origRunCmd
		commandExists = origCommandExists
	})

	const plistTotal = uint64(1) << 40               // 1 TiB
	const containerFree = uint64(600) << 30          // 600 GiB
	const rawTotal = uint64(2) << 40                 // 2 TiB, doubled statfs
	const rawFree = uint64(700) << 30                // 700 GiB
	const rawUsed = rawTotal - rawFree               // ~1.3 TiB
	const correctedUsed = plistTotal - containerFree // 424 GiB
	const mountpoint = "/Volumes/Correction"

	diskPartitionsFunc = func(bool) ([]disk.PartitionStat, error) {
		return []disk.PartitionStat{
			{Device: "/dev/disk9s1", Mountpoint: mountpoint, Fstype: "apfs"},
		}, nil
	}
	diskUsageFunc = func(path string) (*disk.UsageStat, error) {
		if path != mountpoint {
			t.Fatalf("unexpected disk usage path %q", path)
		}
		return &disk.UsageStat{Path: path, Fstype: "apfs", Total: rawTotal, Used: rawUsed, Free: rawFree}, nil
	}
	commandExists = func(name string) bool { return name == "diskutil" }
	plistCalls := 0
	runCmd = func(_ context.Context, name string, args ...string) (string, error) {
		if name != "diskutil" {
			t.Fatalf("unexpected command %q", name)
		}
		for _, arg := range args {
			if arg == "-plist" {
				plistCalls++
			}
		}
		return `<plist><dict>
<key>TotalSize</key><integer>1099511627776</integer>
<key>APFSContainerFree</key><integer>644245094400</integer>
</dict></plist>`, nil
	}

	got, err := collectDisks()
	if err != nil {
		t.Fatalf("collectDisks() error = %v", err)
	}
	if plistCalls != 1 {
		t.Fatalf("collectDisks() ran %d `diskutil info -plist` probes for one volume, want 1", plistCalls)
	}
	if len(got) != 1 {
		t.Fatalf("collectDisks() returned %d disks, want 1: %#v", len(got), got)
	}
	if got[0].Total != plistTotal {
		t.Fatalf("Total = %d, want corrected %d", got[0].Total, plistTotal)
	}
	if got[0].Used != correctedUsed || got[0].Purgeable != 0 {
		t.Fatalf("Used/Purgeable = %d/%d, want %d/0", got[0].Used, got[0].Purgeable, correctedUsed)
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

func TestCorrectAPFSDiskUsageReportsFinderPurgeable(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("APFS Finder corrections are macOS-only")
	}
	// scripts/test.sh exports MOLE_TEST_NO_AUTH=1, which skips the Finder tier.
	t.Setenv("MOLE_TEST_MODE", "")
	t.Setenv("MOLE_TEST_NO_AUTH", "")

	origRunCmd := runCmd
	origCommandExists := commandExists
	origCachedAt := finderDiskCachedAt
	origFree := finderDiskFree
	origTotal := finderDiskTotal
	t.Cleanup(func() {
		runCmd = origRunCmd
		commandExists = origCommandExists
		finderDiskCachedAt = origCachedAt
		finderDiskFree = origFree
		finderDiskTotal = origTotal
	})
	finderDiskCachedAt = time.Time{}

	commandExists = func(name string) bool { return name == "osascript" }
	// Finder: 663.7 GB free of 1.8897 TB, i.e. statfs free (522.7 GB) plus
	// 141 GB purgeable, matching the #1357 scenario.
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		return "663700000000, 1889700000000", nil
	}

	total := uint64(1889700000000)
	rawFree := uint64(522700000000)
	rawUsed := total - rawFree
	used, usedPercent, purgeable := correctAPFSDiskUsage("/", total, rawUsed, rawFree)

	if want := total - uint64(663700000000); used != want {
		t.Fatalf("used = %d, want %d", used, want)
	}
	if usedPercent < 64.87 || usedPercent > 64.89 {
		t.Fatalf("usedPercent = %f, want ~64.88", usedPercent)
	}
	if purgeable != uint64(141000000000) {
		t.Fatalf("purgeable = %d, want %d", purgeable, uint64(141000000000))
	}
}

func TestCorrectAPFSDiskUsageClampsPurgeableToZero(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("APFS Finder corrections are macOS-only")
	}
	// scripts/test.sh exports MOLE_TEST_NO_AUTH=1, which skips the Finder tier.
	t.Setenv("MOLE_TEST_MODE", "")
	t.Setenv("MOLE_TEST_NO_AUTH", "")

	origRunCmd := runCmd
	origCommandExists := commandExists
	origCachedAt := finderDiskCachedAt
	origFree := finderDiskFree
	origTotal := finderDiskTotal
	t.Cleanup(func() {
		runCmd = origRunCmd
		commandExists = origCommandExists
		finderDiskCachedAt = origCachedAt
		finderDiskFree = origFree
		finderDiskTotal = origTotal
	})
	finderDiskCachedAt = time.Time{}

	commandExists = func(name string) bool { return name == "osascript" }
	// Finder free below the statfs free means there is no purgeable space.
	runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
		return "500000000000, 1889700000000", nil
	}

	total := uint64(1889700000000)
	rawFree := uint64(522700000000)
	rawUsed := total - rawFree
	_, _, purgeable := correctAPFSDiskUsage("/", total, rawUsed, rawFree)
	if purgeable != 0 {
		t.Fatalf("purgeable = %d, want 0", purgeable)
	}
}

func TestCorrectAPFSDiskUsageSkipsFinderUnderTestMode(t *testing.T) {
	for _, env := range []string{"MOLE_TEST_MODE", "MOLE_TEST_NO_AUTH"} {
		t.Run(env, func(t *testing.T) {
			t.Setenv("MOLE_TEST_MODE", "")
			t.Setenv("MOLE_TEST_NO_AUTH", "")
			t.Setenv(env, "1")

			origRunCmd := runCmd
			origCommandExists := commandExists
			origCachedAt := finderDiskCachedAt
			origFree := finderDiskFree
			origTotal := finderDiskTotal
			t.Cleanup(func() {
				runCmd = origRunCmd
				commandExists = origCommandExists
				finderDiskCachedAt = origCachedAt
				finderDiskFree = origFree
				finderDiskTotal = origTotal
			})
			finderDiskCachedAt = time.Time{}

			commandExists = func(name string) bool { return name == "osascript" || name == "diskutil" }
			var ran []string
			runCmd = func(ctx context.Context, name string, args ...string) (string, error) {
				ran = append(ran, name)
				switch name {
				case "osascript":
					return "663700000000, 1889700000000", nil
				case "diskutil":
					return "<dict><key>APFSContainerFree</key><integer>600000000000</integer></dict>", nil
				}
				return "", errors.New("unexpected command")
			}

			total := uint64(1889700000000)
			rawFree := uint64(522700000000)
			rawUsed := total - rawFree
			used, _, purgeable := correctAPFSDiskUsage("/", total, rawUsed, rawFree)

			for _, name := range ran {
				if name == "osascript" {
					t.Fatalf("%s=1 must not send Apple events to Finder, ran %v", env, ran)
				}
			}
			// Positive trace: the diskutil tier answered instead.
			if want := total - uint64(600000000000); used != want || purgeable != 0 {
				t.Fatalf("used = %d purgeable = %d, want diskutil fallback %d and 0 (ran %v)", used, purgeable, want, ran)
			}
		})
	}
}

func TestFinderPurgeableBytesIgnoresCorrectedTotal(t *testing.T) {
	// The regression this pins: purgeable was once derived from the
	// diskutil-corrected total minus statfs used, so the correction itself
	// showed up as purgeable space. The statfs free figure is the only
	// valid baseline.
	rawFree := uint64(500 << 30)
	finderFree := uint64(520 << 30)
	if got, want := finderPurgeableBytes(rawFree, finderFree), uint64(20<<30); got != want {
		t.Fatalf("purgeable = %d, want %d", got, want)
	}
	if got := finderPurgeableBytes(finderFree, rawFree); got != 0 {
		t.Fatalf("purgeable when finder below statfs = %d, want 0", got)
	}
}
