package main

import (
	"math"
	"strings"
	"testing"
)

func TestCalculateHealthScorePerfect(t *testing.T) {
	score, msg := calculateHealthScore(
		CPUStatus{Usage: 10},
		MemoryStatus{UsedPercent: 20, Pressure: "normal"},
		[]DiskStatus{{UsedPercent: 30}},
		DiskIOStatus{ReadRate: 5, WriteRate: 5},
		ThermalStatus{CPUTemp: 40},
		nil, "",
	)

	if score != 100 {
		t.Fatalf("expected perfect score 100, got %d", score)
	}
	if msg != "Excellent" {
		t.Fatalf("unexpected message %q", msg)
	}
}

func TestCalculateHealthScoreDetectsIssues(t *testing.T) {
	score, msg := calculateHealthScore(
		CPUStatus{Usage: 95},
		MemoryStatus{UsedPercent: 95, Pressure: "critical"},
		[]DiskStatus{{UsedPercent: 98}},
		DiskIOStatus{ReadRate: 120, WriteRate: 80},
		ThermalStatus{CPUTemp: 90},
		nil, "",
	)

	if score >= 60 {
		t.Fatalf("expected heavy penalties bringing score down, got %d", score)
	}
	if msg == "Excellent" {
		t.Fatalf("expected message to include issues, got %q", msg)
	}
	if !strings.Contains(msg, "High CPU") {
		t.Fatalf("message should mention CPU issue: %q", msg)
	}
	if !strings.Contains(msg, "Disk Almost Full") {
		t.Fatalf("message should mention disk issue: %q", msg)
	}
}

func TestCalculateHealthScoreCapsFailingSMARTAt44(t *testing.T) {
	score, msg := calculateHealthScore(
		CPUStatus{Usage: 10},
		MemoryStatus{UsedPercent: 20, Pressure: "normal"},
		[]DiskStatus{
			{UsedPercent: 30, SmartStatus: smartStatusVerified},
			{UsedPercent: 20, SmartStatus: smartStatusFailing},
		},
		DiskIOStatus{ReadRate: 5, WriteRate: 5},
		ThermalStatus{CPUTemp: 40},
		nil, "",
	)

	if score != 44 {
		t.Fatalf("failing SMART score = %d, want 44", score)
	}
	if !strings.Contains(msg, "Disk SMART Failing") {
		t.Fatalf("failing SMART message = %q", msg)
	}
}

func TestCalculateHealthScoreDoesNotPenalizeUnavailableSMART(t *testing.T) {
	for _, status := range []string{smartStatusUnsupported, smartStatusUnknown} {
		score, msg := calculateHealthScore(
			CPUStatus{Usage: 10},
			MemoryStatus{UsedPercent: 20, Pressure: "normal"},
			[]DiskStatus{{UsedPercent: 30, SmartStatus: status}},
			DiskIOStatus{ReadRate: 5, WriteRate: 5},
			ThermalStatus{CPUTemp: 40},
			nil, "",
		)
		if score != 100 || msg != "Excellent" {
			t.Fatalf("SMART %q changed health to %d %q", status, score, msg)
		}
	}
}

func TestCalculateHealthScoreMonotonicInCPU(t *testing.T) {
	// Rising CPU usage must never improve (raise) the health score, including
	// across the high-usage threshold at 85%.
	prev := 101
	for usage := 40.0; usage <= 100.0; usage += 0.5 {
		score, _ := calculateHealthScore(
			CPUStatus{Usage: usage},
			MemoryStatus{UsedPercent: 20, Pressure: "normal"},
			[]DiskStatus{{UsedPercent: 30}},
			DiskIOStatus{ReadRate: 5, WriteRate: 5},
			ThermalStatus{CPUTemp: 40},
			nil, "",
		)
		if score > prev {
			t.Fatalf("health score rose from %d to %d as CPU usage increased to %.1f%%", prev, score, usage)
		}
		prev = score
	}
}

func TestCalculateHealthScoreMonotonicInMemory(t *testing.T) {
	// Rising memory usage must never improve (raise) the health score, including
	// across the high-usage threshold at 88%.
	prev := 101
	for usage := 60.0; usage <= 100.0; usage += 0.5 {
		score, _ := calculateHealthScore(
			CPUStatus{Usage: 10},
			MemoryStatus{UsedPercent: usage, Pressure: "normal"},
			[]DiskStatus{{UsedPercent: 30}},
			DiskIOStatus{ReadRate: 5, WriteRate: 5},
			ThermalStatus{CPUTemp: 40},
			nil, "",
		)
		if score > prev {
			t.Fatalf("health score rose from %d to %d as memory usage increased to %.1f%%", prev, score, usage)
		}
		prev = score
	}
}

func TestFormatUptime(t *testing.T) {
	if got := formatUptime(65); got != "1m" {
		t.Fatalf("expected 1m, got %s", got)
	}
	if got := formatUptime(3600 + 120); got != "1h 2m" {
		t.Fatalf("expected \"1h 2m\", got %s", got)
	}
	if got := formatUptime(86400*2 + 3600*3 + 60*5); got != "2d 3h" {
		t.Fatalf("expected \"2d 3h\", got %s", got)
	}
}

func TestColorizeTempThresholds(t *testing.T) {
	tests := []struct {
		temp     float64
		expected string
	}{
		{temp: 30.0, expected: "30.0"}, // Normal - should use okStyle (green)
		{temp: 64.9, expected: "64.9"}, // Just below warning threshold
		{temp: 65.0, expected: "65.0"}, // Warning threshold - should use warnStyle (yellow)
		{temp: 78.0, expected: "78.0"}, // Mid warning range
		{temp: 84.9, expected: "84.9"}, // Just below danger threshold
		{temp: 85.0, expected: "85.0"}, // Danger threshold - should use dangerStyle (red)
		{temp: 90.0, expected: "90.0"}, // High temperature
		{temp: 0.0, expected: "0.0"},   // Edge case: zero
	}

	for _, tt := range tests {
		result := colorizeTemp(tt.temp)
		// Check that result contains the formatted temperature value
		if !strings.Contains(result, tt.expected) {
			t.Errorf("colorizeTemp(%.1f) = %q, should contain %q", tt.temp, result, tt.expected)
		}
		// Verify output is not empty and contains the temperature
		if result == "" {
			t.Errorf("colorizeTemp(%.1f) returned empty string", tt.temp)
		}
	}
}

func TestColorizeTempStyleRanges(t *testing.T) {
	normalTemp := colorizeTemp(40.0)
	warningTemp := colorizeTemp(72.0)
	dangerTemp := colorizeTemp(90.0)

	if normalTemp == "" || warningTemp == "" || dangerTemp == "" {
		t.Fatal("colorizeTemp should not return empty strings")
	}

	if !strings.Contains(normalTemp, "40.0") {
		t.Errorf("normal temp should contain '40.0', got: %s", normalTemp)
	}
	if !strings.Contains(warningTemp, "72.0") {
		t.Errorf("warning temp should contain '72.0', got: %s", warningTemp)
	}
	if !strings.Contains(dangerTemp, "90.0") {
		t.Errorf("danger temp should contain '90.0', got: %s", dangerTemp)
	}
}

func TestCalculateHealthScoreEdgeCases(t *testing.T) {
	tests := []struct {
		name    string
		cpu     CPUStatus
		mem     MemoryStatus
		disks   []DiskStatus
		diskIO  DiskIOStatus
		thermal ThermalStatus
		wantMin int
		wantMax int
	}{
		{
			name:    "all metrics at normal threshold",
			cpu:     CPUStatus{Usage: 50.0},
			mem:     MemoryStatus{UsedPercent: 70.0},
			disks:   []DiskStatus{{UsedPercent: 80.0}},
			diskIO:  DiskIOStatus{ReadRate: 25.0, WriteRate: 25.0},
			thermal: ThermalStatus{CPUTemp: 65.0},
			wantMin: 95,
			wantMax: 100,
		},
		{
			name:    "memory pressure warning only",
			cpu:     CPUStatus{Usage: 10.0},
			mem:     MemoryStatus{UsedPercent: 40.0, Pressure: "warn"},
			disks:   []DiskStatus{{UsedPercent: 40.0}},
			diskIO:  DiskIOStatus{ReadRate: 5.0, WriteRate: 5.0},
			thermal: ThermalStatus{CPUTemp: 40.0},
			wantMin: 90,
			wantMax: 100,
		},
		{
			name:    "empty disks array",
			cpu:     CPUStatus{Usage: 10.0},
			mem:     MemoryStatus{UsedPercent: 30.0},
			disks:   []DiskStatus{},
			diskIO:  DiskIOStatus{ReadRate: 5.0, WriteRate: 5.0},
			thermal: ThermalStatus{CPUTemp: 40.0},
			wantMin: 95,
			wantMax: 100,
		},
		{
			name:    "zero thermal data",
			cpu:     CPUStatus{Usage: 10.0},
			mem:     MemoryStatus{UsedPercent: 30.0},
			disks:   []DiskStatus{{UsedPercent: 40.0}},
			diskIO:  DiskIOStatus{ReadRate: 5.0, WriteRate: 5.0},
			thermal: ThermalStatus{CPUTemp: 0},
			wantMin: 95,
			wantMax: 100,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			score, _ := calculateHealthScore(tt.cpu, tt.mem, tt.disks, tt.diskIO, tt.thermal, nil, "")
			if score < tt.wantMin || score > tt.wantMax {
				t.Errorf("calculateHealthScore() = %d, want range [%d, %d]", score, tt.wantMin, tt.wantMax)
			}
		})
	}
}

func TestBatteryHealthLabel(t *testing.T) {
	tests := []struct {
		name     string
		cycles   int
		capacity int
		label    string
		severity string
	}{
		{"new battery", 100, 98, "Healthy", "ok"},
		{"moderate cycles", 600, 92, "Healthy", "ok"},
		{"high cycles", 950, 85, "Service Soon", "danger"},
		{"low capacity", 200, 55, "Service Soon", "danger"},
		{"warn capacity", 200, 75, "Fair", "warn"},
		{"zero values", 0, 0, "", "unknown"},
		{"known cycles unknown capacity", 100, 0, "", "unknown"},
		{"unknown capacity high cycles", 950, 0, "Service Soon", "danger"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			label, severity := batteryHealthLabel(tt.cycles, tt.capacity)
			if label != tt.label {
				t.Errorf("batteryHealthLabel(%d, %d) label = %q, want %q", tt.cycles, tt.capacity, label, tt.label)
			}
			if severity != tt.severity {
				t.Errorf("batteryHealthLabel(%d, %d) severity = %q, want %q", tt.cycles, tt.capacity, severity, tt.severity)
			}
		})
	}
}

func TestHealthScoreBatteryAndRestartPenalty(t *testing.T) {
	base := func(batts []BatteryStatus, restart string) int {
		s, _ := calculateHealthScore(
			CPUStatus{Usage: 10}, MemoryStatus{UsedPercent: 20},
			[]DiskStatus{{UsedPercent: 30}}, DiskIOStatus{ReadRate: 5, WriteRate: 5},
			ThermalStatus{CPUTemp: 40}, batts, restart,
		)
		return s
	}

	perfect := base(nil, "")
	if got := base([]BatteryStatus{{CycleCount: 950, Capacity: 75}}, ""); got >= perfect {
		t.Errorf("old battery should reduce score: got %d vs perfect %d", got, perfect)
	}
	if got := base(nil, "running kernel was replaced by an update"); got >= perfect {
		t.Errorf("pending restart should reduce score: got %d vs perfect %d", got, perfect)
	}
}

// The reference VM from the Omarchy test box: 1.9 GB RAM, 72% used, swap
// completely full. The macOS-derived formula scored it 98 "Excellent".
func TestHealthScoreVMWithFullSwapIsClearlyLower(t *testing.T) {
	vm := MemoryStatus{
		Total: 1900 << 20, Used: 1368 << 20, UsedPercent: 72,
		SwapTotal: 1 << 30, SwapUsed: 1 << 30,
		Pressure: "normal",
	}
	healthy := MemoryStatus{Total: 1900 << 20, UsedPercent: 30, SwapTotal: 1 << 30}
	score := func(mem MemoryStatus) (int, string) {
		return calculateHealthScore(
			CPUStatus{Usage: 5}, mem,
			[]DiskStatus{{Mount: "/", UsedPercent: 40}}, DiskIOStatus{}, ThermalStatus{}, nil, "",
		)
	}

	got, msg := score(vm)
	base, _ := score(healthy)
	if base < 98 {
		t.Fatalf("idle machine scored %d, want >= 98", base)
	}
	if got > 80 || got < 60 {
		t.Fatalf("72%% memory with full swap scored %d (%q), want 60..80", got, msg)
	}
	if base-got < 18 {
		t.Fatalf("score drop = %d, want at least 18 against a healthy machine", base-got)
	}
	if !strings.Contains(msg, "Swap Full") {
		t.Fatalf("message %q should name the full swap", msg)
	}
	if strings.HasPrefix(msg, "Excellent") {
		t.Fatalf("message %q must not read Excellent", msg)
	}
}

func TestSwapPenalty(t *testing.T) {
	tests := []struct {
		name string
		mem  MemoryStatus
		want float64
	}{
		{"no swap configured", MemoryStatus{UsedPercent: 90}, 0},
		{"swap barely used", MemoryStatus{UsedPercent: 90, SwapTotal: 100, SwapUsed: 10}, 0},
		{"swap full, memory idle", MemoryStatus{UsedPercent: 20, SwapTotal: 100, SwapUsed: 100}, 0},
		{"swap full, memory tight", MemoryStatus{UsedPercent: 70, SwapTotal: 100, SwapUsed: 100}, healthSwapWeight},
		{"swap 60%, memory tight", MemoryStatus{UsedPercent: 60, SwapTotal: 100, SwapUsed: 60}, healthSwapWeight * 0.5},
		{"swap full, memory half tight", MemoryStatus{UsedPercent: 45, SwapTotal: 100, SwapUsed: 100}, healthSwapWeight * 0.5},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := swapPenalty(tt.mem); math.Abs(got-tt.want) > 1e-9 {
				t.Fatalf("swapPenalty() = %v, want %v", got, tt.want)
			}
		})
	}
}

func TestHealthScoreMonotonicInSwapAndPressure(t *testing.T) {
	score := func(mem MemoryStatus) int {
		s, _ := calculateHealthScore(CPUStatus{}, mem, nil, DiskIOStatus{}, ThermalStatus{}, nil, "")
		return s
	}
	prev := 101
	for used := uint64(0); used <= 100; used += 5 {
		s := score(MemoryStatus{UsedPercent: 70, SwapTotal: 100, SwapUsed: used})
		if s > prev {
			t.Fatalf("score rose from %d to %d as swap use reached %d%%", prev, s, used)
		}
		prev = s
	}
	normal := score(MemoryStatus{UsedPercent: 50, Pressure: "normal"})
	warn := score(MemoryStatus{UsedPercent: 50, Pressure: "warn"})
	crit := score(MemoryStatus{UsedPercent: 50, Pressure: "critical"})
	if !(normal > warn && warn > crit) {
		t.Fatalf("pressure scores normal=%d warn=%d critical=%d, want strictly decreasing", normal, warn, crit)
	}
}

func TestHealthScoreDoesNotPenalizeUptimeAlone(t *testing.T) {
	// Uptime is no longer an input; only a concrete restart reason counts.
	s, msg := calculateHealthScore(CPUStatus{}, MemoryStatus{}, nil, DiskIOStatus{}, ThermalStatus{}, nil, "")
	if s != 100 || strings.Contains(msg, "Restart") {
		t.Fatalf("score/message = %d %q, want 100 without a restart hint", s, msg)
	}
	_, msg = calculateHealthScore(CPUStatus{}, MemoryStatus{}, nil, DiskIOStatus{}, ThermalStatus{}, nil, "reboot required by pending updates")
	if !strings.Contains(msg, "Restart Recommended") {
		t.Fatalf("message %q should recommend a restart", msg)
	}
}

func TestFormatUptimeEdgeCases(t *testing.T) {
	tests := []struct {
		name string
		secs uint64
		want string
	}{
		{"zero seconds", 0, "0m"},
		{"59 seconds", 59, "0m"},
		{"one minute exact", 60, "1m"},
		{"59 minutes 59 seconds", 3599, "59m"},
		{"one hour exact", 3600, "1h 0m"},
		{"one day exact", 86400, "1d 0h"},
		{"one day one hour", 90000, "1d 1h"},
		{"multiple days no hours", 172800, "2d 0h"},
		{"large uptime", 31536000, "365d 0h"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatUptime(tt.secs)
			if got != tt.want {
				t.Errorf("formatUptime(%d) = %q, want %q", tt.secs, got, tt.want)
			}
		})
	}
}

func TestDiskCriticalNeedsNinetyPercentAndUnderThirtyGBFree(t *testing.T) {
	const gb = 1_000_000_000
	for _, tc := range []struct {
		name       string
		usedPct    float64
		total, use uint64
		want       bool
	}{
		{"2 TB at 90% keeps 200 GB free", 90, 2000 * gb, 1800 * gb, false},
		{"4 TB at 95% keeps 200 GB free", 95, 4000 * gb, 3800 * gb, false},
		{"256 GB at 93.5% has 18 GB free", 93.5, 256 * gb, 238 * gb, true},
		{"exactly 90% under the floor", 90, 250 * gb, 225 * gb, true},
		{"under 90% even with little free", 89.9, 100 * gb, 89 * gb, false},
		{"exactly 30 GB free is not under the floor", 97, 1000 * gb, 970 * gb, false},
	} {
		t.Run(tc.name, func(t *testing.T) {
			disk := DiskStatus{Mount: "/", UsedPercent: tc.usedPct, Total: tc.total, Used: tc.use}
			_, msg := calculateHealthScore(CPUStatus{}, MemoryStatus{}, []DiskStatus{disk}, DiskIOStatus{}, ThermalStatus{}, nil, "")
			if strings.Contains(msg, "Disk Almost Full") != tc.want {
				t.Fatalf("health message %q, want critical=%v", msg, tc.want)
			}
			line := statusDiagnosisLine(MetricsSnapshot{Disks: []DiskStatus{disk}})
			if strings.HasPrefix(line, "Disk low") != tc.want {
				t.Fatalf("diagnosis %q, want critical=%v", line, tc.want)
			}
		})
	}
}
