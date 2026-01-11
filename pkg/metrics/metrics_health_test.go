package metrics

import (
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
	if got := formatUptime(65); got != "1m" {
		t.Fatalf("expected 1m, got %s", got)
	}
	if got := formatUptime(3600 + 120); got != "1h 2m" {
		t.Fatalf("expected \"1h 2m\", got %s", got)
	}
	if got := formatUptime(86400*2 + 3600*3 + 60*5); got != "2d 3h 5m" {
		t.Fatalf("expected \"2d 3h 5m\", got %s", got)
	}
}
