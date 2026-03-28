package main

import "testing"

func TestStatusString(t *testing.T) {
	tests := []struct {
		name   string
		status checkStatus
		want   string
	}{
		{"pass", statusPass, "pass"},
		{"warn", statusWarn, "warn"},
		{"fail", statusFail, "fail"},
		{"skipped", statusSkipped, "skipped"},
		{"unknown", checkStatus(99), "unknown"},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := statusString(tt.status)
			if got != tt.want {
				t.Errorf("statusString(%d) = %q, want %q", tt.status, got, tt.want)
			}
		})
	}
}
