package main

import "testing"

func TestParseSystemProfilerValue(t *testing.T) {
	input := `Hardware:

    Hardware Overview:

      Model Name: MacBook Pro
      Model Identifier: Mac16,8
      Chip: Apple M4 Pro
      Total Number of Cores: 12 (8 performance and 4 efficiency)
      Memory: 24 GB
      System Firmware Version: 11881.101.1
      OS Loader Version: 11881.101.1
`

	tests := []struct {
		key  string
		want string
	}{
		{"Model Name", "MacBook Pro"},
		{"Chip", "Apple M4 Pro"},
		{"Model Identifier", "Mac16,8"},
		{"Memory", "24 GB"},
		{"Nonexistent", ""},
	}

	for _, tt := range tests {
		t.Run(tt.key, func(t *testing.T) {
			got := parseSystemProfilerValue(input, tt.key)
			if got != tt.want {
				t.Errorf("parseSystemProfilerValue(%q) = %q, want %q", tt.key, got, tt.want)
			}
		})
	}
}

func TestParseThermalOK(t *testing.T) {
	tests := []struct {
		name   string
		output string
		want   bool
	}{
		{"no throttling", "Note: No thermal warning level has been recorded\n", true},
		{"has throttling", "2026-03-28 10:00:00 -0700 CPU Speed Limit: 70\n", false},
		{"empty", "", true},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := parseThermalOK(tt.output)
			if got != tt.want {
				t.Errorf("parseThermalOK() = %v, want %v", got, tt.want)
			}
		})
	}
}
