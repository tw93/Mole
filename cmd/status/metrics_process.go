package main

import (
	"container/heap"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"slices"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

type processSample struct {
	processes        []ProcessInfo
	parentsAvailable bool
	root             string // the /proc tree these pids came from; "" for a synthetic sample
}

var collectProcessesFunc = collectProcesses

const zombieParentLimit = 3

// collectProcesses reads the process table straight from /proc, so it works
// without procps and spawns nothing. CPU is a rate over the interval since the
// previous sample; the first sample of a pid falls back to its lifetime average,
// which is what ps shows.
func collectProcesses() (processSample, error) {
	return defaultProcSampler.sample("/", time.Now())
}

// procClockTicks is USER_HZ. The kernel exports /proc times in it and it is
// 100 on every Linux architecture Mole builds for; reading it through sysconf
// would need cgo.
const procClockTicks = 100.0

type procCPUPoint struct {
	ticks     uint64
	startTime uint64 // field 22 of stat; changes when the pid is reused
	appID     string // from /proc/<pid>/cgroup; read once per pid, since a process does not change app
}

type procSampler struct {
	mu     sync.Mutex
	prev   map[int]procCPUPoint
	prevAt time.Time
}

var defaultProcSampler = &procSampler{}

// procStat is the subset of /proc/<pid>/stat the status card needs.
type procStat struct {
	pid       int
	comm      string
	state     string
	ppid      int
	ticks     uint64 // utime + stime
	startTime uint64
	rssPages  uint64
}

// parseProcStat parses one /proc/<pid>/stat line. comm sits in parentheses and
// may itself contain spaces and parentheses, so split on the last ")".
func parseProcStat(raw string) (procStat, bool) {
	open := strings.IndexByte(raw, '(')
	closeIdx := strings.LastIndexByte(raw, ')')
	if open < 0 || closeIdx < open {
		return procStat{}, false
	}
	pid, err := strconv.Atoi(strings.TrimSpace(raw[:open]))
	if err != nil || pid <= 0 {
		return procStat{}, false
	}
	rest := strings.Fields(raw[closeIdx+1:])
	// rest[0] is field 3 (state), so field N is rest[N-3].
	if len(rest) < 22 {
		return procStat{}, false
	}
	ppid, err1 := strconv.Atoi(rest[1])
	utime, err2 := strconv.ParseUint(rest[11], 10, 64)
	stime, err3 := strconv.ParseUint(rest[12], 10, 64)
	start, err4 := strconv.ParseUint(rest[19], 10, 64)
	rss, err5 := strconv.ParseInt(rest[21], 10, 64)
	if err1 != nil || err2 != nil || err3 != nil || err4 != nil || err5 != nil || ppid < 0 {
		return procStat{}, false
	}
	if rss < 0 {
		rss = 0
	}
	return procStat{
		pid:       pid,
		comm:      raw[open+1 : closeIdx],
		state:     rest[0],
		ppid:      ppid,
		ticks:     utime + stime,
		startTime: start,
		rssPages:  uint64(rss),
	}, true
}

func readProcUptime(root string) float64 {
	fields := strings.Fields(readTrimmed(filepath.Join(root, "proc/uptime")))
	if len(fields) == 0 {
		return 0
	}
	v, _ := strconv.ParseFloat(fields[0], 64)
	return v
}

func readMemTotalBytes(root string) uint64 {
	data, err := os.ReadFile(filepath.Join(root, "proc/meminfo"))
	if err != nil {
		return 0
	}
	for line := range strings.Lines(string(data)) {
		rest, ok := strings.CutPrefix(line, "MemTotal:")
		if !ok {
			continue
		}
		fields := strings.Fields(rest)
		if len(fields) == 0 {
			return 0
		}
		kb, _ := strconv.ParseUint(fields[0], 10, 64)
		return kb * 1024
	}
	return 0
}

func (s *procSampler) sample(root string, now time.Time) (processSample, error) {
	dirs, err := filepath.Glob(filepath.Join(root, "proc/[0-9]*"))
	if err != nil {
		return processSample{}, err
	}
	uptime := readProcUptime(root)
	memTotal := readMemTotalBytes(root)
	pageSize := uint64(os.Getpagesize())

	s.mu.Lock()
	defer s.mu.Unlock()
	elapsed := now.Sub(s.prevAt).Seconds()
	usePrev := !s.prevAt.IsZero() && elapsed >= 0.2

	procs := make([]ProcessInfo, 0, len(dirs))
	next := make(map[int]procCPUPoint, len(dirs))
	for _, dir := range dirs {
		raw, err := os.ReadFile(filepath.Join(dir, "stat"))
		if err != nil {
			continue // exited between the glob and the read
		}
		st, ok := parseProcStat(string(raw))
		if !ok {
			continue
		}
		prev, seen := s.prev[st.pid]
		appID := ""
		if seen && prev.startTime == st.startTime {
			appID = prev.appID
		} else {
			appID = readAppID(dir)
		}
		next[st.pid] = procCPUPoint{ticks: st.ticks, startTime: st.startTime, appID: appID}

		cpuPct := 0.0
		if usePrev && seen && prev.startTime == st.startTime && st.ticks >= prev.ticks {
			cpuPct = float64(st.ticks-prev.ticks) / procClockTicks / elapsed * 100
		} else if life := uptime - float64(st.startTime)/procClockTicks; life > 0 {
			cpuPct = float64(st.ticks) / procClockTicks / life * 100
		}

		rssBytes := st.rssPages * pageSize
		memPct := 0.0
		if memTotal > 0 {
			memPct = float64(rssBytes) / float64(memTotal) * 100
		}
		procs = append(procs, ProcessInfo{
			PID:         st.pid,
			PPID:        st.ppid,
			State:       st.state,
			Name:        st.comm,
			Command:     st.comm,
			CPU:         cpuPct,
			Memory:      memPct,
			MemoryBytes: rssBytes,
			AppID:       appID,
		})
	}
	if len(procs) == 0 {
		return processSample{}, errors.New("no processes readable under /proc")
	}
	s.prev, s.prevAt = next, now
	return processSample{processes: procs, parentsAvailable: true, root: root}, nil
}

func isZombieState(state string) bool {
	return strings.HasPrefix(strings.TrimSpace(state), "Z")
}

func summarizeZombies(processes []ProcessInfo, limit int, parentsAvailable bool) (int, []ZombieParent, bool) {
	byPID := make(map[int]ProcessInfo, len(processes))
	for _, proc := range processes {
		byPID[proc.PID] = proc
	}

	count := 0
	complete := parentsAvailable
	byParent := make(map[int]int)
	for _, proc := range processes {
		if !isZombieState(proc.State) {
			continue
		}
		count++
		if !parentsAvailable {
			continue
		}
		if proc.PPID <= 0 {
			complete = false
			continue
		}
		parent, ok := byPID[proc.PPID]
		if !ok || parent.Name == "" {
			complete = false
			continue
		}
		byParent[proc.PPID]++
	}

	parents := make([]ZombieParent, 0, len(byParent))
	for ppid, zombieCount := range byParent {
		parents = append(parents, ZombieParent{
			PID:   ppid,
			Name:  byPID[ppid].Name,
			Count: zombieCount,
		})
	}
	sort.Slice(parents, func(i, j int) bool {
		if parents[i].Count != parents[j].Count {
			return parents[i].Count > parents[j].Count
		}
		if parents[i].Name != parents[j].Name {
			return parents[i].Name < parents[j].Name
		}
		return parents[i].PID < parents[j].PID
	})
	if limit <= 0 {
		if len(parents) > 0 {
			complete = false
		}
		return count, nil, complete
	}
	if len(parents) > limit {
		parents = parents[:limit]
		complete = false
	}
	return count, parents, complete
}

func topProcesses(processes []ProcessInfo, limit int) []ProcessInfo {
	if limit <= 0 || len(processes) == 0 {
		return nil
	}

	h := &processHeap{}
	heap.Init(h)
	for _, proc := range processes {
		if h.Len() < limit {
			heap.Push(h, proc)
			continue
		}
		if processRanksBefore(proc, (*h)[0]) {
			heap.Pop(h)
			heap.Push(h, proc)
		}
	}

	top := make([]ProcessInfo, h.Len())
	for i := range slices.Backward(top) {
		top[i] = heap.Pop(h).(ProcessInfo)
	}
	return top
}

func formatProcessLabel(proc ProcessInfo) string {
	if proc.Name != "" {
		return fmt.Sprintf("%s (%d)", proc.Name, proc.PID)
	}
	return fmt.Sprintf("pid %d", proc.PID)
}

func processRanksBefore(a, b ProcessInfo) bool {
	if a.CPU != b.CPU {
		return a.CPU > b.CPU
	}
	if a.Memory != b.Memory {
		return a.Memory > b.Memory
	}
	return a.PID < b.PID
}

type processHeap []ProcessInfo

func (h processHeap) Len() int { return len(h) }

func (h processHeap) Less(i, j int) bool {
	return processRanksBefore(h[j], h[i])
}

func (h processHeap) Swap(i, j int) {
	h[i], h[j] = h[j], h[i]
}

func (h *processHeap) Push(x any) {
	*h = append(*h, x.(ProcessInfo))
}

func (h *processHeap) Pop() any {
	old := *h
	n := len(old)
	x := old[n-1]
	*h = old[:n-1]
	return x
}
