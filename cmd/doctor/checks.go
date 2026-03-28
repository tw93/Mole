//go:build darwin

package main

import (
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

func runAllChecks(_ bool) diagnosisResult {
	categories := []categoryResult{
		checkStorage(),
		checkPerformance(),
		checkBattery(),
		checkSecurity(),
		checkMaintenance(),
		checkMole(),
	}

	categories = redistributeBatteryScore(categories)
	totalScore, maxScore := calculateTotalScore(categories)
	tips := generateTips(categories)

	return diagnosisResult{
		Categories: categories,
		TotalScore: totalScore,
		MaxScore:   maxScore,
		Tips:       tips,
	}
}

func runDiagnosis(sudo bool) tea.Cmd {
	return func() tea.Msg {
		result := runAllChecks(sudo)
		return diagnosisDoneMsg{result: result}
	}
}

func tickSpinner() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(t time.Time) tea.Msg {
		return tickMsg{}
	})
}
