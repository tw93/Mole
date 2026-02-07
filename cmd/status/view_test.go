package main

import (
	"strings"
	"testing"
)

func TestFormatRate(t *testing.T) {
	tests := []struct {
		name  string
		input float64
		want  string
	}{
		// Below threshold (< 0.01).
		{"zero", 0, "0 MB/s"},
		{"tiny", 0.001, "0 MB/s"},
		{"just under threshold", 0.009, "0 MB/s"},

		// Small rates (0.01 to < 1) — 2 decimal places.
		{"at threshold", 0.01, "0.01 MB/s"},
		{"small rate", 0.5, "0.50 MB/s"},
		{"just under 1", 0.99, "0.99 MB/s"},

		// Medium rates (1 to < 10) — 1 decimal place.
		{"exactly 1", 1.0, "1.0 MB/s"},
		{"medium rate", 5.5, "5.5 MB/s"},
		{"just under 10", 9.9, "9.9 MB/s"},

		// Large rates (>= 10) — no decimal places.
		{"exactly 10", 10.0, "10 MB/s"},
		{"large rate", 100.5, "100 MB/s"},
		{"very large", 1000.0, "1000 MB/s"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatRate(tt.input)
			if got != tt.want {
				t.Errorf("formatRate(%v) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestColorizePercent(t *testing.T) {
	tests := []struct {
		name         string
		percent      float64
		input        string
		expectDanger bool
		expectWarn   bool
		expectOk     bool
	}{
		{"low usage", 30.0, "30%", false, false, true},
		{"just below warn", 59.9, "59.9%", false, false, true},
		{"at warn threshold", 60.0, "60%", false, true, false},
		{"mid range", 70.0, "70%", false, true, false},
		{"just below danger", 84.9, "84.9%", false, true, false},
		{"at danger threshold", 85.0, "85%", true, false, false},
		{"high usage", 95.0, "95%", true, false, false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := colorizePercent(tt.percent, tt.input)

			if got == "" {
				t.Errorf("colorizePercent(%v, %q) returned empty string", tt.percent, tt.input)
				return
			}

			expected := ""
			if tt.expectDanger {
				expected = dangerStyle.Render(tt.input)
			} else if tt.expectWarn {
				expected = warnStyle.Render(tt.input)
			} else if tt.expectOk {
				expected = okStyle.Render(tt.input)
			}

			if got != expected {
				t.Errorf("colorizePercent(%v, %q) = %q, want %q (danger=%v warn=%v ok=%v)",
					tt.percent, tt.input, got, expected, tt.expectDanger, tt.expectWarn, tt.expectOk)
			}
		})
	}
}

func TestColorizeBattery(t *testing.T) {
	tests := []struct {
		name         string
		percent      float64
		input        string
		expectDanger bool
		expectWarn   bool
		expectOk     bool
	}{
		{"critical low", 10.0, "10%", true, false, false},
		{"just below low", 19.9, "19.9%", true, false, false},
		{"at low threshold", 20.0, "20%", false, true, false},
		{"mid range", 35.0, "35%", false, true, false},
		{"just below ok", 49.9, "49.9%", false, true, false},
		{"at ok threshold", 50.0, "50%", false, false, true},
		{"healthy", 80.0, "80%", false, false, true},
		{"full", 100.0, "100%", false, false, true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := colorizeBattery(tt.percent, tt.input)

			if got == "" {
				t.Errorf("colorizeBattery(%v, %q) returned empty string", tt.percent, tt.input)
				return
			}

			expected := ""
			if tt.expectDanger {
				expected = dangerStyle.Render(tt.input)
			} else if tt.expectWarn {
				expected = warnStyle.Render(tt.input)
			} else if tt.expectOk {
				expected = okStyle.Render(tt.input)
			}

			if got != expected {
				t.Errorf("colorizeBattery(%v, %q) = %q, want %q (danger=%v warn=%v ok=%v)",
					tt.percent, tt.input, got, expected, tt.expectDanger, tt.expectWarn, tt.expectOk)
			}
		})
	}
}

func TestShorten(t *testing.T) {
	tests := []struct {
		name   string
		input  string
		maxLen int
		want   string
	}{
		// No truncation needed.
		{"empty string", "", 10, ""},
		{"shorter than max", "hello", 10, "hello"},
		{"exactly at max", "hello", 5, "hello"},

		// Truncation needed.
		{"one over max", "hello!", 5, "hell…"},
		{"much longer", "hello world", 5, "hell…"},

		// Edge cases.
		{"maxLen 1", "hello", 1, "…"},
		{"maxLen 2", "hello", 2, "h…"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := shorten(tt.input, tt.maxLen)
			if got != tt.want {
				t.Errorf("shorten(%q, %d) = %q, want %q", tt.input, tt.maxLen, got, tt.want)
			}
		})
	}
}

func TestHumanBytesShort(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		// Zero and small values.
		{"zero", 0, "0"},
		{"one byte", 1, "1"},
		{"999 bytes", 999, "999"},

		// Kilobyte boundaries.
		{"exactly 1KB", 1 << 10, "1K"},
		{"just under 1KB", (1 << 10) - 1, "1023"},
		{"1.5KB rounds to 2K", 1536, "2K"},
		{"999KB", 999 << 10, "999K"},

		// Megabyte boundaries.
		{"exactly 1MB", 1 << 20, "1M"},
		{"just under 1MB", (1 << 20) - 1, "1024K"},
		{"500MB", 500 << 20, "500M"},

		// Gigabyte boundaries.
		{"exactly 1GB", 1 << 30, "1G"},
		{"just under 1GB", (1 << 30) - 1, "1024M"},
		{"100GB", 100 << 30, "100G"},

		// Terabyte boundaries.
		{"exactly 1TB", 1 << 40, "1T"},
		{"just under 1TB", (1 << 40) - 1, "1024G"},
		{"2TB", 2 << 40, "2T"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := humanBytesShort(tt.input)
			if got != tt.want {
				t.Errorf("humanBytesShort(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestHumanBytes(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		// Zero and small values.
		{"zero", 0, "0 B"},
		{"one byte", 1, "1 B"},
		{"1023 bytes", 1023, "1023 B"},

		// Kilobyte boundaries (uses > not >=).
		{"exactly 1KB", 1 << 10, "1024 B"},
		{"just over 1KB", (1 << 10) + 1, "1.0 KB"},
		{"1.5KB", 1536, "1.5 KB"},

		// Megabyte boundaries (uses > not >=).
		{"exactly 1MB", 1 << 20, "1024.0 KB"},
		{"just over 1MB", (1 << 20) + 1, "1.0 MB"},
		{"500MB", 500 << 20, "500.0 MB"},

		// Gigabyte boundaries (uses > not >=).
		{"exactly 1GB", 1 << 30, "1024.0 MB"},
		{"just over 1GB", (1 << 30) + 1, "1.0 GB"},
		{"100GB", 100 << 30, "100.0 GB"},

		// Terabyte boundaries (uses > not >=).
		{"exactly 1TB", 1 << 40, "1024.0 GB"},
		{"just over 1TB", (1 << 40) + 1, "1.0 TB"},
		{"2TB", 2 << 40, "2.0 TB"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := humanBytes(tt.input)
			if got != tt.want {
				t.Errorf("humanBytes(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestHumanBytesCompact(t *testing.T) {
	tests := []struct {
		name  string
		input uint64
		want  string
	}{
		// Zero and small values.
		{"zero", 0, "0"},
		{"one byte", 1, "1"},
		{"1023 bytes", 1023, "1023"},

		// Kilobyte boundaries (uses >= not >).
		{"exactly 1KB", 1 << 10, "1.0K"},
		{"1.5KB", 1536, "1.5K"},

		// Megabyte boundaries.
		{"exactly 1MB", 1 << 20, "1.0M"},
		{"500MB", 500 << 20, "500.0M"},

		// Gigabyte boundaries.
		{"exactly 1GB", 1 << 30, "1.0G"},
		{"100GB", 100 << 30, "100.0G"},

		// Terabyte boundaries.
		{"exactly 1TB", 1 << 40, "1.0T"},
		{"2TB", 2 << 40, "2.0T"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := humanBytesCompact(tt.input)
			if got != tt.want {
				t.Errorf("humanBytesCompact(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestSplitDisks(t *testing.T) {
	tests := []struct {
		name         string
		disks        []DiskStatus
		wantInternal int
		wantExternal int
	}{
		{
			name:         "empty slice",
			disks:        []DiskStatus{},
			wantInternal: 0,
			wantExternal: 0,
		},
		{
			name: "all internal",
			disks: []DiskStatus{
				{Mount: "/", External: false},
				{Mount: "/System", External: false},
			},
			wantInternal: 2,
			wantExternal: 0,
		},
		{
			name: "all external",
			disks: []DiskStatus{
				{Mount: "/Volumes/USB", External: true},
				{Mount: "/Volumes/Backup", External: true},
			},
			wantInternal: 0,
			wantExternal: 2,
		},
		{
			name: "mixed",
			disks: []DiskStatus{
				{Mount: "/", External: false},
				{Mount: "/Volumes/USB", External: true},
				{Mount: "/System", External: false},
			},
			wantInternal: 2,
			wantExternal: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			internal, external := splitDisks(tt.disks)
			if len(internal) != tt.wantInternal {
				t.Errorf("splitDisks() internal count = %d, want %d", len(internal), tt.wantInternal)
			}
			if len(external) != tt.wantExternal {
				t.Errorf("splitDisks() external count = %d, want %d", len(external), tt.wantExternal)
			}
		})
	}
}

func TestDiskLabel(t *testing.T) {
	tests := []struct {
		name   string
		prefix string
		index  int
		total  int
		want   string
	}{
		// Single disk — no numbering.
		{"single disk", "INTR", 0, 1, "INTR"},
		{"single external", "EXTR", 0, 1, "EXTR"},

		// Multiple disks — numbered (1-indexed).
		{"first of two", "INTR", 0, 2, "INTR1"},
		{"second of two", "INTR", 1, 2, "INTR2"},
		{"third of three", "EXTR", 2, 3, "EXTR3"},

		// Edge case: total 0 treated as single.
		{"total zero", "DISK", 0, 0, "DISK"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := diskLabel(tt.prefix, tt.index, tt.total)
			if got != tt.want {
				t.Errorf("diskLabel(%q, %d, %d) = %q, want %q", tt.prefix, tt.index, tt.total, got, tt.want)
			}
		})
	}
}

func TestParseInt(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  int
	}{
		// Basic integers.
		{"simple number", "123", 123},
		{"zero", "0", 0},
		{"single digit", "5", 5},

		// With whitespace.
		{"leading space", "  42", 42},
		{"trailing space", "42  ", 42},
		{"both spaces", "  42  ", 42},

		// With non-numeric padding.
		{"leading @", "@60", 60},
		{"trailing Hz", "120Hz", 120},
		{"both padding", "@60Hz", 60},

		// Decimals (truncated to int).
		{"decimal", "60.00", 60},
		{"decimal with suffix", "119.88hz", 119},

		// Edge cases.
		{"empty string", "", 0},
		{"only spaces", "   ", 0},
		{"no digits", "abc", 0},
		{"negative strips sign", "-5", 5}, // Strips non-numeric prefix.
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseInt(tt.input)
			if got != tt.want {
				t.Errorf("parseInt(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestParseRefreshRate(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  string
	}{
		// Standard formats.
		{"60Hz format", "Resolution: 1920x1080 @ 60Hz", "60Hz"},
		{"120Hz format", "Resolution: 2560x1600 @ 120Hz", "120Hz"},
		{"separated Hz", "Refresh Rate: 60 Hz", "60Hz"},

		// Decimal refresh rates.
		{"decimal Hz", "Resolution: 3840x2160 @ 59.94Hz", "59Hz"},
		{"ProMotion", "Resolution: 3456x2234 @ 120.00Hz", "120Hz"},

		// Multiple lines — picks highest valid.
		{"multiple rates", "Display 1: 60Hz\nDisplay 2: 120Hz", "120Hz"},

		// Edge cases.
		{"empty string", "", ""},
		{"no Hz found", "Resolution: 1920x1080", ""},
		{"invalid Hz value", "Rate: abcHz", ""},
		{"Hz too high filtered", "Rate: 600Hz", ""},

		// Case insensitivity.
		{"lowercase hz", "60hz", "60Hz"},
		{"uppercase HZ", "60HZ", "60Hz"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseRefreshRate(tt.input)
			if got != tt.want {
				t.Errorf("parseRefreshRate(%q) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestIsNoiseInterface(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  bool
	}{
		// Noise interfaces (should return true).
		{"loopback", "lo0", true},
		{"awdl", "awdl0", true},
		{"utun", "utun0", true},
		{"llw", "llw0", true},
		{"bridge", "bridge0", true},
		{"gif", "gif0", true},
		{"stf", "stf0", true},
		{"xhc", "xhc0", true},
		{"anpi", "anpi0", true},
		{"ap", "ap1", true},

		// Real interfaces (should return false).
		{"ethernet", "en0", false},
		{"wifi", "en1", false},
		{"thunderbolt", "en5", false},

		// Case insensitivity.
		{"uppercase LO", "LO0", true},
		{"mixed case Awdl", "Awdl0", true},

		// Edge cases.
		{"empty string", "", false},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := isNoiseInterface(tt.input)
			if got != tt.want {
				t.Errorf("isNoiseInterface(%q) = %v, want %v", tt.input, got, tt.want)
			}
		})
	}
}

func TestParsePMSet(t *testing.T) {
	tests := []struct {
		name     string
		raw      string
		health   string
		cycles   int
		capacity int
		wantLen  int
		wantPct  float64
		wantStat string
		wantTime string
	}{
		{
			name: "charging with time",
			raw: `Now drawing from 'AC Power'
 -InternalBattery-0 (id=1234)	85%; charging; 0:45 remaining present: true`,
			health:   "Good",
			cycles:   150,
			capacity: 92,
			wantLen:  1,
			wantPct:  85,
			wantStat: "charging",
			wantTime: "0:45",
		},
		{
			name: "discharging",
			raw: `Now drawing from 'Battery Power'
 -InternalBattery-0 (id=1234)	45%; discharging; 2:30 remaining present: true`,
			health:   "Normal",
			cycles:   200,
			capacity: 88,
			wantLen:  1,
			wantPct:  45,
			wantStat: "discharging",
			wantTime: "2:30",
		},
		{
			name: "fully charged",
			raw: `Now drawing from 'AC Power'
 -InternalBattery-0 (id=1234)	100%; charged; present: true`,
			health:   "Good",
			cycles:   50,
			capacity: 100,
			wantLen:  1,
			wantPct:  100,
			wantStat: "charged",
			wantTime: "",
		},
		{
			name:     "empty output",
			raw:      "",
			health:   "",
			cycles:   0,
			capacity: 0,
			wantLen:  0,
		},
		{
			name:     "no battery line",
			raw:      "Now drawing from 'AC Power'\nNo batteries found.",
			health:   "",
			cycles:   0,
			capacity: 0,
			wantLen:  0,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parsePMSet(tt.raw, tt.health, tt.cycles, tt.capacity)
			if len(got) != tt.wantLen {
				t.Errorf("parsePMSet() returned %d batteries, want %d", len(got), tt.wantLen)
				return
			}
			if tt.wantLen == 0 {
				return
			}
			b := got[0]
			if b.Percent != tt.wantPct {
				t.Errorf("Percent = %v, want %v", b.Percent, tt.wantPct)
			}
			if b.Status != tt.wantStat {
				t.Errorf("Status = %q, want %q", b.Status, tt.wantStat)
			}
			if b.TimeLeft != tt.wantTime {
				t.Errorf("TimeLeft = %q, want %q", b.TimeLeft, tt.wantTime)
			}
			if b.Health != tt.health {
				t.Errorf("Health = %q, want %q", b.Health, tt.health)
			}
			if b.CycleCount != tt.cycles {
				t.Errorf("CycleCount = %d, want %d", b.CycleCount, tt.cycles)
			}
			if b.Capacity != tt.capacity {
				t.Errorf("Capacity = %d, want %d", b.Capacity, tt.capacity)
			}
		})
	}
}

func TestProgressBar(t *testing.T) {
	tests := []struct {
		name     string
		percent  float64
		wantRune int
	}{
		{"zero percent", 0, 16},
		{"negative clamped", -10, 16},
		{"low percent", 25, 16},
		{"half", 50, 16},
		{"high percent", 75, 16},
		{"full", 100, 16},
		{"over 100 clamped", 150, 16},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := progressBar(tt.percent)
			if len(got) == 0 {
				t.Errorf("progressBar(%v) returned empty string", tt.percent)
				return
			}
			gotClean := stripANSI(got)
			gotRuneCount := len([]rune(gotClean))
			if gotRuneCount != tt.wantRune {
				t.Errorf("progressBar(%v) rune count = %d, want %d", tt.percent, gotRuneCount, tt.wantRune)
			}
		})
	}
}

func TestBatteryProgressBar(t *testing.T) {
	tests := []struct {
		name     string
		percent  float64
		wantRune int
	}{
		{"zero percent", 0, 16},
		{"negative clamped", -10, 16},
		{"critical low", 15, 16},
		{"low", 25, 16},
		{"medium", 50, 16},
		{"high", 75, 16},
		{"full", 100, 16},
		{"over 100 clamped", 120, 16},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := batteryProgressBar(tt.percent)
			if len(got) == 0 {
				t.Errorf("batteryProgressBar(%v) returned empty string", tt.percent)
				return
			}
			gotClean := stripANSI(got)
			gotRuneCount := len([]rune(gotClean))
			if gotRuneCount != tt.wantRune {
				t.Errorf("batteryProgressBar(%v) rune count = %d, want %d", tt.percent, gotRuneCount, tt.wantRune)
			}
		})
	}
}

func TestColorizeTemp(t *testing.T) {
	tests := []struct {
		name string
		temp float64
	}{
		{"very low", 20.0},
		{"low", 40.0},
		{"normal threshold", 55.9},
		{"at warn threshold", 56.0},
		{"warn range", 65.0},
		{"just below danger", 75.9},
		{"at danger threshold", 76.0},
		{"high", 85.0},
		{"very high", 95.0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := colorizeTemp(tt.temp)
			if got == "" {
				t.Errorf("colorizeTemp(%v) returned empty string", tt.temp)
			}
		})
	}
}

func TestIoBar(t *testing.T) {
	tests := []struct {
		name string
		rate float64
	}{
		{"zero", 0},
		{"very low", 5},
		{"low normal", 20},
		{"at warn threshold", 30},
		{"warn range", 50},
		{"just below danger", 79},
		{"at danger threshold", 80},
		{"high", 100},
		{"very high", 200},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := ioBar(tt.rate)
			if got == "" {
				t.Errorf("ioBar(%v) returned empty string", tt.rate)
				return
			}
			gotClean := stripANSI(got)
			gotRuneCount := len([]rune(gotClean))
			if gotRuneCount != 5 {
				t.Errorf("ioBar(%v) rune count = %d, want 5", tt.rate, gotRuneCount)
			}
		})
	}
}

func TestMiniBar(t *testing.T) {
	tests := []struct {
		name    string
		percent float64
	}{
		{"zero", 0},
		{"negative", -5},
		{"low", 15},
		{"at first step", 20},
		{"mid", 50},
		{"high", 75},
		{"full", 100},
		{"over 100", 120},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := miniBar(tt.percent)
			if got == "" {
				t.Errorf("miniBar(%v) returned empty string", tt.percent)
				return
			}
			gotClean := stripANSI(got)
			gotRuneCount := len([]rune(gotClean))
			if gotRuneCount != 5 {
				t.Errorf("miniBar(%v) rune count = %d, want 5", tt.percent, gotRuneCount)
			}
		})
	}
}

func TestFormatDiskLine(t *testing.T) {
	tests := []struct {
		name  string
		label string
		disk  DiskStatus
	}{
		{
			name:  "empty label defaults to DISK",
			label: "",
			disk:  DiskStatus{UsedPercent: 50.5, Used: 100 << 30, Total: 200 << 30},
		},
		{
			name:  "internal disk",
			label: "INTR",
			disk:  DiskStatus{UsedPercent: 67.2, Used: 336 << 30, Total: 500 << 30},
		},
		{
			name:  "external disk",
			label: "EXTR1",
			disk:  DiskStatus{UsedPercent: 85.0, Used: 850 << 30, Total: 1000 << 30},
		},
		{
			name:  "low usage",
			label: "INTR",
			disk:  DiskStatus{UsedPercent: 15.3, Used: 15 << 30, Total: 100 << 30},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatDiskLine(tt.label, tt.disk)
			if got == "" {
				t.Errorf("formatDiskLine(%q, ...) returned empty string", tt.label)
				return
			}
			expectedLabel := tt.label
			if expectedLabel == "" {
				expectedLabel = "DISK"
			}
			if !contains(got, expectedLabel) {
				t.Errorf("formatDiskLine(%q, ...) = %q, should contain label %q", tt.label, got, expectedLabel)
			}
		})
	}
}

func TestGetScoreStyle(t *testing.T) {
	tests := []struct {
		name  string
		score int
	}{
		{"critical low", 10},
		{"poor low", 25},
		{"just below fair", 39},
		{"at fair threshold", 40},
		{"fair range", 50},
		{"just below good", 59},
		{"at good threshold", 60},
		{"good range", 70},
		{"just below excellent", 74},
		{"at excellent threshold", 75},
		{"excellent range", 85},
		{"just below perfect", 89},
		{"perfect", 90},
		{"max", 100},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			style := getScoreStyle(tt.score)
			if style.GetForeground() == nil {
				t.Errorf("getScoreStyle(%d) returned style with no foreground color", tt.score)
			}
		})
	}
}

func TestSparkline(t *testing.T) {
	tests := []struct {
		name    string
		history []float64
		current float64
		width   int
		wantLen int
	}{
		{
			name:    "empty history",
			history: []float64{},
			current: 1.5,
			width:   10,
			wantLen: 10,
		},
		{
			name:    "short history padded",
			history: []float64{1.0, 2.0, 3.0},
			current: 3.0,
			width:   10,
			wantLen: 10,
		},
		{
			name:    "exact width",
			history: []float64{1.0, 2.0, 3.0, 4.0, 5.0},
			current: 5.0,
			width:   5,
			wantLen: 5,
		},
		{
			name:    "history longer than width",
			history: []float64{1.0, 2.0, 3.0, 4.0, 5.0, 6.0, 7.0, 8.0, 9.0, 10.0},
			current: 10.0,
			width:   5,
			wantLen: 5,
		},
		{
			name:    "low current value ok style",
			history: []float64{1.0, 1.5, 2.0},
			current: 2.0,
			width:   5,
			wantLen: 5,
		},
		{
			name:    "medium current value warn style",
			history: []float64{3.0, 4.0, 5.0},
			current: 5.0,
			width:   5,
			wantLen: 5,
		},
		{
			name:    "high current value danger style",
			history: []float64{8.0, 9.0, 10.0},
			current: 10.0,
			width:   5,
			wantLen: 5,
		},
		{
			name:    "all identical values flatline",
			history: []float64{5.0, 5.0, 5.0, 5.0, 5.0},
			current: 5.0,
			width:   5,
			wantLen: 5,
		},
		{
			name:    "zero width edge case",
			history: []float64{1.0, 2.0, 3.0},
			current: 2.0,
			width:   0,
			wantLen: 0,
		},
		{
			name:    "width of 1",
			history: []float64{1.0, 2.0, 3.0},
			current: 2.0,
			width:   1,
			wantLen: 1,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := sparkline(tt.history, tt.current, tt.width)
			if tt.width == 0 {
				return
			}
			if got == "" {
				t.Errorf("sparkline() returned empty string")
				return
			}
			gotClean := stripANSI(got)
			if len([]rune(gotClean)) != tt.wantLen {
				t.Errorf("sparkline() rune length = %d, want %d", len([]rune(gotClean)), tt.wantLen)
			}
		})
	}
}

func stripANSI(s string) string {
	var result strings.Builder
	i := 0
	for i < len(s) {
		if i < len(s)-1 && s[i] == '\x1b' && s[i+1] == '[' {
			i += 2
			for i < len(s) && (s[i] < 'A' || s[i] > 'Z') && (s[i] < 'a' || s[i] > 'z') {
				i++
			}
			if i < len(s) {
				i++
			}
		} else {
			result.WriteByte(s[i])
			i++
		}
	}
	return result.String()
}

func contains(s, substr string) bool {
	return len(s) >= len(substr) && (s == substr || len(s) > len(substr) && (s[:len(substr)] == substr || s[len(s)-len(substr):] == substr || containsMiddle(s, substr)))
}

func containsMiddle(s, substr string) bool {
	for i := 0; i <= len(s)-len(substr); i++ {
		if s[i:i+len(substr)] == substr {
			return true
		}
	}
	return false
}
