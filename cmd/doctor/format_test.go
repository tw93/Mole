package main

import (
	"strings"
	"testing"
)

func TestHumanizeBytes(t *testing.T) {
	tests := []struct {
		name  string
		input int64
		want  string
	}{
		{"zero", 0, "0 B"},
		{"one byte", 1, "1 B"},
		{"999 bytes", 999, "999 B"},
		{"exactly 1KB", 1024, "1.0 KB"},
		{"1.5KB", 1536, "1.5 KB"},
		{"exactly 1MB", 1024 * 1024, "1.0 MB"},
		{"500MB", 500 * 1024 * 1024, "500.0 MB"},
		{"exactly 1GB", 1024 * 1024 * 1024, "1.0 GB"},
		{"exactly 1TB", 1024 * 1024 * 1024 * 1024, "1.0 TB"},
		{"negative", -1, "-1 B"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := humanizeBytes(tt.input)
			if got != tt.want {
				t.Errorf("humanizeBytes(%d) = %q, want %q", tt.input, got, tt.want)
			}
		})
	}
}

func TestProgressBar(t *testing.T) {
	tests := []struct {
		name     string
		score    int
		maxScore int
		width    int
	}{
		{"zero score", 0, 100, 20},
		{"full score", 100, 100, 20},
		{"half score", 50, 100, 20},
		{"max zero returns empty bar", 0, 0, 20},
		{"score exceeds max clamped", 120, 100, 20},
		{"width 1", 50, 100, 1},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := progressBar(tt.score, tt.maxScore, tt.width)
			if got == "" {
				t.Errorf("progressBar(%d, %d, %d) returned empty string", tt.score, tt.maxScore, tt.width)
			}
		})
	}
}

func TestProgressBarMaxZeroAllEmpty(t *testing.T) {
	got := progressBar(0, 0, 10)
	clean := stripANSI(got)
	if len([]rune(clean)) != 10 {
		t.Errorf("progressBar(0,0,10) rune count = %d, want 10", len([]rune(clean)))
	}
	if !strings.Contains(clean, "░") {
		t.Error("progressBar(0,0,10) should be all empty blocks")
	}
}

func TestProgressBarColorThresholds(t *testing.T) {
	low := progressBar(50, 100, 20)    // 50% → red
	mid := progressBar(70, 100, 20)    // 70% → yellow
	high := progressBar(90, 100, 20)   // 90% → green

	if low == mid || mid == high {
		t.Error("progressBar should use different colors for different score ranges")
	}
}

func TestStatusIcon(t *testing.T) {
	tests := []struct {
		name   string
		status checkStatus
		want   string
	}{
		{"pass", statusPass, "✓"},
		{"warn", statusWarn, "⚠"},
		{"fail", statusFail, "✗"},
		{"skipped", statusSkipped, "–"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := statusIcon(tt.status)
			if !strings.Contains(got, tt.want) {
				t.Errorf("statusIcon(%d) = %q, should contain %q", tt.status, got, tt.want)
			}
		})
	}
}

func TestCategoryIcon(t *testing.T) {
	tests := []struct {
		name     string
		score    int
		maxScore int
		want     string
	}{
		{"perfect", 20, 20, "✓"},
		{"good", 17, 20, "✓"},
		{"warning", 13, 20, "⚠"},
		{"fail", 10, 20, "✗"},
		{"zero max skipped", 0, 0, "–"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := categoryIcon(tt.score, tt.maxScore)
			if !strings.Contains(got, tt.want) {
				t.Errorf("categoryIcon(%d, %d) = %q, should contain %q", tt.score, tt.maxScore, got, tt.want)
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
