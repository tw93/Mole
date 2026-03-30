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
				{Name: "Storage", Score: 15, MaxScore: 15},
				{Name: "Performance", Score: 20, MaxScore: 20},
				{Name: "Battery", Score: 15, MaxScore: 15},
				{Name: "Security", Score: 15, MaxScore: 15},
				{Name: "Maintenance", Score: 15, MaxScore: 15},
				{Name: "Dev Environment", Score: 15, MaxScore: 15},
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
		{Name: "Storage", Score: 15, MaxScore: 15},
		{Name: "Performance", Score: 20, MaxScore: 20},
		{Name: "Battery", Score: 0, MaxScore: 0},
		{Name: "Security", Score: 15, MaxScore: 15},
		{Name: "Maintenance", Score: 15, MaxScore: 15},
		{Name: "Dev Environment", Score: 15, MaxScore: 15},
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
		{Name: "Storage", Score: 8, MaxScore: 15},          // ~53%
		{Name: "Performance", Score: 20, MaxScore: 20},     // 100%
		{Name: "Battery", Score: 0, MaxScore: 0},           // skipped
		{Name: "Security", Score: 11, MaxScore: 15},        // ~73%
		{Name: "Maintenance", Score: 15, MaxScore: 15},     // 100%
		{Name: "Dev Environment", Score: 10, MaxScore: 15}, // ~67%
		{Name: "Mole", Score: 5, MaxScore: 5},              // 100%
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
		{Name: "Storage", Score: 5, MaxScore: 15, Checks: []checkResult{
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
		{Name: "Security", Score: 5, MaxScore: 15, Checks: []checkResult{
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
		{Name: "Battery", Score: 15, MaxScore: 15, Checks: []checkResult{
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

func TestGenerateTips_DevEnvironment(t *testing.T) {
	categories := []categoryResult{
		{Name: "Dev Environment", Score: 5, MaxScore: 15, Checks: []checkResult{
			{Name: "Common tools", Status: statusWarn, Detail: "Missing: docker, go"},
			{Name: "IDE extensions", Status: statusWarn, Detail: "2 duplicates: publisher.ext, other.ext"},
		}},
	}

	tips := generateTips(categories)
	if len(tips) != 2 {
		t.Errorf("generateTips() = %d tips, want 2: %v", len(tips), tips)
	}
	foundTools, foundIDE := false, false
	for _, tip := range tips {
		if tip == "Missing: docker, go" {
			foundTools = true
		}
		if tip == "Remove duplicate IDE extensions to save disk and avoid conflicts" {
			foundIDE = true
		}
	}
	if !foundTools {
		t.Error("missing tools tip")
	}
	if !foundIDE {
		t.Error("missing IDE tip")
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

func TestBuildCategory(t *testing.T) {
	tests := []struct {
		name           string
		categoryName   string
		maxScore       int
		checks         []checkResult
		wantScore      int
		wantMaxScore   int
		wantCheckCount int
	}{
		{
			name:           "empty checks",
			categoryName:   "Storage",
			maxScore:       20,
			checks:         []checkResult{},
			wantScore:      0,
			wantMaxScore:   20,
			wantCheckCount: 0,
		},
		{
			name:         "single check full score",
			categoryName: "Performance",
			maxScore:     15,
			checks: []checkResult{
				{Name: "Uptime", Score: 8, MaxScore: 8, Status: statusPass},
			},
			wantScore:      8,
			wantMaxScore:   15,
			wantCheckCount: 1,
		},
		{
			name:         "multiple checks sum correctly",
			categoryName: "Security",
			maxScore:     15,
			checks: []checkResult{
				{Name: "FileVault", Score: 4, MaxScore: 4, Status: statusPass},
				{Name: "Firewall", Score: 4, MaxScore: 4, Status: statusPass},
				{Name: "SIP", Score: 3, MaxScore: 4, Status: statusWarn},
			},
			wantScore:      11,
			wantMaxScore:   15,
			wantCheckCount: 3,
		},
		{
			name:         "score capped at maxScore",
			categoryName: "Test",
			maxScore:     10,
			checks: []checkResult{
				{Name: "Check1", Score: 7, MaxScore: 10, Status: statusPass},
				{Name: "Check2", Score: 5, MaxScore: 10, Status: statusPass},
				{Name: "Check3", Score: 3, MaxScore: 10, Status: statusPass},
			},
			wantScore:      10, // capped at maxScore of 10
			wantMaxScore:   10,
			wantCheckCount: 3,
		},
		{
			name:         "partial scores",
			categoryName: "Battery",
			maxScore:     10,
			checks: []checkResult{
				{Name: "Cycles", Score: 5, MaxScore: 8, Status: statusWarn},
				{Name: "Health", Score: 2, MaxScore: 2, Status: statusFail},
			},
			wantScore:      7,
			wantMaxScore:   10,
			wantCheckCount: 2,
		},
		{
			name:         "zero scores",
			categoryName: "Test",
			maxScore:     15,
			checks: []checkResult{
				{Name: "Check1", Score: 0, MaxScore: 5, Status: statusFail},
				{Name: "Check2", Score: 0, MaxScore: 5, Status: statusFail},
			},
			wantScore:      0,
			wantMaxScore:   15,
			wantCheckCount: 2,
		},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			result := buildCategory(tt.categoryName, tt.maxScore, tt.checks)

			if result.Name != tt.categoryName {
				t.Errorf("buildCategory() name = %q, want %q", result.Name, tt.categoryName)
			}
			if result.MaxScore != tt.wantMaxScore {
				t.Errorf("buildCategory() maxScore = %d, want %d", result.MaxScore, tt.wantMaxScore)
			}
			if result.Score != tt.wantScore {
				t.Errorf("buildCategory() score = %d, want %d", result.Score, tt.wantScore)
			}
			if len(result.Checks) != tt.wantCheckCount {
				t.Errorf("buildCategory() checks count = %d, want %d", len(result.Checks), tt.wantCheckCount)
			}
		})
	}
}
