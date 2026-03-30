//go:build darwin

package main

import (
	"context"
	"sync"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// diagCtx holds the cancellable context for the current diagnosis run.
// Cancelled when the user quits the TUI during a running diagnosis.
var diagCtx context.Context
var diagCancel context.CancelFunc

func runAllChecks(_ bool) diagnosisResult {
	var hardware hardwareProfile
	var wg sync.WaitGroup

	// Collect hardware in parallel with category checks.
	wg.Add(1)
	go func() {
		defer wg.Done()
		hardware = collectHardware()
	}()

	// Run all category checks in parallel.
	type indexedResult struct {
		index  int
		result categoryResult
	}
	checks := []func() categoryResult{
		checkStorage,
		checkPerformance,
		checkBattery,
		checkSecurity,
		checkMaintenance,
		checkDevEnvironment,
		checkMole,
	}
	ch := make(chan indexedResult, len(checks))
	for i, fn := range checks {
		wg.Add(1)
		go func(idx int, f func() categoryResult) {
			defer wg.Done()
			ch <- indexedResult{index: idx, result: f()}
		}(i, fn)
	}

	wg.Wait()
	close(ch)

	categories := make([]categoryResult, len(checks))
	for r := range ch {
		categories[r.index] = r.result
	}

	categories = redistributeBatteryScore(categories)
	totalScore, maxScore := calculateTotalScore(categories)
	tips := generateTips(categories)

	return diagnosisResult{
		Hardware:   hardware,
		Categories: categories,
		TotalScore: totalScore,
		MaxScore:   maxScore,
		Tips:       tips,
	}
}

func runDiagnosis(sudo bool) tea.Cmd {
	return func() tea.Msg {
		diagCtx, diagCancel = context.WithCancel(context.Background())
		result := runAllChecks(sudo)
		return diagnosisDoneMsg{result: result}
	}
}

func tickSpinner() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(t time.Time) tea.Msg {
		return tickMsg{}
	})
}
