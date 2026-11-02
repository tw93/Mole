package main

import (
	"os"
	"path/filepath"
	"testing"
	"time"
)

const amdFdinfo = "pos:\t0\nflags:\t02000002\ndrm-driver:\tamdgpu\ndrm-pdev:\t0000:03:00.0\ndrm-client-id:\t7\ndrm-memory-vram:\t2048 KiB\ndrm-memory-gtt:\t1 MiB\ndrm-memory-cpu:\t0 KiB\n"
const i915Fdinfo = "drm-driver:\ti915\ndrm-pdev:\t0000:00:02.0\ndrm-client-id:\t12\ndrm-total-system0:\t10 MiB\ndrm-resident-system0:\t4 MiB\ndrm-total-local0:\t8 MiB\n"

func TestParseDRMFdinfo(t *testing.T) {
	info, ok := parseDRMFdinfo(amdFdinfo)
	if !ok || info.clientID != "7" || info.driver != "amdgpu" || info.bytes != 3<<20 {
		t.Fatalf("amd = %#v, %v", info, ok)
	}
	// Resident beats total for the same region; a region with only total uses total.
	info, ok = parseDRMFdinfo(i915Fdinfo)
	if !ok || info.bytes != (4+8)<<20 {
		t.Fatalf("i915 = %#v, %v", info, ok)
	}
	for _, raw := range []string{"", "pos:\t0\nflags:\t02\n", "drm-memory-vram:\t5 KiB\n"} {
		if _, ok := parseDRMFdinfo(raw); ok {
			t.Fatalf("parseDRMFdinfo(%q) ok", raw)
		}
	}
	if _, ok := parseDRMSize("12 TB"); ok {
		t.Fatal("unknown unit accepted")
	}
	if n, ok := parseDRMSize("4096"); !ok || n != 4096 {
		t.Fatalf("plain bytes = %d, %v", n, ok)
	}
}

// drmFdFixture makes pid with the given fds: fd name to (link target, fdinfo).
func drmFdFixture(t *testing.T, root string, pid int, fds map[string][2]string) {
	t.Helper()
	base := filepath.Join(root, "proc", itoa(pid))
	for name, v := range fds {
		if err := os.MkdirAll(filepath.Join(base, "fd"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.MkdirAll(filepath.Join(base, "fdinfo"), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.Symlink(v[0], filepath.Join(base, "fd", name)); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(filepath.Join(base, "fdinfo", name), []byte(v[1]), 0o644); err != nil {
			t.Fatal(err)
		}
	}
}

func TestScanDRMMemoryCountsEachClientOncePerDevice(t *testing.T) {
	root := t.TempDir()
	drmFdFixture(t, root, 100, map[string][2]string{
		"5": {"/dev/dri/renderD128", amdFdinfo},
		"6": {"/dev/dri/renderD128", amdFdinfo}, // same client twice in one process
		"7": {"/dev/null", amdFdinfo},           // not a DRM node: never opened
	})
	drmFdFixture(t, root, 101, map[string][2]string{
		"3": {"/dev/dri/card0", amdFdinfo}, // same client inherited by a child
		"4": {"/dev/dri/renderD129", "drm-driver:\tamdgpu\ndrm-pdev:\t0000:04:00.0\ndrm-client-id:\t7\ndrm-memory-vram:\t1 MiB\n"},
	})
	got := scanDRMMemory(root, []int{100, 101, 999})
	if got[100] != 3<<20 {
		t.Fatalf("pid 100 = %d, want 3 MiB once", got[100])
	}
	// Client id 7 on a different device (pdev) is a different client.
	if got[101] != 1<<20 {
		t.Fatalf("pid 101 = %d, want only the second device's 1 MiB", got[101])
	}
	if _, ok := got[999]; ok {
		t.Fatal("unreadable pid reported")
	}
}

func resetDRMCache() {
	drmCache.Lock()
	drmCache.byPID, drmCache.at = nil, time.Time{}
	drmCache.Unlock()
}

func TestAttachGPUMemoryNeedsAGPUAndReusesTheScan(t *testing.T) {
	resetDRMCache()
	t.Cleanup(resetDRMCache)
	root := t.TempDir()
	drmFdFixture(t, root, 100, map[string][2]string{"5": {"/dev/dri/renderD128", amdFdinfo}})
	procs := func() []ProcessInfo {
		return []ProcessInfo{{PID: 100, Name: "game", CPU: 50, MemoryBytes: 1}}
	}
	rows := []AppInfo{{Kind: appKindProcess, PID: 100}}
	now := time.Unix(5000, 0)

	// No /sys/class/drm card: nothing is scanned even though the fd exists.
	p := procs()
	attachGPUMemory(root, p, rows, now)
	if p[0].GPUMemoryBytes != 0 {
		t.Fatalf("scanned without a GPU: %d", p[0].GPUMemoryBytes)
	}

	resetDRMCache()
	addTree(t, root, map[string]string{"sys/class/drm/card0/device/vendor": "0x1002\n"})
	p = procs()
	attachGPUMemory(root, p, rows, now)
	if p[0].GPUMemoryBytes != 3<<20 {
		t.Fatalf("gpu memory = %d, want 3 MiB", p[0].GPUMemoryBytes)
	}
	// Within the interval the cached value is reused even if the fd vanished.
	if err := os.RemoveAll(filepath.Join(root, "proc/100/fd")); err != nil {
		t.Fatal(err)
	}
	p = procs()
	attachGPUMemory(root, p, rows, now.Add(time.Second))
	if p[0].GPUMemoryBytes != 3<<20 {
		t.Fatalf("cached value lost: %d", p[0].GPUMemoryBytes)
	}
	p = procs()
	attachGPUMemory(root, p, rows, now.Add(drmScanInterval))
	if p[0].GPUMemoryBytes != 0 {
		t.Fatalf("stale value after the interval: %d", p[0].GPUMemoryBytes)
	}
}

func TestDRMCandidatePIDsStayWithinTheTopRowsAndTheCap(t *testing.T) {
	var procs []ProcessInfo
	for i := 1; i <= 100; i++ {
		procs = append(procs, ProcessInfo{PID: i, AppID: "big", MemoryBytes: uint64(i)})
	}
	procs = append(procs, ProcessInfo{PID: 500, AppID: "other", MemoryBytes: 1 << 40}, ProcessInfo{PID: 600, Name: "solo", MemoryBytes: 5})
	got := drmCandidatePIDs(procs, []AppInfo{{Kind: appKindApp, ID: "big"}, {Kind: appKindProcess, PID: 600}})
	if len(got) != drmMaxPIDs {
		t.Fatalf("len = %d, want cap %d", len(got), drmMaxPIDs)
	}
	for _, pid := range got {
		if pid == 500 {
			t.Fatal("process outside the top rows was scanned")
		}
	}
	if got[0] != 100 {
		t.Fatalf("first = %d, want biggest memory first", got[0])
	}
}
