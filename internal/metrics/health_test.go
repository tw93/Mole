package metrics

import (
	"strings"
	"testing"
)

func TestCalculateHealthScorePerfect(t *testing.T) {
	score, msg := CalculateHealthScore(
		CPUStatus{Usage: 10},
		MemoryStatus{UsedPercent: 20, Pressure: "normal"},
		[]DiskStatus{{UsedPercent: 30}},
		DiskIOStatus{ReadRate: 5, WriteRate: 5},
		ThermalStatus{CPUTemp: 40},
	)

	if score != 100 {
		t.Fatalf("expected perfect score 100, got %d", score)
	}
	if msg != "Excellent" {
		t.Fatalf("unexpected message %q", msg)
	}
}

func TestCalculateHealthScoreDetectsIssues(t *testing.T) {
	score, msg := CalculateHealthScore(
		CPUStatus{Usage: 95},
		MemoryStatus{UsedPercent: 90, Pressure: "critical"},
		[]DiskStatus{{UsedPercent: 95}},
		DiskIOStatus{ReadRate: 120, WriteRate: 80},
		ThermalStatus{CPUTemp: 90},
	)

	if score >= 40 {
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

func TestFormatUptime(t *testing.T) {
	if got := FormatUptime(65); got != "1m" {
		t.Fatalf("expected 1m, got %s", got)
	}
	if got := FormatUptime(3600 + 120); got != "1h 2m" {
		t.Fatalf("expected \"1h 2m\", got %s", got)
	}
	if got := FormatUptime(86400*2 + 3600*3 + 60*5); got != "2d 3h" {
		t.Fatalf("expected \"2d 3h\", got %s", got)
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
			cpu:     CPUStatus{Usage: 30.0},
			mem:     MemoryStatus{UsedPercent: 50.0},
			disks:   []DiskStatus{{UsedPercent: 70.0}},
			diskIO:  DiskIOStatus{ReadRate: 25.0, WriteRate: 25.0},
			thermal: ThermalStatus{CPUTemp: 60.0},
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
			score, _ := CalculateHealthScore(tt.cpu, tt.mem, tt.disks, tt.diskIO, tt.thermal)
			if score < tt.wantMin || score > tt.wantMax {
				t.Errorf("CalculateHealthScore() = %d, want range [%d, %d]", score, tt.wantMin, tt.wantMax)
			}
		})
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
			got := FormatUptime(tt.secs)
			if got != tt.want {
				t.Errorf("FormatUptime(%d) = %q, want %q", tt.secs, got, tt.want)
			}
		})
	}
}
