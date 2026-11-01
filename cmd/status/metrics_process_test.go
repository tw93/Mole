package main

import (
	"os"
	"path/filepath"
	"strconv"
	"testing"
	"time"
)

// A /proc/<pid>/stat line: pid (comm) state ppid ... field 14 utime, 15 stime,
// 22 starttime, 24 rss. Fields 4-13 and 16-21 are filler zeros here.
func statLine(pid int, comm, state string, ppid int, utime, stime, start, rss uint64) string {
	return itoa(pid) + " (" + comm + ") " + state + " " + itoa(ppid) +
		" 0 0 0 0 0 0 0 0 0 " + // fields 5-13
		u(utime) + " " + u(stime) + // 14, 15
		" 0 0 20 0 1 0 " + // 16-21
		u(start) + " 0 " + u(rss) + " 0\n" // 22, 23 (vsize), 24 (rss)
}

func itoa(n int) string { return strconv.Itoa(n) }
func u(n uint64) string { return strconv.FormatUint(n, 10) }

func TestParseProcStatHandlesAwkwardComm(t *testing.T) {
	line := statLine(4242, "Web Content (x) 1", "S", 100, 300, 100, 5000, 2560)
	st, ok := parseProcStat(line)
	if !ok {
		t.Fatalf("parseProcStat() ok = false for %q", line)
	}
	if st.pid != 4242 || st.comm != "Web Content (x) 1" || st.state != "S" || st.ppid != 100 {
		t.Fatalf("parseProcStat() = %#v", st)
	}
	if st.ticks != 400 || st.startTime != 5000 || st.rssPages != 2560 {
		t.Fatalf("parseProcStat() times/rss = %#v", st)
	}
}

func TestParseProcStatRejectsTruncatedAndGarbage(t *testing.T) {
	for _, raw := range []string{"", "garbage", "12 (short) S 1 2 3\n", "x (a) S 1 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0\n"} {
		if _, ok := parseProcStat(raw); ok {
			t.Fatalf("parseProcStat(%q) ok = true", raw)
		}
	}
}

func procFixture(t *testing.T, uptime string, procs map[int]string) string {
	t.Helper()
	files := map[string]string{
		"proc/uptime":  uptime + " 100.00\n",
		"proc/meminfo": "MemTotal:        1048576 kB\nMemFree: 1 kB\n",
	}
	for pid, stat := range procs {
		files["proc/"+itoa(pid)+"/stat"] = stat
	}
	files["proc/self/stat"] = "not a pid directory\n"
	return writeTree(t, files)
}

func TestProcSamplerLifetimeThenIntervalCPU(t *testing.T) {
	pageSize := uint64(os.Getpagesize())
	rssPages := uint64(100<<20) / pageSize // 100 MiB of 1 GiB total
	root := procFixture(t, "1000.00", map[int]string{
		1:   statLine(1, "init", "S", 0, 100, 0, 0, rssPages),
		200: statLine(200, "busy", "R", 1, 40000, 10000, 50000, rssPages), // started 500 s in, 500 s CPU
		300: statLine(300, "ghost", "Z", 1, 0, 0, 90000, 0),
	})
	sampler := &procSampler{}
	t0 := time.Unix(1_000_000, 0)

	first, err := sampler.sample(root, t0)
	if err != nil {
		t.Fatalf("sample() error = %v", err)
	}
	if !first.parentsAvailable || len(first.processes) != 3 {
		t.Fatalf("first sample = %#v", first)
	}
	byPID := map[int]ProcessInfo{}
	for _, p := range first.processes {
		byPID[p.PID] = p
	}
	// Lifetime average: 500 s CPU over 500 s of life = 100%.
	if got := byPID[200].CPU; got < 99 || got > 101 {
		t.Fatalf("lifetime CPU = %.2f, want about 100", got)
	}
	if got := byPID[200].Memory; got < 9.7 || got > 9.8 {
		t.Fatalf("memory percent = %.2f, want about 9.77 (100 MiB of 1 GiB)", got)
	}
	if byPID[200].MemoryBytes != rssPages*pageSize || byPID[200].PPID != 1 || byPID[200].Name != "busy" {
		t.Fatalf("process 200 = %#v", byPID[200])
	}
	if !isZombieState(byPID[300].State) {
		t.Fatalf("process 300 state = %q, want zombie", byPID[300].State)
	}

	// Two seconds later pid 200 used 100 more ticks (1 s) of CPU: 50%.
	addTree(t, root, map[string]string{
		"proc/200/stat": statLine(200, "busy", "R", 1, 40100, 10000, 50000, rssPages),
	})
	second, err := sampler.sample(root, t0.Add(2*time.Second))
	if err != nil {
		t.Fatalf("second sample() error = %v", err)
	}
	for _, p := range second.processes {
		if p.PID == 200 && (p.CPU < 49.9 || p.CPU > 50.1) {
			t.Fatalf("interval CPU = %.2f, want 50", p.CPU)
		}
	}
}

func TestProcSamplerTreatsReusedPIDAsNew(t *testing.T) {
	root := procFixture(t, "1000.00", map[int]string{
		200: statLine(200, "old", "S", 1, 9000, 0, 100, 1),
	})
	sampler := &procSampler{}
	t0 := time.Unix(1_000_000, 0)
	if _, err := sampler.sample(root, t0); err != nil {
		t.Fatal(err)
	}
	// Same pid, new start time and a tiny counter: the delta would underflow.
	addTree(t, root, map[string]string{"proc/200/stat": statLine(200, "new", "S", 1, 10, 0, 99000, 1)})
	got, err := sampler.sample(root, t0.Add(time.Second))
	if err != nil || len(got.processes) != 1 {
		t.Fatalf("sample() = %#v, %v", got, err)
	}
	if cpu := got.processes[0].CPU; cpu < 0 || cpu > 100 {
		t.Fatalf("reused pid CPU = %v, want a sane lifetime average", cpu)
	}
}

func TestProcSamplerFailsWhenProcIsUnreadable(t *testing.T) {
	if _, err := (&procSampler{}).sample(t.TempDir(), time.Now()); err == nil {
		t.Fatal("sample() on an empty /proc returned nil error")
	}
}

func TestProcSamplerSkipsVanishedProcess(t *testing.T) {
	root := procFixture(t, "1000.00", map[int]string{1: statLine(1, "init", "S", 0, 1, 1, 1, 1)})
	// A pid directory whose stat file is gone, as when the process just exited.
	if err := os.MkdirAll(filepath.Join(root, "proc/999"), 0o755); err != nil {
		t.Fatal(err)
	}
	got, err := (&procSampler{}).sample(root, time.Now())
	if err != nil || len(got.processes) != 1 {
		t.Fatalf("sample() = %#v, %v; want only pid 1", got, err)
	}
}

func TestCollectProcessesReadsLiveProc(t *testing.T) {
	if _, err := os.Stat("/proc/self/stat"); err != nil {
		t.Skip("no /proc on this host")
	}
	sample, err := collectProcesses()
	if err != nil {
		t.Fatalf("collectProcesses() error = %v", err)
	}
	self := os.Getpid()
	for _, p := range sample.processes {
		if p.PID == self {
			if p.Name == "" || p.MemoryBytes == 0 {
				t.Fatalf("own process row = %#v", p)
			}
			return
		}
	}
	t.Fatalf("own pid %d missing from %d processes", self, len(sample.processes))
}

func TestSummarizeZombiesAttributesParentsFromProc(t *testing.T) {
	root := procFixture(t, "1000.00", map[int]string{
		10: statLine(10, "Web Content", "S", 1, 1, 1, 1, 1),
		11: statLine(11, "worker", "Z", 10, 0, 0, 5, 0),
		12: statLine(12, "worker", "Z", 10, 0, 0, 6, 0),
	})
	sample, err := (&procSampler{}).sample(root, time.Now())
	if err != nil {
		t.Fatal(err)
	}
	count, parents, complete := summarizeZombies(sample.processes, zombieParentLimit, sample.parentsAvailable)
	if count != 2 || len(parents) != 1 || parents[0] != (ZombieParent{PID: 10, Name: "Web Content", Count: 2}) || !complete {
		t.Fatalf("zombies = %d %#v complete=%v", count, parents, complete)
	}
}
