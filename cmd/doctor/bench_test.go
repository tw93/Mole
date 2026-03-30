//go:build darwin

package main

import (
	"fmt"
	"sync"
	"testing"
	"time"
)

func TestBenchRunAllChecks(t *testing.T) {
	start := time.Now()

	var hardware hardwareProfile
	var wg sync.WaitGroup

	wg.Add(1)
	go func() {
		defer wg.Done()
		hardware = collectHardware()
	}()

	type indexedResult struct {
		index  int
		result categoryResult
	}
	ch := make(chan indexedResult, len(categorySpecs))
	for i, spec := range categorySpecs {
		wg.Add(1)
		go func(idx int, fn func() categoryResult) {
			defer wg.Done()
			ch <- indexedResult{index: idx, result: fn()}
		}(i, spec.fn)
	}

	wg.Wait()
	close(ch)

	categories := make([]categoryResult, len(categorySpecs))
	for r := range ch {
		categories[r.index] = r.result
	}

	categories = redistributeBatteryScore(categories)
	totalScore, maxScore := calculateTotalScore(categories)

	elapsed := time.Since(start)

	fmt.Printf("\n=== Doctor completed in %s ===\n", elapsed)
	fmt.Printf("Hardware: %s · %s · %s\n", hardware.Model, hardware.Chip, hardware.RAM)
	for _, c := range categories {
		fmt.Printf("  %s: %d/%d\n", c.Name, c.Score, c.MaxScore)
	}
	fmt.Printf("Total: %d/%d\n", totalScore, maxScore)

	if elapsed > 45*time.Second {
		t.Errorf("checks took %s, want < 45s", elapsed)
	}
}
