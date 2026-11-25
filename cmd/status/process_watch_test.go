package main

import (
	"context"
	"encoding/json"
	"runtime"
	"strings"
	"testing"
	"time"
)

// Guards #1267: ps and uptime emit comma decimals under locales like
// ru_RU.UTF-8, which made every ParseFloat in the collectors fail.
func TestRunCmdForcesCLocale(t *testing.T) {
	t.Setenv("LC_ALL", "ru_RU.UTF-8")
	t.Setenv("LC_NUMERIC", "ru_RU.UTF-8")
	t.Setenv("LANG", "ru_RU.UTF-8")

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "sh", "-c", "printf '%s|%s|%s' \"$LC_ALL\" \"$LC_NUMERIC\" \"$LANG\"")
	if err != nil {
		t.Fatalf("runCmd() error = %v", err)
	}
	if out != "C||" {
		t.Fatalf("runCmd() subprocess locale = %q, want %q", out, "C||")
	}
}

func TestCollectProcessesUnderCommaLocale(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("ps output format is darwin-specific")
	}
	t.Setenv("LC_ALL", "ru_RU.UTF-8")
	t.Setenv("LC_NUMERIC", "ru_RU.UTF-8")

	sample, err := collectProcesses()
	if err != nil {
		t.Fatalf("collectProcesses() error = %v", err)
	}
	if len(sample.processes) == 0 {
		t.Fatal("collectProcesses() returned no processes under a comma-decimal locale")
	}
	if !sample.parentsAvailable {
		t.Fatal("primary process sample should include parent metadata")
	}
}

func TestParsePsAuxOutputStrictAcceptsCurrentDarwinOutput(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("ps output format is darwin-specific")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := runCmd(ctx, "ps", "aux")
	if err != nil {
		t.Fatalf("ps aux error = %v", err)
	}
	procs, err := parsePsAuxOutputStrict(out)
	if err != nil {
		t.Fatalf("parsePsAuxOutputStrict(current output) error = %v", err)
	}
	if len(procs) == 0 {
		t.Fatal("parsePsAuxOutputStrict(current output) returned no processes")
	}
}

func TestParsePrimaryProcessOutputStrictAcceptsCurrentDarwinOutput(t *testing.T) {
	if runtime.GOOS != "darwin" {
		t.Skip("ps output format is darwin-specific")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	out, err := runCmd(ctx, "ps", "-Aceo", "pid=,ppid=,state=,pcpu=,pmem=,rss=,comm=", "-r")
	if err != nil {
		t.Fatalf("primary ps command error = %v", err)
	}
	procs, err := parseProcessOutputStrict(out)
	if err != nil {
		t.Fatalf("parseProcessOutputStrict(current output) error = %v", err)
	}
	if len(procs) == 0 {
		t.Fatal("parseProcessOutputStrict(current output) returned no processes")
	}
}

func TestCollectProcessesMarksFallbackParentAttributionIncomplete(t *testing.T) {
	originalRunCmd := runCmd
	t.Cleanup(func() { runCmd = originalRunCmd })

	runCmd = func(_ context.Context, _ string, args ...string) (string, error) {
		if len(args) > 0 && args[0] == "-Aceo" {
			return "malformed primary output", nil
		}
		return strings.Join([]string{
			"USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND",
			"raj 11 0.0 0.0 0 0 ?? Z+ 10:00AM 0:00 child <defunct>",
		}, "\n"), nil
	}

	sample, err := collectProcesses()
	if err != nil {
		t.Fatalf("collectProcesses() error = %v", err)
	}
	if sample.parentsAvailable {
		t.Fatal("ps aux fallback should not claim parent metadata")
	}
	if len(sample.processes) != 1 || !isZombieState(sample.processes[0].State) {
		t.Fatalf("unexpected fallback sample: %#v", sample.processes)
	}
}

func TestParseProcessOutputStrictCapturesStateAndResidentMemory(t *testing.T) {
	raw := strings.Join([]string{
		"123 10 Z+ 0.0 0.0 0 worker <defunct>",
		"456 10 S 1.5 0.2 1024 /usr/bin/worker",
	}, "\n")

	procs, err := parseProcessOutputStrict(raw)
	if err != nil {
		t.Fatalf("parseProcessOutputStrict() error = %v", err)
	}
	if len(procs) != 2 {
		t.Fatalf("parseProcessOutputStrict() len = %d, want 2", len(procs))
	}
	if procs[0].State != "Z+" {
		t.Fatalf("zombie state = %q, want Z+", procs[0].State)
	}
	if procs[1].State != "S" {
		t.Fatalf("ordinary state = %q, want S", procs[1].State)
	}
	if procs[1].MemoryBytes != 1024*1024 {
		t.Fatalf("resident memory = %d, want %d", procs[1].MemoryBytes, 1024*1024)
	}
}

func TestPrimaryProcessOutputPreservesMultiwordZombieParentName(t *testing.T) {
	raw := strings.Join([]string{
		"123 1 S 0.0 0.1 1024 /Applications/Microsoft Edge.app/Contents/MacOS/Microsoft Edge Helper (Renderer)",
		"456 123 Z 0.0 0.0 0 child <defunct>",
	}, "\n")

	procs, err := parseProcessOutputStrict(raw)
	if err != nil {
		t.Fatalf("parseProcessOutputStrict() error = %v", err)
	}
	count, parents, complete := summarizeZombies(procs, zombieParentLimit, true)
	if count != 1 || len(parents) != 1 {
		t.Fatalf("unexpected zombie summary: count=%d parents=%#v", count, parents)
	}
	if parents[0] != (ZombieParent{PID: 123, Name: "Microsoft Edge Helper (Renderer)", Count: 1}) {
		t.Fatalf("zombie parent = %#v", parents[0])
	}
	if !complete {
		t.Fatal("complete primary process table should preserve complete parent attribution")
	}
}

func TestParsePsAuxOutputCapturesResidentMemory(t *testing.T) {
	raw := strings.Join([]string{
		"USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND",
		"raj 123 4.5 6.0 123456 2097152 ?? S 10:00AM 1:23 /Applications/Chrome.app/Contents/MacOS/Chrome --type=renderer",
	}, "\n")

	procs, err := parsePsAuxOutputStrict(raw)
	if err != nil {
		t.Fatalf("parsePsAuxOutputStrict() error = %v", err)
	}
	if len(procs) != 1 {
		t.Fatalf("parsePsAuxOutputStrict() len = %d, want 1", len(procs))
	}
	if procs[0].MemoryBytes != 2097152*1024 {
		t.Fatalf("unexpected memory bytes %d", procs[0].MemoryBytes)
	}
	if procs[0].State != "S" {
		t.Fatalf("unexpected process state %q", procs[0].State)
	}
	if !strings.Contains(procs[0].Command, "--type=renderer") {
		t.Fatalf("command path missing args: %q", procs[0].Command)
	}
}

func TestFallbackCountsZombiesWithoutGuessingParents(t *testing.T) {
	raw := strings.Join([]string{
		"USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND",
		"raj 10 1.0 1.0 100 10 ?? S 10:00AM 0:01 /Applications/Chrome.app/Contents/MacOS/Chrome",
		"raj 11 0.0 0.0 0 0 ?? Z+ 10:00AM 0:00 child <defunct>",
	}, "\n")
	procs, err := parsePsAuxOutputStrict(raw)
	if err != nil {
		t.Fatalf("parsePsAuxOutputStrict() error = %v", err)
	}

	count, parents, complete := summarizeZombies(procs, 3, false)
	if count != 1 {
		t.Fatalf("fallback zombie count = %d, want 1", count)
	}
	if len(parents) != 0 {
		t.Fatalf("fallback should omit unknown parent detail, got %#v", parents)
	}
	if complete {
		t.Fatal("fallback parent attribution should be marked incomplete")
	}
}

func TestStrictProcessParsersRejectPartialTables(t *testing.T) {
	if _, err := parseProcessOutputStrict("123 1 Z 0.0 0.0 0 child\nbad line"); err == nil {
		t.Fatal("parseProcessOutputStrict() accepted a partial process table")
	}
	for name, raw := range map[string]string{
		"missing state": "123 1 0.0 0.0 0 child",
		"bad ppid":      "123 parent Z 0.0 0.0 0 child",
		"bad rss":       "123 1 Z 0.0 0.0 unknown child",
		"reordered":     "123 1 0.0 Z 0.0 0 child",
	} {
		t.Run(name, func(t *testing.T) {
			if _, err := parseProcessOutputStrict(raw); err == nil {
				t.Fatalf("parseProcessOutputStrict(%q) accepted malformed output", raw)
			}
		})
	}
	if _, err := parsePsAuxOutputStrict("USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND\nbad line"); err == nil {
		t.Fatal("parsePsAuxOutputStrict() accepted a partial process table")
	}
	malformedState := "USER PID %CPU %MEM VSZ RSS TT STAT STARTED TIME COMMAND\nraj 11 0.0 0.0 0 0 ?? ZOMBIE 10:00AM 0:00 child"
	if _, err := parsePsAuxOutputStrict(malformedState); err == nil {
		t.Fatal("parsePsAuxOutputStrict() accepted malformed STAT")
	}
	reordered := "USER PID %MEM %CPU VSZ RSS TT STAT STARTED TIME COMMAND\nraj 11 0.0 0.0 0 0 ?? Z 10:00AM 0:00 child"
	if _, err := parsePsAuxOutputStrict(reordered); err == nil {
		t.Fatal("parsePsAuxOutputStrict() accepted reordered columns")
	}
}

func TestProcessStateTokenGrammar(t *testing.T) {
	for _, state := range []string{"?", "?+", "?E", "D", "I", "R", "S", "T", "U", "W", "Z", "Z+", "Ss", "R<", "SN+", "S>", "RE", "SV", "RX", "SAW"} {
		if !isProcessStateToken(state) {
			t.Fatalf("isProcessStateToken(%q) = false, want true", state)
		}
	}
	for _, state := range []string{"", "ZOMBIE", "sleeping", "0", "Z?"} {
		if isProcessStateToken(state) {
			t.Fatalf("isProcessStateToken(%q) = true, want false", state)
		}
	}
}

func TestSummarizeZombiesCountsAndRanksKnownParents(t *testing.T) {
	processes := []ProcessInfo{
		{PID: 10, Name: "Chrome"},
		{PID: 20, Name: "zsh"},
		{PID: 101, PPID: 10, State: "Z", Name: "child-a"},
		{PID: 102, PPID: 10, State: "Z+", Name: "child-b"},
		{PID: 103, PPID: 20, State: "Z", Name: "child-c"},
		{PID: 104, PPID: 999, State: "Z", Name: "unknown-parent"},
		{PID: 105, PPID: 10, State: "S", Name: "live-child"},
	}

	count, parents, complete := summarizeZombies(processes, 3, true)
	if count != 4 {
		t.Fatalf("zombie count = %d, want 4", count)
	}
	if len(parents) != 2 {
		t.Fatalf("zombie parents = %#v, want 2 known parents", parents)
	}
	if parents[0] != (ZombieParent{PID: 10, Name: "Chrome", Count: 2}) {
		t.Fatalf("first zombie parent = %#v", parents[0])
	}
	if parents[1] != (ZombieParent{PID: 20, Name: "zsh", Count: 1}) {
		t.Fatalf("second zombie parent = %#v", parents[1])
	}
	if complete {
		t.Fatal("missing parent row should mark attribution incomplete")
	}

	_, limited, limitedComplete := summarizeZombies(processes, 1, true)
	if len(limited) != 1 || limited[0].PID != 10 {
		t.Fatalf("limited zombie parents = %#v", limited)
	}
	if limitedComplete {
		t.Fatal("truncated parent list should be marked incomplete")
	}
}

func TestSummarizeZombiesHealthySample(t *testing.T) {
	processes := []ProcessInfo{{PID: 1, State: "S", Name: "parent"}}
	count, parents, complete := summarizeZombies(processes, zombieParentLimit, true)
	if count != 0 || parents == nil || len(parents) != 0 || !complete {
		t.Fatalf("healthy sample = %d, %#v, %t; want zero, an empty parent list, and complete attribution",
			count, parents, complete)
	}
}

func BenchmarkSummarizeZombies(b *testing.B) {
	for _, tc := range []struct {
		name   string
		zombie bool
	}{
		{name: "healthy"},
		{name: "one_attributed_zombie", zombie: true},
	} {
		b.Run(tc.name, func(b *testing.B) {
			processes := make([]ProcessInfo, 1000)
			for i := range processes {
				processes[i] = ProcessInfo{PID: i + 1, State: "S", Name: "worker"}
			}
			if tc.zombie {
				processes[len(processes)-1].State = "Z"
				processes[len(processes)-1].PPID = 1
			}
			b.ReportAllocs()
			for b.Loop() {
				summarizeZombies(processes, zombieParentLimit, true)
			}
		})
	}
}

func TestTopProcessesSortsByCPU(t *testing.T) {
	procs := []ProcessInfo{
		{PID: 3, Name: "low", CPU: 20, Memory: 3},
		{PID: 1, Name: "high", CPU: 120, Memory: 1},
		{PID: 2, Name: "mid", CPU: 120, Memory: 8},
	}

	top := topProcesses(procs, 2)
	if len(top) != 2 {
		t.Fatalf("topProcesses() len = %d, want 2", len(top))
	}
	if top[0].PID != 2 || top[1].PID != 1 {
		t.Fatalf("unexpected order: %+v", top)
	}
}

func TestProcessNameFromCommand(t *testing.T) {
	tests := []struct {
		command string
		want    string
	}{
		{"/Applications/Visual Studio Code.app/Contents/MacOS/Electron", "Electron"},
		{"/usr/local/bin/node /tmp/server.js", "server.js"},
		{"Finder", "Finder"},
	}

	for _, tt := range tests {
		t.Run(tt.command, func(t *testing.T) {
			if got := processNameFromCommand(tt.command); got != tt.want {
				t.Fatalf("processNameFromCommand(%q) = %q, want %q", tt.command, got, tt.want)
			}
		})
	}
}

func TestProcessWatcherTriggersAfterContinuousWindow(t *testing.T) {
	base := time.Date(2026, 3, 19, 10, 0, 0, 0, time.UTC)
	watcher := NewProcessWatcher(ProcessWatchOptions{
		Enabled:      true,
		CPUThreshold: 100,
		Window:       5 * time.Minute,
	})

	proc := []ProcessInfo{{PID: 42, Name: "stress", CPU: 140}}
	if alerts := watcher.Update(base, proc); len(alerts) != 0 {
		t.Fatalf("unexpected early alerts: %+v", alerts)
	}
	if alerts := watcher.Update(base.Add(4*time.Minute), proc); len(alerts) != 0 {
		t.Fatalf("unexpected early alerts at 4m: %+v", alerts)
	}
	alerts := watcher.Update(base.Add(5*time.Minute), proc)
	if len(alerts) != 1 {
		t.Fatalf("expected 1 alert after full window, got %+v", alerts)
	}
	if alerts[0].Status != "active" {
		t.Fatalf("unexpected alert status %q", alerts[0].Status)
	}
}

func TestProcessWatcherResetsWhenUsageDrops(t *testing.T) {
	base := time.Date(2026, 3, 19, 10, 0, 0, 0, time.UTC)
	watcher := NewProcessWatcher(ProcessWatchOptions{
		Enabled:      true,
		CPUThreshold: 100,
		Window:       5 * time.Minute,
	})

	high := []ProcessInfo{{PID: 42, Name: "stress", CPU: 140}}
	low := []ProcessInfo{{PID: 42, Name: "stress", CPU: 30}}

	watcher.Update(base, high)
	watcher.Update(base.Add(4*time.Minute), high)
	if alerts := watcher.Update(base.Add(4*time.Minute+30*time.Second), low); len(alerts) != 0 {
		t.Fatalf("expected reset after dip, got %+v", alerts)
	}
	if alerts := watcher.Update(base.Add(9*time.Minute), high); len(alerts) != 0 {
		t.Fatalf("expected no alert after reset, got %+v", alerts)
	}
	if alerts := watcher.Update(base.Add(14*time.Minute), high); len(alerts) != 1 {
		t.Fatalf("expected alert after second full window, got %+v", alerts)
	}
}

func TestProcessWatcherResetsOnPIDReuse(t *testing.T) {
	base := time.Date(2026, 3, 19, 10, 0, 0, 0, time.UTC)
	watcher := NewProcessWatcher(ProcessWatchOptions{
		Enabled:      true,
		CPUThreshold: 100,
		Window:       2 * time.Minute,
	})

	firstProc := []ProcessInfo{{
		PID:     42,
		PPID:    1,
		Name:    "stress",
		Command: "/usr/bin/stress",
		CPU:     140,
	}}
	secondProc := []ProcessInfo{{
		PID:     42,
		PPID:    99,
		Name:    "node",
		Command: "/usr/local/bin/node /tmp/server.js",
		CPU:     135,
	}}

	watcher.Update(base, firstProc)
	if alerts := watcher.Update(base.Add(2*time.Minute), firstProc); len(alerts) != 1 {
		t.Fatalf("expected first process to alert after window, got %+v", alerts)
	}

	if alerts := watcher.Update(base.Add(3*time.Minute), secondProc); len(alerts) != 0 {
		t.Fatalf("expected pid reuse to reset tracking, got %+v", alerts)
	}
	if alerts := watcher.Update(base.Add(5*time.Minute), secondProc); len(alerts) != 1 {
		t.Fatalf("expected reused pid to alert only after its own window, got %+v", alerts)
	}
}

func TestRenderProcessAlertBar(t *testing.T) {
	stale := false
	alerts := []ProcessAlert{
		{PID: 10, Name: "node", CPU: 150, Threshold: 100, Window: "5m0s", Status: "active"},
		{PID: 11, Name: "java", CPU: 130, Threshold: 100, Window: "5m0s", Status: "active"},
	}

	bar := renderProcessAlertBar(alerts, &stale, nil, 120)
	if !strings.Contains(bar, "ALERT") {
		t.Fatalf("missing alert prefix: %q", bar)
	}
	if !strings.Contains(bar, "node (10)") {
		t.Fatalf("missing lead process label: %q", bar)
	}
	if !strings.Contains(bar, "+1 more") {
		t.Fatalf("missing additional alert count: %q", bar)
	}
	if strings.Contains(bar, "terminate") || strings.Contains(bar, "ignore") {
		t.Fatalf("unexpected action text in read-only alert bar: %q", bar)
	}
}

func TestRenderProcessAlertBarMarksStaleSamplesBeforeTruncation(t *testing.T) {
	stale := true
	collectedAt := time.Date(2026, time.August, 30, 9, 7, 0, 0, time.FixedZone("UTC+8", 8*60*60))
	alerts := []ProcessAlert{{
		PID: 10, Name: "node", CPU: 150, Threshold: 100, Window: "5m0s", Status: "active",
	}}

	narrowBar := stripANSI(renderProcessAlertBar(alerts, &stale, &collectedAt, 10))
	if !strings.HasPrefix(strings.TrimSpace(narrowBar), "OLD") {
		t.Fatalf("historical alert marker should survive narrow rendering, got %q", narrowBar)
	}
	if strings.Contains(narrowBar, "2026") {
		t.Fatalf("narrow rendering should not show a partial timestamp, got %q", narrowBar)
	}
	wideBar := stripANSI(renderProcessAlertBar(alerts, &stale, &collectedAt, 120))
	if !strings.HasPrefix(strings.TrimSpace(wideBar), "LAST ALERT · STALE 2026-08-30T09:07:00+08:00") {
		t.Fatalf("stale process alert should include unambiguous age and historical semantics, got %q", wideBar)
	}
	if strings.Contains(wideBar, "· ALERT ") {
		t.Fatalf("stale process alert should not present itself as current, got %q", wideBar)
	}
	unboundedBar := stripANSI(renderProcessAlertBar(alerts, &stale, &collectedAt, 0))
	if !strings.HasPrefix(strings.TrimSpace(unboundedBar), "LAST ALERT · STALE 2026-08-30T09:07:00+08:00") {
		t.Fatalf("unbounded rendering should preserve the full historical marker, got %q", unboundedBar)
	}
	boundaryBar := stripANSI(renderProcessAlertBar(alerts, &stale, &collectedAt, 28))
	if !strings.HasPrefix(strings.TrimSpace(boundaryBar), "LAST ALERT · STALE") || strings.Contains(boundaryBar, "2026") {
		t.Fatalf("partial RFC3339 timestamp should collapse atomically, got %q", boundaryBar)
	}
}

func TestRenderProcessAlertBarMarksUnknownFreshnessAsLastKnown(t *testing.T) {
	alerts := []ProcessAlert{{
		PID: 10, Name: "node", CPU: 150, Threshold: 100, Window: "5m0s", Status: "active",
	}}

	bar := stripANSI(renderProcessAlertBar(alerts, nil, nil, 80))
	if !strings.HasPrefix(strings.TrimSpace(bar), "LAST ALERT · UNKNOWN") {
		t.Fatalf("unknown-freshness process alert should be last-known, got %q", bar)
	}
}

func TestMetricsSnapshotJSONIncludesProcessWatch(t *testing.T) {
	zombieCount := 2
	zombieParentsComplete := true
	processCollectedAt := time.Date(2026, time.August, 29, 12, 30, 0, 0, time.UTC)
	processStale := false
	snapshot := MetricsSnapshot{
		ProcessCollectedAt: &processCollectedAt,
		ProcessStale:       &processStale,
		ZombieCount:        &zombieCount,
		ZombieParents: []ZombieParent{{
			PID:   42,
			Name:  "Chrome",
			Count: 2,
		}},
		ZombieParentsComplete: &zombieParentsComplete,
		ProcessWatch: ProcessWatchConfig{
			Enabled:      true,
			CPUThreshold: 100,
			Window:       "5m0s",
		},
		ProcessAlerts: []ProcessAlert{{
			PID:       99,
			Name:      "node",
			CPU:       140,
			Threshold: 100,
			Window:    "5m0s",
			Status:    "active",
		}},
	}

	data, err := json.Marshal(snapshot)
	if err != nil {
		t.Fatalf("json.Marshal() error = %v", err)
	}
	out := string(data)
	if !strings.Contains(out, "\"process_watch\"") {
		t.Fatalf("missing process_watch in json: %s", out)
	}
	if !strings.Contains(out, "\"process_alerts\"") {
		t.Fatalf("missing process_alerts in json: %s", out)
	}
	if !strings.Contains(out, "\"process_collected_at\":\"2026-08-29T12:30:00Z\"") ||
		!strings.Contains(out, "\"process_stale\":false") {
		t.Fatalf("missing process freshness in json: %s", out)
	}
	if !strings.Contains(out, "\"zombie_count\":2") || !strings.Contains(out, "\"zombie_parents\"") ||
		!strings.Contains(out, "\"zombie_parents_complete\":true") {
		t.Fatalf("missing zombie summary in json: %s", out)
	}
}

func TestMetricsSnapshotJSONDistinguishesUnmeasuredFromZeroZombies(t *testing.T) {
	unmeasured, err := json.Marshal(MetricsSnapshot{})
	if err != nil {
		t.Fatalf("json.Marshal(unmeasured) error = %v", err)
	}
	if strings.Contains(string(unmeasured), "\"zombie_count\"") ||
		strings.Contains(string(unmeasured), "\"zombie_parents_complete\"") ||
		strings.Contains(string(unmeasured), "\"process_collected_at\"") ||
		strings.Contains(string(unmeasured), "\"process_stale\"") {
		t.Fatalf("unmeasured snapshot should omit zombie measurements: %s", unmeasured)
	}

	zero := 0
	complete := true
	processCollectedAt := time.Date(2026, time.August, 29, 12, 30, 0, 0, time.UTC)
	processStale := false
	measured, err := json.Marshal(MetricsSnapshot{
		ProcessCollectedAt:    &processCollectedAt,
		ProcessStale:          &processStale,
		ZombieCount:           &zero,
		ZombieParentsComplete: &complete,
	})
	if err != nil {
		t.Fatalf("json.Marshal(measured) error = %v", err)
	}
	if !strings.Contains(string(measured), "\"zombie_count\":0") ||
		!strings.Contains(string(measured), "\"zombie_parents_complete\":true") ||
		!strings.Contains(string(measured), "\"process_stale\":false") {
		t.Fatalf("measured zero snapshot should include zombie_count: %s", measured)
	}
}
