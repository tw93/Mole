package main

import "testing"

func TestParseVMStatValue(t *testing.T) {
	tests := []struct {
		name string
		line string
		want int64
	}{
		{"standard line", "Pages free:                             123456.", 123456},
		{"with spaces", "Pages inactive:    789012.", 789012},
		{"no trailing dot", "Pages free: 100", 100},
		{"empty value", "Pages free:", 0},
		{"no colon", "Pages free", 0},
		{"zero value", "Pages free:                             0.", 0},
		{"large value", "Pages wired down:                       1234567890.", 1234567890},
		{"empty line", "", 0},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseVMStatValue(tt.line)
			if got != tt.want {
				t.Errorf("parseVMStatValue(%q) = %d, want %d", tt.line, got, tt.want)
			}
		})
	}
}
