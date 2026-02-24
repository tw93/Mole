//go:build darwin

package main

import (
	"testing"

	"github.com/tw93/mole/internal/metrics"
)

func TestPlainProgressBar(t *testing.T) {
	tests := []struct {
		percent float64
		filled  int // expected number of █ characters
	}{
		{0, 0},
		{50, 8},
		{100, 16},
		{-5, 0},   // clamped
		{110, 16},  // clamped
		{25, 4},
		{6.25, 1},  // exactly 1/16
	}
	for _, tt := range tests {
		bar := plainProgressBar(tt.percent)
		if len([]rune(bar)) != 16 {
			t.Errorf("plainProgressBar(%.1f) length = %d, want 16", tt.percent, len([]rune(bar)))
		}
		filled := 0
		for _, r := range bar {
			if r == '█' {
				filled++
			}
		}
		if filled != tt.filled {
			t.Errorf("plainProgressBar(%.1f) filled = %d, want %d", tt.percent, filled, tt.filled)
		}
	}
}

func TestPlainIoBar(t *testing.T) {
	tests := []struct {
		rate   float64
		filled int
	}{
		{0, 0},
		{10, 1},
		{25, 2},
		{50, 5},   // capped at 5
		{100, 5},  // capped at 5
	}
	for _, tt := range tests {
		bar := plainIoBar(tt.rate)
		if len([]rune(bar)) != 5 {
			t.Errorf("plainIoBar(%.1f) length = %d, want 5", tt.rate, len([]rune(bar)))
		}
		filled := 0
		for _, r := range bar {
			if r == '▮' {
				filled++
			}
		}
		if filled != tt.filled {
			t.Errorf("plainIoBar(%.1f) filled = %d, want %d", tt.rate, filled, tt.filled)
		}
	}
}

func TestPlainMiniBar(t *testing.T) {
	tests := []struct {
		percent float64
		filled  int
	}{
		{0, 0},
		{20, 1},
		{50, 2},
		{100, 5},
		{200, 5}, // capped
	}
	for _, tt := range tests {
		bar := plainMiniBar(tt.percent)
		if len([]rune(bar)) != 5 {
			t.Errorf("plainMiniBar(%.1f) length = %d, want 5", tt.percent, len([]rune(bar)))
		}
		filled := 0
		for _, r := range bar {
			if r == '▮' {
				filled++
			}
		}
		if filled != tt.filled {
			t.Errorf("plainMiniBar(%.1f) filled = %d, want %d", tt.percent, filled, tt.filled)
		}
	}
}

func TestPlainSparkline(t *testing.T) {
	// Empty history produces all-lowest bars.
	spark := plainSparkline(nil, 8)
	if len([]rune(spark)) != 8 {
		t.Errorf("plainSparkline(nil, 8) length = %d, want 8", len([]rune(spark)))
	}
	for _, r := range spark {
		if r != '▁' {
			t.Errorf("plainSparkline(nil) should be all ▁, got %c", r)
			break
		}
	}

	// With data, highest value should map to █.
	data := []float64{0, 0.5, 1.0}
	spark = plainSparkline(data, 3)
	runes := []rune(spark)
	if runes[2] != '█' {
		t.Errorf("plainSparkline max value should be █, got %c", runes[2])
	}
	if runes[0] != '▁' {
		t.Errorf("plainSparkline zero value should be ▁, got %c", runes[0])
	}
}

func TestHealthEmoji(t *testing.T) {
	tests := []struct {
		score int
		want  string
	}{
		{95, "🟢"},
		{75, "🟢"},
		{60, "🟡"},
		{40, "🔴"},
		{0, "🔴"},
	}
	for _, tt := range tests {
		if got := healthEmoji(tt.score); got != tt.want {
			t.Errorf("healthEmoji(%d) = %s, want %s", tt.score, got, tt.want)
		}
	}
}

func TestPercentEmoji(t *testing.T) {
	tests := []struct {
		percent float64
		want    string
	}{
		{90, "🔴"},
		{85, "🔴"},
		{70, "🟡"},
		{60, "🟡"},
		{50, "🟢"},
		{0, "🟢"},
	}
	for _, tt := range tests {
		if got := percentEmoji(tt.percent); got != tt.want {
			t.Errorf("percentEmoji(%.0f) = %s, want %s", tt.percent, got, tt.want)
		}
	}
}

func TestBatteryEmoji(t *testing.T) {
	tests := []struct {
		percent float64
		want    string
	}{
		{80, "🟢"},
		{50, "🟢"},
		{40, "🟡"},
		{20, "🟡"},
		{15, "🔴"},
		{0, "🔴"},
	}
	for _, tt := range tests {
		if got := batteryEmoji(tt.percent); got != tt.want {
			t.Errorf("batteryEmoji(%.0f) = %s, want %s", tt.percent, got, tt.want)
		}
	}
}

func TestPressureEmoji(t *testing.T) {
	tests := []struct {
		pressure string
		want     string
	}{
		{"normal", "🟢"},
		{"warn", "🟡"},
		{"critical", "🔴"},
		{"", "🟢"},
	}
	for _, tt := range tests {
		if got := pressureEmoji(tt.pressure); got != tt.want {
			t.Errorf("pressureEmoji(%q) = %s, want %s", tt.pressure, got, tt.want)
		}
	}
}

func TestMenuSplitDisks(t *testing.T) {
	disks := []metrics.DiskStatus{
		{Mount: "/", External: false},
		{Mount: "/Volumes/USB", External: true},
		{Mount: "/Volumes/Data", External: false},
	}
	internal, external := menuSplitDisks(disks)
	if len(internal) != 2 {
		t.Errorf("internal count = %d, want 2", len(internal))
	}
	if len(external) != 1 {
		t.Errorf("external count = %d, want 1", len(external))
	}
}

func TestMenuDiskLabel(t *testing.T) {
	tests := []struct {
		prefix string
		index  int
		total  int
		want   string
	}{
		{"INTR", 0, 1, "INTR"},
		{"INTR", 0, 2, "INTR1"},
		{"INTR", 1, 2, "INTR2"},
		{"EXTR", 0, 1, "EXTR"},
	}
	for _, tt := range tests {
		if got := menuDiskLabel(tt.prefix, tt.index, tt.total); got != tt.want {
			t.Errorf("menuDiskLabel(%q, %d, %d) = %q, want %q",
				tt.prefix, tt.index, tt.total, got, tt.want)
		}
	}
}

func TestPlainFormatDiskLine(t *testing.T) {
	d := metrics.DiskStatus{Used: 200 * 1024 * 1024 * 1024, Total: 500 * 1024 * 1024 * 1024, UsedPercent: 40}
	line := plainFormatDiskLine("INTR", d)
	if line == "" {
		t.Error("plainFormatDiskLine returned empty string")
	}
	// Should contain the label and percentage.
	if !contains(line, "INTR") || !contains(line, "40.0%") {
		t.Errorf("plainFormatDiskLine output unexpected: %q", line)
	}
}

func TestShortenName(t *testing.T) {
	tests := []struct {
		input  string
		maxLen int
		want   string
	}{
		{"short", 10, "short"},
		{"LongProcessName", 10, "LongProce…"},
		{"exact", 5, "exact"},
		{"ab", 2, "ab"},
	}
	for _, tt := range tests {
		if got := shortenName(tt.input, tt.maxLen); got != tt.want {
			t.Errorf("shortenName(%q, %d) = %q, want %q", tt.input, tt.maxLen, got, tt.want)
		}
	}
}

func contains(s, sub string) bool {
	return len(s) >= len(sub) && (s == sub || len(s) > 0 && containsSubstr(s, sub))
}

func containsSubstr(s, sub string) bool {
	for i := 0; i <= len(s)-len(sub); i++ {
		if s[i:i+len(sub)] == sub {
			return true
		}
	}
	return false
}
