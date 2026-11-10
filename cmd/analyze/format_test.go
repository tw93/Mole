package main

import (
	"math"
	"strings"
	"testing"
	"time"

	"github.com/charmbracelet/lipgloss"
)

func TestSpinnerFramesHaveSingleColumnWidth(t *testing.T) {
	for _, frame := range spinnerFrames {
		if got := displayWidth(frame); got != 1 {
			t.Errorf("spinner frame %q width = %d, want 1", frame, got)
		}
	}
}

func TestDisplayWidthCharacters(t *testing.T) {
	tests := []struct {
		name  string
		input rune
		want  int
	}{
		{"ASCII letter", 'a', 1},
		{"ASCII digit", '5', 1},
		{"Chinese character", '中', 2},
		{"Japanese hiragana", 'あ', 2},
		{"Korean hangul", '한', 2},
		{"CJK ideograph", '語', 2},
		{"Full-width number", '１', 2},
		{"ASCII space", ' ', 1},
		{"Tab", '	', 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := displayWidth(string(tt.input)); got != tt.want {
				t.Errorf("displayWidth(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

func TestDisplayWidth(t *testing.T) {
	tests := []struct {
		name  string
		input string
		want  int
	}{
		{"Empty string", "", 0},
		{"ASCII only", "hello", 5},
		{"Chinese only", "你好", 4},
		{"Mixed ASCII and CJK", "hello世界", 9}, // 5 + 4
		{"Path with CJK", "/Users/张三/文件", 16}, // 7 (ASCII) + 4 (张三) + 4 (文件) + 1 (/) = 16
		{"Full-width chars", "１２３", 6},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			if got := displayWidth(tt.input); got != tt.want {
				t.Errorf("displayWidth(%q) = %d, want %d", tt.input, got, tt.want)
			}
		})
	}
}

// Sizes follow Windows Explorer: 1024-based, labeled KB/MB/GB.
func TestHumanizeBytes(t *testing.T) {
	tests := []struct {
		input int64
		want  string
	}{
		{-1, "0 B"},
		{0, "0 B"},
		{512, "512 B"},
		{1024, "1.0 KB"},
		{1536, "1.5 KB"},
		{1 << 20, "1.0 MB"},
		{1 << 30, "1.0 GB"},
		{1 << 40, "1.0 TB"},
		{1023, "1023 B"},
		{1<<20 - 1024, "1023.0 KB"},
		{1<<20 - 53, "1023.9 KB"},
		{1<<20 - 1, "1.0 MB"},
		{1<<30 - 1, "1.0 GB"},
		{1<<40 - 1, "1.0 TB"},
	}
	for _, tt := range tests {
		if got := humanizeBytes(tt.input); got != tt.want {
			t.Errorf("humanizeBytes(%d) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestFormatNumber(t *testing.T) {
	tests := []struct {
		input int64
		want  string
	}{
		{0, "0"},
		{500, "500"},
		{999, "999"},
		{1000, "1.0k"},
		{1500, "1.5k"},
		{999999, "1000.0k"},
		{1000000, "1.0M"},
		{1500000, "1.5M"},
	}

	for _, tt := range tests {
		got := formatNumber(tt.input)
		if got != tt.want {
			t.Errorf("formatNumber(%d) = %q, want %q", tt.input, got, tt.want)
		}
	}
}

func TestFormatPercentKeepsFixedWidth(t *testing.T) {
	tests := []struct {
		name    string
		percent float64
		known   bool
		want    string
	}{
		{"whole", 47, true, " 47.0%"},
		{"fraction", 0.9, true, "  0.9%"},
		{"threshold", 0.1, true, "  0.1%"},
		{"tiny nonzero", 0.046, true, "< 0.1%"},
		{"zero", 0, true, "  0.0%"},
		{"pending", 0, false, "      "},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := formatPercent(tt.percent, tt.known)
			if got != tt.want {
				t.Fatalf("formatPercent(%v, %v) = %q, want %q", tt.percent, tt.known, got, tt.want)
			}
			if displayWidth(got) != 6 {
				t.Fatalf("formatPercent width = %d, want 6 for %q", displayWidth(got), got)
			}
		})
	}
}

// The bar measures length in eighths of a cell across the whole range, so one
// glyph family encodes magnitude everywhere. Three outcomes matter: no value
// draws nothing, a value too small to scale keeps its place with a gray tick
// rather than an empty column, and anything larger draws to scale in color.
func TestColoredProgressBarKeepsFixedWidth(t *testing.T) {
	tests := []struct {
		name     string
		value    int64
		maxValue int64
		percent  float64
		want     string // "blank", "grayTick", or "scaled"
	}{
		{"empty", 0, 100, 0, "blank"},
		{"below one eighth of a cell", 1, 1000, 0.01, "grayTick"},
		{"sub-cell but scalable", 1, 40, 2.5, "scaled"},
		{"partial", 25, 100, 25, "scaled"},
		{"full", 100, 100, 100, "scaled"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := coloredProgressBar(tt.value, tt.maxValue, tt.percent, barWidth)
			if width := lipgloss.Width(got); width != barWidth {
				t.Fatalf("progress bar width = %d, want %d for %q", width, barWidth, got)
			}
			if strings.Contains(got, "░") || strings.Contains(got, "▓") || strings.Contains(got, "▒") {
				t.Fatalf("progress bar should encode length by width, not shading: %q", got)
			}
			switch tt.want {
			case "blank":
				if got != strings.Repeat(" ", barWidth) {
					t.Fatalf("no value should render blank, got %q", got)
				}
			case "grayTick":
				if !strings.HasPrefix(got, colorGray) {
					t.Fatalf("an unscalable value should keep its place in gray, got %q", got)
				}
				if !strings.Contains(got, subCellBlocks[1]) {
					t.Fatalf("gray tick should use the smallest block, got %q", got)
				}
			case "scaled":
				if strings.HasPrefix(got, colorGray) {
					t.Fatalf("a scalable value should draw in its own color, got %q", got)
				}
				if lipgloss.Width(strings.TrimSpace(got)) == 0 {
					t.Fatalf("a scalable value should draw glyphs, got %q", got)
				}
			}
		})
	}
}

// Scaling the byte count before dividing overflowed int64 at 42.7 PB, wrapped
// negative, and reached strings.Repeat with a negative count, which panics.
// Sizes that large are not realistic, but a rendering helper must not be able
// to take the whole TUI down on unexpected input.
func TestColoredProgressBarSurvivesExtremeSizes(t *testing.T) {
	sizes := []int64{
		1 << 50,           // 1 PB
		48038396025285290, // the old overflow threshold
		48038396025285291, // just past it
		math.MaxInt64 / 2,
		math.MaxInt64,
	}
	for _, size := range sizes {
		for _, pair := range [][2]int64{{size, size}, {1, size}, {size, 1}} {
			got := coloredProgressBar(pair[0], pair[1], 50, barWidth)
			if width := lipgloss.Width(got); width != barWidth {
				t.Fatalf("value=%d max=%d width=%d, want %d", pair[0], pair[1], width, barWidth)
			}
		}
	}
}

func TestTruncateMiddle(t *testing.T) {
	tests := []struct {
		name     string
		input    string
		maxWidth int
		check    func(t *testing.T, result string)
	}{
		{
			name:     "No truncation needed",
			input:    "short",
			maxWidth: 10,
			check: func(t *testing.T, result string) {
				if result != "short" {
					t.Errorf("Should not truncate short string, got %q", result)
				}
			},
		},
		{
			name:     "Truncate long ASCII",
			input:    "verylongfilename.txt",
			maxWidth: 15,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, "...") {
					t.Errorf("Truncated string should contain '...', got %q", result)
				}
				if displayWidth(result) > 15 {
					t.Errorf("Truncated width %d exceeds max %d", displayWidth(result), 15)
				}
			},
		},
		{
			name:     "Truncate with CJK characters",
			input:    "非常长的中文文件名称.txt",
			maxWidth: 20,
			check: func(t *testing.T, result string) {
				if !strings.Contains(result, "...") {
					t.Errorf("Should truncate CJK string, got %q", result)
				}
				if displayWidth(result) > 20 {
					t.Errorf("Truncated width %d exceeds max %d", displayWidth(result), 20)
				}
			},
		},
		{
			name:     "Very small width",
			input:    "longname",
			maxWidth: 5,
			check: func(t *testing.T, result string) {
				if displayWidth(result) > 5 {
					t.Errorf("Width %d exceeds max %d", displayWidth(result), 5)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := truncateMiddle(tt.input, tt.maxWidth)
			tt.check(t, result)
		})
	}
}

func TestDisplayPath(t *testing.T) {
	tests := []struct {
		name  string
		setup func() string
		check func(t *testing.T, result string)
	}{
		{
			name: "Replace home directory",
			setup: func() string {
				home := t.TempDir()
				t.Setenv("HOME", home)
				t.Setenv("USERPROFILE", home)
				return home + "/Documents/file.txt"
			},
			check: func(t *testing.T, result string) {
				if !strings.HasPrefix(result, "~/") {
					t.Errorf("Expected path to start with ~/, got %q", result)
				}
				if !strings.HasSuffix(result, "Documents/file.txt") {
					t.Errorf("Expected path to end with Documents/file.txt, got %q", result)
				}
			},
		},
		{
			name: "Keep absolute path outside home",
			setup: func() string {
				home := t.TempDir()
				t.Setenv("HOME", home)
				t.Setenv("USERPROFILE", home)
				return home + "2/system.log"
			},
			check: func(t *testing.T, result string) {
				if strings.HasPrefix(result, "~") {
					t.Errorf("Expected unchanged path, got %q", result)
				}
			},
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			path := tt.setup()
			result := displayPath(path)
			tt.check(t, result)
		})
	}
}

func TestPadName(t *testing.T) {
	tests := []struct {
		name        string
		input       string
		targetWidth int
		wantWidth   int
	}{
		{"Pad ASCII", "test", 10, 10},
		{"No padding needed", "longname", 5, 8},
		{"Pad CJK", "中文", 10, 10},
		{"Mixed CJK and ASCII", "hello世", 15, 15},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := padName(tt.input, tt.targetWidth)
			gotWidth := displayWidth(result)
			if gotWidth < tt.wantWidth && displayWidth(tt.input) < tt.targetWidth {
				t.Errorf("padName(%q, %d) width = %d, want >= %d", tt.input, tt.targetWidth, gotWidth, tt.wantWidth)
			}
		})
	}
}

func TestCalculateNameWidth(t *testing.T) {
	tests := []struct {
		termWidth int
		wantMin   int
		wantMax   int
	}{
		{80, 19, 60},  // 80 - 61 = 19
		{120, 59, 60}, // 120 - 61 = 59
		{200, 60, 60}, // Capped at 60
		{70, 24, 60},  // Below minimum, use 24
		{50, 13, 13},  // Bar disappears before names lose their remaining space
	}

	for _, tt := range tests {
		got := calculateNameWidth(tt.termWidth)
		if got < tt.wantMin || got > tt.wantMax {
			t.Errorf("calculateNameWidth(%d) = %d, want between %d and %d",
				tt.termWidth, got, tt.wantMin, tt.wantMax)
		}
	}
}

func TestFormatUnusedTime(t *testing.T) {
	now := time.Now().UTC()
	tests := []struct {
		name    string
		daysAgo int
		want    string
	}{
		{"zero time", -1, ""},            // Special case: will use time.Time{}
		{"recent file", 30, ""},          // < 90 days returns empty
		{"just under threshold", 89, ""}, // Boundary: 89 days still empty
		{"at 90 days", 90, ">3mo"},       // Boundary: exactly 90 days
		{"4 months", 120, ">4mo"},
		{"6 months", 180, ">6mo"},
		{"11 months", 330, ">11mo"},
		{"just under 1 year", 364, ">12mo"},
		{"exactly 1 year", 365, ">1yr"},
		{"18 months", 548, ">1yr"}, // Between 1 and 2 years
		{"just under 2 years", 729, ">1yr"},
		{"exactly 2 years", 730, ">2yr"},
		{"3 years", 1095, ">3yr"},
	}

	tracked := lastAccessTracked
	lastAccessTracked = func() bool { return true }
	t.Cleanup(func() { lastAccessTracked = tracked })

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			var lastAccess time.Time
			if tt.daysAgo >= 0 {
				// Use a fixed UTC baseline to avoid DST-related flakiness.
				lastAccess = now.Add(-time.Duration(tt.daysAgo) * 24 * time.Hour)
			}
			// If daysAgo < 0, lastAccess remains zero value

			got := formatUnusedTime(lastAccess)
			if got != tt.want {
				t.Errorf("formatUnusedTime(%d days ago) = %q, want %q", tt.daysAgo, got, tt.want)
			}
		})
	}
}

func TestFormatUnusedTimeClaimsNothingWithoutAccessTimes(t *testing.T) {
	tracked := lastAccessTracked
	lastAccessTracked = func() bool { return false }
	t.Cleanup(func() { lastAccessTracked = tracked })

	if got := formatUnusedTime(time.Now().Add(-3 * 365 * 24 * time.Hour)); got != "" {
		t.Errorf("formatUnusedTime without access times = %q, want empty", got)
	}
}

func TestAccessTrackedFromReadsBitZero(t *testing.T) {
	for value, want := range map[uint64]bool{
		0: true, 0x80000000: true, 0x80000002: true,
		1: false, 0x80000001: false, 0x80000003: false,
	} {
		if got := accessTrackedFrom(value); got != want {
			t.Errorf("accessTrackedFrom(%#x) = %v, want %v", value, got, want)
		}
	}
}

func TestUnicodeColumnsPreserveGraphemes(t *testing.T) {
	for _, tt := range []struct {
		name  string
		width int
	}{
		{"微信输入法", 10}, {"资料、备份", 10}, {"Cafe\u0301", 4}, {"ｶﾀｶﾅ", 4}, {"👨‍👩‍👧‍👦", 2},
	} {
		if got := displayWidth(tt.name); got != tt.width {
			t.Errorf("%q width=%d want %d", tt.name, got, tt.width)
		}
		if got := lipgloss.Width(padName(tt.name, 24)); got != 24 {
			t.Errorf("%q padded width=%d", tt.name, got)
		}
	}
	if got := truncateMiddle("👨‍👩‍👧‍👦abc", 2); got != "👨‍👩‍👧‍👦" {
		t.Errorf("split grapheme=%q", got)
	}
}

func TestTruncateMiddleNeverExceedsTheColumnBudget(t *testing.T) {
	// A wide grapheme at the tail cut used to leave the name one cell too wide,
	// which pushed the size column on CJK and flag names.
	names := []string{
		"🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵🇯🇵",
		"资料备份资料备份资料备份资料备份",
		"abc资料备份def资料备份ghi资料",
		"report-2023-final-version-archive.tar.gz",
	}
	for _, name := range names {
		for budget := 1; budget <= 24; budget++ {
			if got := truncateMiddle(name, budget); displayWidth(got) > budget {
				t.Errorf("truncateMiddle(%q, %d) = %q is %d cells", name, budget, got, displayWidth(got))
			}
		}
	}
}
