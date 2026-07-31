package main

import (
	"strings"
	"testing"

	"github.com/charmbracelet/lipgloss"
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

		// Small rates (0.01 to < 1): 2 decimal places.
		{"at threshold", 0.01, "0.01 MB/s"},
		{"small rate", 0.5, "0.50 MB/s"},
		{"just under 1", 0.99, "0.99 MB/s"},

		// Medium rates (1 to < 10): 1 decimal place.
		{"exactly 1", 1.0, "1.0 MB/s"},
		{"medium rate", 5.5, "5.5 MB/s"},
		{"just under 10", 9.9, "9.9 MB/s"},

		// Large rates (>= 10): no decimal places.
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

// Core byte-format coverage lives in internal/units; these are wiring sanity
// checks to ensure the cmd/status helpers still delegate to that package.
func TestHumanBytesShort(t *testing.T) {
	if got := humanBytesShort(100 << 30); got != "100G" {
		t.Errorf("humanBytesShort(100<<30) = %q, want %q", got, "100G")
	}
}

func TestHumanBytes(t *testing.T) {
	if got := humanBytes((1 << 20) + 1); got != "1.0 MB" {
		t.Errorf("humanBytes(1MB+1) = %q, want %q", got, "1.0 MB")
	}
}

func TestHumanBytesCompact(t *testing.T) {
	if got := humanBytesCompact(1536); got != "1.5K" {
		t.Errorf("humanBytesCompact(1536) = %q, want %q", got, "1.5K")
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
		// Single disk: no numbering.
		{"single disk", "INTR", 0, 1, "INTR"},
		{"single external", "EXTR", 0, 1, "EXTR"},

		// Multiple disks: numbered (1-indexed).
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

		// Multiple lines: picks highest valid.
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

func TestRenderBatteryCardShowsAdapterInputOnly(t *testing.T) {
	card := renderBatteryCard([]BatteryStatus{{
		Percent:    80,
		Status:     "AC",
		Capacity:   100,
		CycleCount: 4,
	}}, ThermalStatus{
		BatteryTemp:  30.7,
		AdapterPower: 94,
	})

	var joined []string
	for _, line := range card.lines {
		joined = append(joined, stripANSI(line))
	}
	got := strings.Join(joined, "\n")

	if len(card.lines) != 4 {
		t.Fatalf("expected compact 4-line power card, got %d lines:\n%s", len(card.lines), got)
	}
	if !strings.Contains(got, "Input") || !strings.Contains(got, "94W max") {
		t.Fatalf("expected input line with adapter max watts, got:\n%s", got)
	}
	if strings.Contains(got, "Draw") || strings.Contains(got, "Charge") {
		t.Fatalf("expected no live draw or charge watt row, got:\n%s", got)
	}
	if strings.Contains(got, "94W adapter") {
		t.Fatalf("expected adapter watts only on the Input line, got:\n%s", got)
	}
	if !strings.Contains(got, "AC · Healthy · 4 cycles · 30.7°C") {
		t.Fatalf("expected compact AC health summary, got:\n%s", got)
	}
	if strings.Contains(got, "Battery 30.7°C") {
		t.Fatalf("expected compact temperature without Battery prefix, got:\n%s", got)
	}
	if strings.Contains(got, "Ac") {
		t.Fatalf("expected AC to stay uppercase, got:\n%s", got)
	}
	if strings.Contains(got, "⚡") {
		t.Fatalf("expected no charging glyph, got:\n%s", got)
	}
}

func TestColorizeTemp(t *testing.T) {
	tests := []struct {
		name string
		temp float64
	}{
		{"very low", 20.0},
		{"low", 40.0},
		{"normal range", 55.0},
		{"at warn threshold", 65.0},
		{"warn range", 75.0},
		{"just below danger", 84.9},
		{"at danger threshold", 85.0},
		{"high", 92.0},
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

func TestFormatDiskLine(t *testing.T) {
	tests := []struct {
		name         string
		label        string
		disk         DiskStatus
		wantUsed     string
		wantFree     string
		wantNoSubstr string
	}{
		{
			name:         "empty label defaults to DISK",
			label:        "",
			disk:         DiskStatus{UsedPercent: 50.5, Used: 100 << 30, Total: 200 << 30},
			wantUsed:     "100G used",
			wantFree:     "100G free",
			wantNoSubstr: "%",
		},
		{
			name:         "internal disk",
			label:        "INTR",
			disk:         DiskStatus{UsedPercent: 67.2, Used: 336 << 30, Total: 500 << 30},
			wantUsed:     "336G used",
			wantFree:     "164G free",
			wantNoSubstr: "%",
		},
		{
			name:         "external disk",
			label:        "EXTR1",
			disk:         DiskStatus{UsedPercent: 85.0, Used: 850 << 30, Total: 1000 << 30},
			wantUsed:     "850G used",
			wantFree:     "150G free",
			wantNoSubstr: "%",
		},
		{
			name:         "low usage",
			label:        "INTR",
			disk:         DiskStatus{UsedPercent: 15.3, Used: 15 << 30, Total: 100 << 30},
			wantUsed:     "15G used",
			wantFree:     "85G free",
			wantNoSubstr: "%",
		},
		{
			name:         "used exceeds total clamps free to zero",
			label:        "INTR",
			disk:         DiskStatus{UsedPercent: 110.0, Used: 110 << 30, Total: 100 << 30},
			wantUsed:     "110G used",
			wantFree:     "0 free",
			wantNoSubstr: "%",
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
			if !strings.Contains(got, expectedLabel) {
				t.Errorf("formatDiskLine(%q, ...) = %q, should contain label %q", tt.label, got, expectedLabel)
			}
			if !strings.Contains(got, tt.wantUsed) {
				t.Errorf("formatDiskLine(%q, ...) = %q, should contain used value %q", tt.label, got, tt.wantUsed)
			}
			if !strings.Contains(got, tt.wantFree) {
				t.Errorf("formatDiskLine(%q, ...) = %q, should contain free value %q", tt.label, got, tt.wantFree)
			}
			if tt.wantNoSubstr != "" && strings.Contains(got, tt.wantNoSubstr) {
				t.Errorf("formatDiskLine(%q, ...) = %q, should not contain %q", tt.label, got, tt.wantNoSubstr)
			}
		})
	}
}

func TestRenderDiskCardAddsMetaLineForSingleDisk(t *testing.T) {
	card := renderDiskCard([]DiskStatus{{
		UsedPercent: 28.4,
		Used:        263 << 30,
		Total:       926 << 30,
		Fstype:      "apfs",
	}}, DiskIOStatus{ReadRate: 0, WriteRate: 0.1}, 0, false)

	if len(card.lines) != 4 {
		t.Fatalf("renderDiskCard() single disk expected 4 lines, got %d", len(card.lines))
	}

	meta := stripANSI(card.lines[1])
	if meta != "Total  926G · APFS" {
		t.Fatalf("renderDiskCard() single disk meta line = %q, want %q", meta, "Total  926G · APFS")
	}
}

func TestRenderDiskCardDoesNotAddMetaLineForMultipleDisks(t *testing.T) {
	card := renderDiskCard([]DiskStatus{
		{UsedPercent: 28.4, Used: 263 << 30, Total: 926 << 30, Fstype: "apfs"},
		{UsedPercent: 50.0, Used: 500 << 30, Total: 1000 << 30, Fstype: "apfs"},
	}, DiskIOStatus{}, 0, false)

	if len(card.lines) != 4 {
		t.Fatalf("renderDiskCard() multiple disks expected 4 lines, got %d", len(card.lines))
	}

	for _, line := range card.lines {
		if stripANSI(line) == "Total  926G · APFS" || stripANSI(line) == "Total  1000G · APFS" {
			t.Fatalf("renderDiskCard() multiple disks should not add meta line, got %q", line)
		}
	}
}

func TestRenderDiskCardOmitsTrashFromMainView(t *testing.T) {
	disk := DiskStatus{UsedPercent: 50, Used: 500 << 30, Total: 1000 << 30, Fstype: "apfs"}
	tests := []struct {
		name      string
		trashSize uint64
		approx    bool
	}{
		{"no trash", 0, false},
		{"1.5 GB exact", 1536 << 20, false},
		{"approx 12 GB", 12 << 30, true},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			card := renderDiskCard([]DiskStatus{disk}, DiskIOStatus{}, tt.trashSize, tt.approx)
			ioLine := ""
			trashLine := ""
			for _, line := range card.lines {
				s := stripANSI(line)
				if strings.HasPrefix(s, "I/O") {
					ioLine = s
				}
				if strings.HasPrefix(s, "Trash") {
					trashLine = s
				}
			}
			if ioLine == "" {
				t.Fatal("expected I/O line")
			}
			if trashLine != "" {
				t.Fatalf("expected no trash line in main view, got %q", trashLine)
			}
		})
	}
}

func TestRenderDiskCardUsesGraphicIOLine(t *testing.T) {
	card := renderDiskCard([]DiskStatus{
		{UsedPercent: 50.0, Used: 500 << 30, Total: 1000 << 30},
		{UsedPercent: 95.0, Used: 18 << 30, Total: 18<<30 + 472<<20, External: true},
		{UsedPercent: 95.0, Used: 16 << 30, Total: 16<<30 + 444<<20, External: true},
	}, DiskIOStatus{ReadRate: 0, WriteRate: 24.6}, 101<<20, false)

	if len(card.lines) != 5 {
		t.Fatalf("renderDiskCard() expected 5 lines without trash, got %d", len(card.lines))
	}
	if got := stripANSI(card.lines[4]); got != "I/O    ▯▯▯▯▯ R 0 · ▮▮▯▯▯ W 25 MB/s" {
		t.Fatalf("I/O line = %q", got)
	}
}

func TestRenderDiskCardFormatsSingleAndMultipleSMARTSummaries(t *testing.T) {
	single := renderDiskCard([]DiskStatus{{
		UsedPercent: 30,
		Used:        30 << 30,
		Total:       100 << 30,
		SmartStatus: smartStatusVerified,
	}}, DiskIOStatus{}, 0, false)
	if got := stripANSI(single.lines[2]); got != "SMART  Verified" {
		t.Fatalf("single SMART line = %q", got)
	}

	multiple := renderDiskCard([]DiskStatus{
		{UsedPercent: 30, Used: 30 << 30, Total: 100 << 30, SmartStatus: smartStatusVerified},
		{UsedPercent: 20, Used: 20 << 30, Total: 100 << 30, External: true, SmartStatus: smartStatusUnsupported},
	}, DiskIOStatus{}, 0, false)
	if got := stripANSI(multiple.lines[2]); got != "SMART  INTR OK · EXTR N/A" {
		t.Fatalf("multiple SMART line = %q", got)
	}
}

func TestRenderDiskCardHighlightsFailingSMARTAndFitsNarrowWidth(t *testing.T) {
	card := renderDiskCard([]DiskStatus{
		{UsedPercent: 30, Used: 30 << 30, Total: 100 << 30, SmartStatus: smartStatusFailing},
		{UsedPercent: 20, Used: 20 << 30, Total: 100 << 30, External: true, SmartStatus: smartStatusUnknown},
	}, DiskIOStatus{}, 0, false)

	smartLine := card.lines[2]
	if !strings.Contains(smartLine, dangerStyle.Render("FAIL")) ||
		!strings.Contains(smartLine, dangerStyle.Render("Back up now")) {
		t.Fatalf("failing SMART line lacks danger styling or backup hint: %q", smartLine)
	}

	const narrowWidth = 38
	rendered := renderCard(card, narrowWidth)
	for line := range strings.Lines(rendered) {
		if lipgloss.Width(stripANSI(line)) > narrowWidth {
			t.Fatalf("narrow disk card line exceeds %d columns: %q", narrowWidth, line)
		}
	}
	if plain := stripANSI(rendered); !strings.Contains(plain, "Back up now") {
		t.Fatalf("narrow disk card lost backup hint: %q", plain)
	} else if !strings.Contains(plain, "FAIL") {
		t.Fatalf("narrow disk card lost failing status: %q", plain)
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

func TestRenderHeaderErrorReturnsMoleOnce(t *testing.T) {
	header, mole := renderHeader(MetricsSnapshot{}, "boom", 0, 120, false)

	if mole != "" {
		t.Fatalf("renderHeader() mole return should be empty on error to avoid duplicate render, got %q", mole)
	}
	if !strings.Contains(header, "ERROR: boom") {
		t.Fatalf("renderHeader() missing error text, got %q", header)
	}
	if strings.Count(header, "/\\_/\\") != 1 {
		t.Fatalf("renderHeader() should contain one mole frame in error state, got %d", strings.Count(header, "/\\_/\\"))
	}
}

func TestStatusDiagnosisLinePrioritizesFailingSMART(t *testing.T) {
	m := MetricsSnapshot{
		CPU:   CPUStatus{Usage: 95},
		Disks: []DiskStatus{{SmartStatus: smartStatusFailing}},
	}

	if got := statusDiagnosisLine(m); got != "SMART failing, back up now" {
		t.Fatalf("statusDiagnosisLine() = %q", got)
	}
}

func TestStatusDiagnosisLineUsesTopCPUProcess(t *testing.T) {
	m := MetricsSnapshot{
		CPU: CPUStatus{Usage: 95},
		TopProcesses: []ProcessInfo{
			{Name: "Safari", CPU: 12},
			{Name: "Xcode", CPU: 82},
		},
	}

	got := statusDiagnosisLine(m)
	if got != "Xcode high CPU" {
		t.Fatalf("statusDiagnosisLine() = %q, want top CPU process", got)
	}
}

func TestStatusDiagnosisLineUsesMemoryContributorWhenCPUIsCalm(t *testing.T) {
	m := MetricsSnapshot{
		CPU: CPUStatus{Usage: 20},
		Memory: MemoryStatus{
			UsedPercent: 86,
			Pressure:    "warn",
		},
		TopProcesses: []ProcessInfo{
			{Name: "Chrome", Memory: 31},
			{Name: "Finder", Memory: 2},
		},
	}

	got := statusDiagnosisLine(m)
	if got != "Chrome memory pressure" {
		t.Fatalf("statusDiagnosisLine() = %q, want memory contributor", got)
	}
}

func TestStatusDiagnosisLineFallsBackToAllClear(t *testing.T) {
	m := MetricsSnapshot{
		CPU:            CPUStatus{Usage: 10},
		Memory:         MemoryStatus{UsedPercent: 20, Pressure: "normal"},
		HealthScoreMsg: "Excellent",
	}

	got := statusDiagnosisLine(m)
	if got != "All clear" {
		t.Fatalf("statusDiagnosisLine() = %q, want All clear", got)
	}
}

func TestRenderProcessCardAddsInlineMemoryWithoutExtraRows(t *testing.T) {
	card := renderProcessCard([]ProcessInfo{
		{Name: "Chrome", CPU: 12, Memory: 22, MemoryBytes: 2 * 1024 * 1024 * 1024},
		{Name: "Xcode", CPU: 95, Memory: 8, MemoryBytes: 512 * 1024 * 1024},
	}, colWidth)

	if len(card.lines) != 2 {
		t.Fatalf("renderProcessCard() lines = %d, want 2", len(card.lines))
	}
	plain := stripANSI(strings.Join(card.lines, "\n"))
	if !strings.Contains(plain, "2.0G") {
		t.Fatalf("renderProcessCard() missing resident memory hint, got %q", plain)
	}
	if !strings.Contains(plain, "95.0%") {
		t.Fatalf("renderProcessCard() missing cpu value, got %q", plain)
	}
}

func TestRenderProcessCardShowsCollectingWhenEmpty(t *testing.T) {
	card := renderProcessCard(nil, colWidth)

	if len(card.lines) != 1 {
		t.Fatalf("renderProcessCard() empty lines = %d, want 1", len(card.lines))
	}
	if got := stripANSI(card.lines[0]); got != "Collecting..." {
		t.Fatalf("renderProcessCard() empty line = %q", got)
	}
}

func TestRenderProcessCardAlignsMetricColumns(t *testing.T) {
	const wideCardWidth = 56
	card := renderProcessCard([]ProcessInfo{
		{Name: "duetexpertd", CPU: 97.3, MemoryBytes: 75 << 20},
		{Name: "WindowServer", CPU: 46.8, MemoryBytes: 352 << 20},
		{Name: "Xcode", CPU: 24.3, MemoryBytes: 1018 << 20},
	}, wideCardWidth)

	if len(card.lines) != 3 {
		t.Fatalf("renderProcessCard() lines = %d, want 3", len(card.lines))
	}
	lines := make([]string, 0, len(card.lines))
	for _, line := range card.lines {
		lines = append(lines, stripANSI(line))
	}

	barText := []string{
		"███████████████░",
		"███████░░░░░░░░░",
		"███░░░░░░░░░░░░░",
	}
	memoryText := []string{"75.0M", "352.0M", "1018.0M"}
	barCol := strings.Index(lines[0], barText[0])
	if barCol != metricLabelWidth+1 {
		t.Fatalf("process bar column = %d, want %d in %q", barCol, metricLabelWidth+1, lines[0])
	}
	afterBar := lines[0][barCol+len(barText[0]):]
	if !strings.HasPrefix(afterBar, "  97.3%") {
		t.Fatalf("process percent should sit one column closer to the bar, got %q", lines[0])
	}
	percentCol := strings.Index(lines[0], "%")
	memoryEndCol := strings.Index(lines[0], memoryText[0]) + len(memoryText[0])
	for i, line := range lines {
		if got := strings.Index(line, barText[i]); got != barCol {
			t.Fatalf("process bar column line %d = %d, want %d in %q", i, got, barCol, line)
		}
		if got := strings.Index(line, "%"); got != percentCol {
			t.Fatalf("process percent column line %d = %d, want %d in %q", i, got, percentCol, line)
		}
		gotMemoryEnd := strings.Index(line, memoryText[i]) + len(memoryText[i])
		if gotMemoryEnd != memoryEndCol {
			t.Fatalf("process memory column line %d ends at %d, want %d in %q", i, gotMemoryEnd, memoryEndCol, line)
		}
	}
	if lipgloss.Width(lines[0]) > wideCardWidth {
		t.Fatalf("renderProcessCard() line exceeds card width: %q", lines[0])
	}
	if !strings.Contains(lines[0], "duet") {
		t.Fatalf("renderProcessCard() should keep process name after metrics, got %q", lines[0])
	}
}

func TestRenderProcessCardFallsBackToMemoryPercent(t *testing.T) {
	card := renderProcessCard([]ProcessInfo{
		{Name: "Chrome", CPU: 12, Memory: 22},
	}, colWidth)

	plain := stripANSI(strings.Join(card.lines, "\n"))
	if !strings.Contains(plain, "M22%") {
		t.Fatalf("renderProcessCard() missing memory percent fallback, got %q", plain)
	}
}

func TestRenderHeaderUsesFastMetricSpecFallbacks(t *testing.T) {
	const ram = uint64(16 * 1024 * 1024 * 1024)
	const diskSize = uint64(512 * 1024 * 1024 * 1024)
	m := MetricsSnapshot{
		HealthScore: 90,
		Memory:      MemoryStatus{Total: ram},
		Disks:       []DiskStatus{{Mount: "/", Total: diskSize}},
	}

	header, _ := renderHeader(m, "", 0, 120, true)
	plain := stripANSI(header)
	wantRAM := "RAM " + humanBytes(ram)
	wantDisk := "Disk " + humanBytes(diskSize)
	if !strings.Contains(plain, wantRAM) || !strings.Contains(plain, wantDisk) {
		t.Fatalf("renderHeader() should label fast metric specs %q and %q, got %q", wantRAM, wantDisk, plain)
	}
	if strings.Contains(plain, humanBytes(ram)+"/"+humanBytes(diskSize)) {
		t.Fatalf("renderHeader() should not render RAM and disk as a slash pair, got %q", plain)
	}
}

func TestRenderHeaderWrapsOnNarrowWidth(t *testing.T) {
	m := MetricsSnapshot{
		HealthScore: 91,
		Hardware: HardwareInfo{
			Model:       "MacBook Pro",
			CPUModel:    "Apple M3 Max",
			TotalRAM:    "128GB",
			DiskSize:    "4TB",
			RefreshRate: "120Hz",
			OSVersion:   "macOS 15.0",
		},
		Uptime: "10d 3h",
	}

	header, _ := renderHeader(m, "", 0, 38, true)
	for line := range strings.Lines(header) {
		if lipgloss.Width(stripANSI(line)) > 38 {
			t.Fatalf("renderHeader() line exceeds width: %q", line)
		}
	}
}

func TestRenderHeaderHidesOSAndUptimeOnNarrowWidth(t *testing.T) {
	m := MetricsSnapshot{
		HealthScore: 91,
		Hardware: HardwareInfo{
			Model:       "MacBook Pro",
			CPUModel:    "Apple M3 Max",
			TotalRAM:    "128GB",
			DiskSize:    "4TB",
			RefreshRate: "120Hz",
			OSVersion:   "macOS 15.0",
		},
		Uptime: "10d 3h",
	}

	header, _ := renderHeader(m, "", 0, 80, true)
	plain := stripANSI(header)
	if strings.Contains(plain, "macOS 15.0") {
		t.Fatalf("renderHeader() narrow width should hide os version, got %q", plain)
	}
	if strings.Contains(plain, "up 10d 3h") {
		t.Fatalf("renderHeader() narrow width should hide uptime, got %q", plain)
	}
}

func TestRenderHeaderKeepsLabeledSpecsOnCompactWidth(t *testing.T) {
	m := MetricsSnapshot{
		HealthScore: 91,
		Hardware: HardwareInfo{
			Model:       "MacBook Pro",
			CPUModel:    "Apple M4 Pro",
			TotalRAM:    "48G",
			DiskSize:    "926GB",
			RefreshRate: "120Hz",
		},
		GPU: []GPUStatus{{CoreCount: 20}},
	}

	header, _ := renderHeader(m, "", 0, 80, true)
	plain := stripANSI(header)
	if !strings.Contains(plain, "RAM 48G") || !strings.Contains(plain, "Disk 926GB") {
		t.Fatalf("renderHeader() compact width should keep labeled specs, got %q", plain)
	}
	if strings.Contains(plain, "48G/926GB") {
		t.Fatalf("renderHeader() compact width should not use slash specs, got %q", plain)
	}
	for line := range strings.Lines(header) {
		if lipgloss.Width(stripANSI(line)) > 80 {
			t.Fatalf("renderHeader() compact line exceeds width: %q", line)
		}
	}
}

func TestRenderHeaderDropsLowPriorityInfoToStaySingleLine(t *testing.T) {
	m := MetricsSnapshot{
		HealthScore: 90,
		Hardware: HardwareInfo{
			Model:       "MacBook Pro",
			CPUModel:    "Apple M2 Pro",
			TotalRAM:    "32.0 GB",
			DiskSize:    "460.4 GB",
			RefreshRate: "60Hz",
			OSVersion:   "macOS 26.3",
		},
		GPU:    []GPUStatus{{CoreCount: 19}},
		Uptime: "9d 13h",
	}

	header, _ := renderHeader(m, "", 0, 100, true)
	plain := stripANSI(header)
	if strings.Contains(plain, "\n") {
		t.Fatalf("renderHeader() should stay single line when trimming low-priority fields, got %q", plain)
	}
	if strings.Contains(plain, "macOS 26.3") {
		t.Fatalf("renderHeader() should drop os version when width is tight, got %q", plain)
	}
	if strings.Contains(plain, "up 9d 13h") {
		t.Fatalf("renderHeader() should drop uptime when width is tight, got %q", plain)
	}
}

func TestRenderCardWrapsOnNarrowWidth(t *testing.T) {
	card := cardData{
		icon:  iconCPU,
		title: "CPU",
		lines: []string{
			"Total  ████████████████  100.0% @ 85.0°C",
			"Load   12.34 / 8.90 / 7.65, 4P+4E",
		},
	}

	rendered := renderCard(card, 26)
	for line := range strings.Lines(rendered) {
		if lipgloss.Width(stripANSI(line)) > 26 {
			t.Fatalf("renderCard() line exceeds width: %q", line)
		}
	}
}

func TestRenderCPUCardKeepsOnlyTwoHotCores(t *testing.T) {
	card := renderCPUCard(CPUStatus{
		Usage:      6.1,
		PerCore:    []float64{8.0, 27.9, 18.9, 16.8},
		Load1:      2.30,
		Load5:      2.27,
		Load15:     2.16,
		LogicalCPU: 4,
	}, ThermalStatus{}, 2)

	plain := stripANSI(strings.Join(card.lines, "\n"))
	if len(card.lines) != 4 {
		t.Fatalf("renderCPUCard() lines = %d, want 4", len(card.lines))
	}
	if strings.Count(plain, "Core") != 2 {
		t.Fatalf("renderCPUCard() should render two core rows, got %q", plain)
	}
	if !strings.Contains(plain, "Core2") || !strings.Contains(plain, "Core3") {
		t.Fatalf("renderCPUCard() should keep the two hottest cores, got %q", plain)
	}
}

func TestRenderCPUCardHonoursCoreCount(t *testing.T) {
	cpu := CPUStatus{
		Usage:      6.1,
		PerCore:    []float64{8.0, 27.9, 18.9, 16.8},
		LogicalCPU: 4,
	}

	// cpuCores = 0 means "all": every core gets a row.
	all := stripANSI(strings.Join(renderCPUCard(cpu, ThermalStatus{}, 0).lines, "\n"))
	if got := strings.Count(all, "Core"); got != 4 {
		t.Fatalf("cpuCores=0 should render all 4 cores, got %d rows: %q", got, all)
	}

	// A custom count lists exactly that many of the hottest cores.
	three := stripANSI(strings.Join(renderCPUCard(cpu, ThermalStatus{}, 3).lines, "\n"))
	if got := strings.Count(three, "Core"); got != 3 {
		t.Fatalf("cpuCores=3 should render 3 cores, got %d rows: %q", got, three)
	}

	// A count larger than the core total is clamped, not padded.
	many := stripANSI(strings.Join(renderCPUCard(cpu, ThermalStatus{}, 99).lines, "\n"))
	if got := strings.Count(many, "Core"); got != 4 {
		t.Fatalf("cpuCores=99 should clamp to 4 cores, got %d rows: %q", got, many)
	}
}

func TestNextCPUCoresCyclesAndWraps(t *testing.T) {
	want := []int{4, 8, 0, 2} // starting from 2, one full loop back to 2
	got := 2
	for i, exp := range want {
		got = nextCPUCores(got)
		if got != exp {
			t.Fatalf("step %d: nextCPUCores gave %d, want %d", i, got, exp)
		}
	}
	// An unknown value restarts the cycle at the default.
	if n := nextCPUCores(7); n != 2 {
		t.Fatalf("nextCPUCores(7) = %d, want default 2", n)
	}
}

func TestSmallerCPUCoresStepsDownAndFloors(t *testing.T) {
	for _, tc := range []struct{ from, want int }{
		{0, 8}, {8, 4}, {4, 2}, {2, 2}, {7, 2},
	} {
		if got := smallerCPUCores(tc.from); got != tc.want {
			t.Errorf("smallerCPUCores(%d) = %d, want %d", tc.from, got, tc.want)
		}
	}
}

// A tall CPU card must never push the frame past the window: the view steps the
// core count back down until it fits, so the lower cards stay on screen.
func TestViewShrinksCPUCardToFitHeight(t *testing.T) {
	cpu := CPUStatus{Usage: 6.1, LogicalCPU: 20}
	for i := range 20 {
		cpu.PerCore = append(cpu.PerCore, float64(i))
	}
	m := model{
		ready:    true,
		width:    120,
		metrics:  MetricsSnapshot{CPU: cpu},
		cpuCores: 0, // "all"
	}

	tall := m
	tall.height = 200
	if got := lipgloss.Height(tall.View()); got != 200 {
		t.Fatalf("tall window should render all cores and pad to 200, got %d", got)
	}

	short := m
	short.height = 20
	if got := lipgloss.Height(short.View()); got > 20 {
		t.Fatalf("frame overflows a 20-line window: %d lines", got)
	}
	if strings.Count(stripANSI(short.View()), "Core") > 8 {
		t.Error("short window should have stepped the core count down")
	}
}

func TestLayoutColumnRowsStacksBesideTallCard(t *testing.T) {
	tall := cardData{icon: iconCPU, title: "CPU", lines: make([]string, 12)}
	short := func(title string) cardData {
		return cardData{title: title, lines: []string{"x"}}
	}
	cards := []cardData{tall, short("GPU"), short("Memory"), short("Disk")}

	rows := layoutColumnRows(cards, colWidth)

	if len(rows) == 0 || len(rows[0].left) != 1 || rows[0].left[0].title != "CPU" {
		t.Fatalf("first row should seed its left cell with CPU, got %+v", rows)
	}
	// Several short cards stack beside the tall CPU to fill its height and keep
	// the following rows' titles aligned.
	if len(rows[0].right) < 2 {
		t.Errorf("tall CPU should be matched by >=2 stacked cards, got %d", len(rows[0].right))
	}
	// Every card is placed exactly once.
	total := 0
	for _, r := range rows {
		total += len(r.left) + len(r.right)
	}
	if total != len(cards) {
		t.Errorf("placed %d cards, want %d", total, len(cards))
	}
}

func TestRenderTwoColumnsAlignsRowTitles(t *testing.T) {
	mk := func(icon, title string, n int) cardData {
		lines := make([]string, n)
		for i := range lines {
			lines[i] = title
		}
		return cardData{icon: icon, title: title, lines: lines}
	}
	// A tall CPU beside short cards: GPU+Memory stack in row 0, then Disk and
	// Power form row 1 and must line up on the same output line.
	cards := []cardData{
		mk(iconCPU, "CPU", 11),
		mk(iconGPU, "GPU", 6),
		mk(iconMemory, "Memory", 4),
		mk(iconDisk, "Disk", 3),
		mk(iconBattery, "Power", 3),
	}

	out := stripANSI(renderTwoColumns(cards, 120))
	aligned := false
	for line := range strings.Lines(out) {
		if strings.Contains(line, "Disk") && strings.Contains(line, "Power") {
			aligned = true
			break
		}
	}
	if !aligned {
		t.Errorf("Disk and Power titles should sit on the same row:\n%s", out)
	}
}

func TestRenderTwoColumnsNeverGrowsFixedPairLayout(t *testing.T) {
	const width = 120
	cards := buildCards(MetricsSnapshot{}, width/2-4, 2)
	cw := width/2 - 2

	var fixedRows []string
	for i := 0; i < len(cards); i += 2 {
		left := renderCard(cards[i], cw)
		if i+1 >= len(cards) {
			fixedRows = append(fixedRows, left)
			continue
		}
		right := renderCard(cards[i+1], cw)
		fixedRows = append(fixedRows, lipgloss.JoinHorizontal(lipgloss.Top, left, "  ", right))
	}
	var spacedFixedRows []string
	for i, row := range fixedRows {
		if i > 0 {
			spacedFixedRows = append(spacedFixedRows, "")
		}
		spacedFixedRows = append(spacedFixedRows, row)
	}
	fixed := lipgloss.JoinVertical(lipgloss.Left, spacedFixedRows...)
	balanced := renderTwoColumns(cards, width)

	if got, limit := lipgloss.Height(balanced), lipgloss.Height(fixed); got > limit {
		t.Fatalf("balanced layout grew from %d to %d lines:\n%s", limit, got, stripANSI(balanced))
	}
}

func TestRenderTwoColumnsInsertsRowGap(t *testing.T) {
	cards := []cardData{
		{icon: iconCPU, title: "CPU", lines: []string{"Total  ok"}},
		{icon: iconMemory, title: "Memory", lines: []string{"Used   ok"}},
		{icon: iconDisk, title: "Disk", lines: []string{"INTR   ok"}},
		{icon: iconNetwork, title: "Network", lines: []string{"Down   ok"}},
	}

	rendered := stripANSI(renderTwoColumns(cards, 120))
	hasBlankRow := false
	for line := range strings.Lines(rendered) {
		if strings.TrimSpace(line) == "" {
			hasBlankRow = true
			break
		}
	}
	if !hasBlankRow {
		t.Fatalf("renderTwoColumns() should insert one blank row between card rows, got %q", rendered)
	}
}

func TestRenderMemoryCardHidesSwapSizeOnNarrowWidth(t *testing.T) {
	card := renderMemoryCard(MemoryStatus{
		Used:        8 << 30,
		Total:       16 << 30,
		Available:   8 << 30,
		UsedPercent: 50.0,
		SwapUsed:    482,
		SwapTotal:   1000,
	}, 38)

	if len(card.lines) < 3 {
		t.Fatalf("renderMemoryCard() expected at least 3 lines, got %d", len(card.lines))
	}

	swapLine := stripANSI(card.lines[2])
	if strings.Contains(swapLine, "/") {
		t.Fatalf("renderMemoryCard() narrow width should hide swap size, got %q", swapLine)
	}
}

func TestRenderMemoryCardShowsSwapSizeOnWideWidth(t *testing.T) {
	card := renderMemoryCard(MemoryStatus{
		Used:        8 << 30,
		Total:       16 << 30,
		Available:   8 << 30,
		UsedPercent: 50.0,
		SwapUsed:    482,
		SwapTotal:   1000,
	}, 60)

	if len(card.lines) < 3 {
		t.Fatalf("renderMemoryCard() expected at least 3 lines, got %d", len(card.lines))
	}

	swapLine := stripANSI(card.lines[2])
	if !strings.Contains(swapLine, "/") {
		t.Fatalf("renderMemoryCard() wide width should include swap size, got %q", swapLine)
	}
}

func TestRenderMemoryCardUsesCollectedAvailableMemory(t *testing.T) {
	card := renderMemoryCard(MemoryStatus{
		Used:        12 << 30,
		Total:       16 << 30,
		Available:   9 << 30,
		UsedPercent: 75.0,
	}, 60)

	plain := stripANSI(strings.Join(card.lines, "\n"))
	if !strings.Contains(plain, "Free") || !strings.Contains(plain, "56.2%") {
		t.Fatalf("renderMemoryCard() should derive free percent from Available, got %q", plain)
	}
	if !strings.Contains(plain, "Avail  9.0 GB") {
		t.Fatalf("renderMemoryCard() should render collected Available memory, got %q", plain)
	}
}

func TestRenderMemoryCardCombinesCacheAndAvailable(t *testing.T) {
	card := renderMemoryCard(MemoryStatus{
		Used:        12 << 30,
		Total:       16 << 30,
		Available:   9 << 30,
		Cached:      2 << 30,
		UsedPercent: 75.0,
	}, 60)

	plain := stripANSI(strings.Join(card.lines, "\n"))
	if len(card.lines) != 4 {
		t.Fatalf("renderMemoryCard() lines = %d, want 4", len(card.lines))
	}
	if !strings.Contains(plain, "Cache  2.0 GB · Avail 9.0 GB") {
		t.Fatalf("renderMemoryCard() should combine cache and available memory, got %q", plain)
	}
}

func TestModelViewPadsToTerminalHeight(t *testing.T) {
	tests := []struct {
		name   string
		width  int
		height int
	}{
		{"narrow terminal", 60, 40},
		{"wide terminal", 120, 40},
		{"tall terminal", 120, 80},
		{"short terminal", 120, 10},
		{"zero height", 120, 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			m := model{
				width:   tt.width,
				height:  tt.height,
				ready:   true,
				metrics: MetricsSnapshot{},
			}

			view := m.View()
			got := lipgloss.Height(view)
			if got < tt.height {
				t.Errorf("View() height = %d, want >= %d (terminal height)", got, tt.height)
			}
		})
	}
}

func TestModelViewErrorRendersSingleMole(t *testing.T) {
	m := model{
		width:      120,
		height:     40,
		ready:      true,
		metrics:    MetricsSnapshot{},
		errMessage: "boom",
		animFrame:  0,
		catHidden:  false,
	}

	view := m.View()
	if strings.Count(view, "/\\_/\\") != 1 {
		t.Fatalf("model.View() should render one mole frame in error state, got %d", strings.Count(view, "/\\_/\\"))
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
