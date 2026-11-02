package main

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

// Per-process GPU memory comes from DRM fdinfo (kernel drm-usage-stats): each
// open DRM file shows "drm-client-id" and memory keys in /proc/<pid>/fdinfo/<fd>,
// readable for the user's own processes without root. The cost is bounded three
// ways: only the processes of the rows on screen are scanned (at most
// drmMaxPIDs), an fd is opened only after its symlink says /dev/dri, and the
// result is reused for drmScanInterval.
const (
	drmMaxPIDs      = 64
	drmScanInterval = 5 * time.Second
)

var drmCache = struct {
	sync.Mutex
	at    time.Time
	byPID map[int]uint64
}{}

type drmFdinfo struct {
	driver, pdev string
	clientID     string
	bytes        uint64
}

// parseDRMFdinfo returns ok=false for an fdinfo that is not a DRM client.
// One number is taken per memory region: resident bytes where the driver
// reports them, else drm-memory-<region> (amdgpu), else drm-total-<region>.
// Regions are summed, so on an integrated GPU the figure includes system
// memory the GPU holds (i915 "system0"), which is what the process costs the
// machine.
func parseDRMFdinfo(raw string) (drmFdinfo, bool) {
	var info drmFdinfo
	type region struct{ resident, memory, total *uint64 }
	regions := map[string]*region{}
	sc := bufio.NewScanner(strings.NewReader(raw))
	for sc.Scan() {
		key, val, found := strings.Cut(sc.Text(), ":")
		if !found {
			continue
		}
		val = strings.TrimSpace(val)
		switch {
		case key == "drm-client-id":
			info.clientID = val
		case key == "drm-driver":
			info.driver = val
		case key == "drm-pdev":
			info.pdev = val
		case strings.HasPrefix(key, "drm-resident-"), strings.HasPrefix(key, "drm-memory-"), strings.HasPrefix(key, "drm-total-"):
			prefix, name, _ := strings.Cut(key[len("drm-"):], "-")
			n, ok := parseDRMSize(val)
			if !ok {
				continue
			}
			r := regions[name]
			if r == nil {
				r = &region{}
				regions[name] = r
			}
			switch prefix {
			case "resident":
				r.resident = &n
			case "memory":
				r.memory = &n
			case "total":
				r.total = &n
			}
		}
	}
	if info.clientID == "" {
		return drmFdinfo{}, false
	}
	for _, r := range regions {
		switch {
		case r.resident != nil:
			info.bytes += *r.resident
		case r.memory != nil:
			info.bytes += *r.memory
		case r.total != nil:
			info.bytes += *r.total
		}
	}
	return info, true
}

// parseDRMSize reads "12345", "512 KiB", "3 MiB" or "1 GiB" into bytes.
func parseDRMSize(v string) (uint64, bool) {
	fields := strings.Fields(v)
	if len(fields) == 0 || len(fields) > 2 {
		return 0, false
	}
	n, err := strconv.ParseUint(fields[0], 10, 64)
	if err != nil {
		return 0, false
	}
	if len(fields) == 2 {
		switch fields[1] {
		case "KiB":
			n <<= 10
		case "MiB":
			n <<= 20
		case "GiB":
			n <<= 30
		default:
			return 0, false
		}
	}
	return n, true
}

// scanDRMMemory returns GPU memory by pid for the given pids. Each
// (driver, pdev, drm-client-id) counts once: a client shared through fork or
// SCM_RIGHTS appears in several processes and several fds, and is charged to
// the first pid that shows it.
func scanDRMMemory(root string, pids []int) map[int]uint64 {
	result := make(map[int]uint64)
	seen := make(map[string]bool)
	for _, pid := range pids {
		base := filepath.Join(root, "proc", strconv.Itoa(pid))
		fds, err := os.ReadDir(filepath.Join(base, "fd"))
		if err != nil {
			continue
		}
		for _, fd := range fds {
			target, err := os.Readlink(filepath.Join(base, "fd", fd.Name()))
			if err != nil || !strings.HasPrefix(target, "/dev/dri/") {
				continue
			}
			raw, err := os.ReadFile(filepath.Join(base, "fdinfo", fd.Name()))
			if err != nil {
				continue
			}
			info, ok := parseDRMFdinfo(string(raw))
			if !ok {
				continue
			}
			key := info.driver + "\x00" + info.pdev + "\x00" + info.clientID
			if seen[key] {
				continue
			}
			seen[key] = true
			if info.bytes > 0 {
				result[pid] += info.bytes
			}
		}
	}
	return result
}

// drmCandidatePIDs lists the processes behind the top rows, biggest memory
// first, capped at drmMaxPIDs.
func drmCandidatePIDs(procs []ProcessInfo, rows []AppInfo) []int {
	apps := make(map[string]bool)
	pids := make(map[int]bool)
	for _, r := range rows {
		if r.Kind == appKindApp {
			apps[r.ID] = true
		} else {
			pids[r.PID] = true
		}
	}
	var cands []ProcessInfo
	for _, p := range procs {
		if pids[p.PID] || (p.AppID != "" && apps[p.AppID]) {
			cands = append(cands, p)
		}
	}
	sort.Slice(cands, func(i, j int) bool {
		if cands[i].MemoryBytes != cands[j].MemoryBytes {
			return cands[i].MemoryBytes > cands[j].MemoryBytes
		}
		return cands[i].PID < cands[j].PID
	})
	if len(cands) > drmMaxPIDs {
		cands = cands[:drmMaxPIDs]
	}
	out := make([]int, len(cands))
	for i, p := range cands {
		out[i] = p.PID
	}
	return out
}

// attachGPUMemory fills ProcessInfo.GPUMemoryBytes for the processes behind the
// top rows when the machine has a DRM device. now drives the reuse window.
func attachGPUMemory(root string, procs []ProcessInfo, rows []AppInfo, now time.Time) {
	drmCache.Lock()
	defer drmCache.Unlock()
	if drmCache.byPID == nil || now.Sub(drmCache.at) >= drmScanInterval || now.Before(drmCache.at) {
		if len(listDRMGPUs(root)) == 0 {
			drmCache.byPID = map[int]uint64{}
		} else {
			drmCache.byPID = scanDRMMemory(root, drmCandidatePIDs(procs, rows))
		}
		drmCache.at = now
	}
	if len(drmCache.byPID) == 0 {
		return
	}
	for i := range procs {
		procs[i].GPUMemoryBytes = drmCache.byPID[procs[i].PID]
	}
}
