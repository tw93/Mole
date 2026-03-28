package main

import (
	"testing"
)

func TestCalculateTotalScore(t *testing.T) {
	tests := []struct {
		name       string
		categories []categoryResult
		wantTotal  int
		wantMax    int
	}{
		{
			name:       "empty",
			categories: []categoryResult{},
			wantTotal:  0,
			wantMax:    0,
		},
		{
			name: "single category",
			categories: []categoryResult{
				{Name: "Storage", Score: 15, MaxScore: 20},
			},
			wantTotal: 15,
			wantMax:   20,
		},
		{
			name: "all categories perfect",
			categories: []categoryResult{
				{Name: "Storage", Score: 20, MaxScore: 20},
				{Name: "Performance", Score: 20, MaxScore: 20},
				{Name: "Battery", Score: 20, MaxScore: 20},
				{Name: "Security", Score: 20, MaxScore: 20},
				{Name: "Maintenance", Score: 15, MaxScore: 15},
				{Name: "Mole", Score: 5, MaxScore: 5},
			},
			wantTotal: 100,
			wantMax:   100,
		},
		{
			name: "mixed scores",
			categories: []categoryResult{
				{Name: "Storage", Score: 10, MaxScore: 20},
				{Name: "Performance", Score: 18, MaxScore: 20},
			},
			wantTotal: 28,
			wantMax:   40,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			total, max := calculateTotalScore(tt.categories)
			if total != tt.wantTotal {
				t.Errorf("calculateTotalScore() total = %d, want %d", total, tt.wantTotal)
			}
			if max != tt.wantMax {
				t.Errorf("calculateTotalScore() max = %d, want %d", max, tt.wantMax)
			}
		})
	}
}

func TestRedistributeBatteryScore_WithBattery(t *testing.T) {
	categories := []categoryResult{
		{Name: "Storage", Score: 15, MaxScore: 20},
		{Name: "Battery", Score: 10, MaxScore: 20},
	}

	result := redistributeBatteryScore(categories)
	if len(result) != 2 {
		t.Fatalf("expected 2 categories, got %d", len(result))
	}
	// With battery present, no redistribution should happen.
	if result[0].MaxScore != 20 {
		t.Errorf("Storage MaxScore = %d, want 20 (no redistribution)", result[0].MaxScore)
	}
}

func TestRedistributeBatteryScore_NoBattery(t *testing.T) {
	categories := []categoryResult{
		{Name: "Storage", Score: 20, MaxScore: 20},
		{Name: "Performance", Score: 20, MaxScore: 20},
		{Name: "Battery", Score: 0, MaxScore: 0},
		{Name: "Security", Score: 20, MaxScore: 20},
		{Name: "Maintenance", Score: 15, MaxScore: 15},
		{Name: "Mole", Score: 5, MaxScore: 5},
	}

	result := redistributeBatteryScore(categories)

	// Battery should be removed.
	for _, c := range result {
		if c.Name == "Battery" {
			t.Fatal("Battery category should be removed when MaxScore=0")
		}
	}

	// Total MaxScore should still be 100.
	totalMax := 0
	for _, c := range result {
		totalMax += c.MaxScore
	}
	if totalMax != 100 {
		t.Errorf("total MaxScore after redistribution = %d, want 100", totalMax)
	}
}

func TestRedistributeBatteryScore_ScoresProportional(t *testing.T) {
	categories := []categoryResult{
		{Name: "Storage", Score: 10, MaxScore: 20},       // 50%
		{Name: "Performance", Score: 20, MaxScore: 20},    // 100%
		{Name: "Battery", Score: 0, MaxScore: 0},          // skipped
		{Name: "Security", Score: 15, MaxScore: 20},       // 75%
		{Name: "Maintenance", Score: 15, MaxScore: 15},    // 100%
		{Name: "Mole", Score: 5, MaxScore: 5},             // 100%
	}

	result := redistributeBatteryScore(categories)

	for _, c := range result {
		if c.Score > c.MaxScore {
			t.Errorf("%s: Score %d exceeds MaxScore %d", c.Name, c.Score, c.MaxScore)
		}
		if c.Score < 0 {
			t.Errorf("%s: Score %d is negative", c.Name, c.Score)
		}
	}
}

func TestGenerateTips_AllGood(t *testing.T) {
	categories := []categoryResult{
		{Name: "Storage", Score: 20, MaxScore: 20, Checks: []checkResult{
			{Name: "Free space", Status: statusPass},
		}},
		{Name: "Performance", Score: 20, MaxScore: 20, Checks: []checkResult{
			{Name: "RAM usage", Status: statusPass},
		}},
	}

	tips := generateTips(categories)
	if len(tips) != 1 || tips[0] != "Your Mac is in great shape!" {
		t.Errorf("generateTips() = %v, want [\"Your Mac is in great shape!\"]", tips)
	}
}

func TestGenerateTips_StorageCache(t *testing.T) {
	categories := []categoryResult{
		{Name: "Storage", Score: 10, MaxScore: 20, Checks: []checkResult{
			{Name: "Free space", Status: statusPass},
			{Name: "Recoverable cache", Status: statusWarn},
		}},
	}

	tips := generateTips(categories)
	found := false
	for _, tip := range tips {
		if tip == "Run 'mo clean' to reclaim cache space" {
			found = true
		}
	}
	if !found {
		t.Errorf("generateTips() should include cache tip, got %v", tips)
	}
}

func TestGenerateTips_HeavyProcesses(t *testing.T) {
	categories := []categoryResult{
		{Name: "Maintenance", Score: 5, MaxScore: 15, Checks: []checkResult{
			{Name: "Broken launch agents", Status: statusPass},
			{Name: "Heavy processes", Status: statusWarn},
		}},
	}

	tips := generateTips(categories)
	found := false
	for _, tip := range tips {
		if tip == "Close heavy background processes to improve performance" {
			found = true
		}
	}
	if !found {
		t.Errorf("generateTips() should include heavy processes tip, got %v", tips)
	}
}

func TestGenerateTips_SecurityAggregated(t *testing.T) {
	categories := []categoryResult{
		{Name: "Security", Score: 5, MaxScore: 20, Checks: []checkResult{
			{Name: "FileVault", Status: statusFail},
			{Name: "Firewall", Status: statusFail},
			{Name: "SIP", Status: statusPass},
		}},
	}

	tips := generateTips(categories)
	// Should be a single aggregated tip, not one per check.
	secTips := 0
	for _, tip := range tips {
		if len(tip) > 0 {
			secTips++
		}
	}
	if secTips != 1 {
		t.Errorf("generateTips() should produce 1 aggregated security tip, got %d tips: %v", secTips, tips)
	}
}

func TestGenerateTips_BatteryOnlyWhenFailing(t *testing.T) {
	// Battery all pass, ratio >= 0.8 → no tip.
	categories := []categoryResult{
		{Name: "Battery", Score: 20, MaxScore: 20, Checks: []checkResult{
			{Name: "Cycle count", Status: statusPass},
			{Name: "Health", Status: statusPass},
		}},
	}

	tips := generateTips(categories)
	for _, tip := range tips {
		if tip == "Battery health is low — consider Apple service" {
			t.Error("generateTips() should not show battery tip when battery is healthy")
		}
	}
}

func TestGenerateTips_SkippedCategoryIgnored(t *testing.T) {
	categories := []categoryResult{
		{Name: "Battery", Score: 0, MaxScore: 0, Checks: []checkResult{
			{Name: "Battery", Status: statusSkipped},
		}},
	}

	tips := generateTips(categories)
	if len(tips) != 1 || tips[0] != "Your Mac is in great shape!" {
		t.Errorf("generateTips() should ignore skipped categories, got %v", tips)
	}
}
