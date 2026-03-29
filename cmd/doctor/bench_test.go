//go:build darwin

package main

import (
	"fmt"
	"testing"
	"time"
)

func TestBenchRunAllChecks(t *testing.T) {
	start := time.Now()
	result := runAllChecks(false)
	elapsed := time.Since(start)

	fmt.Printf("\n=== Doctor completed in %s ===\n", elapsed)
	fmt.Printf("Hardware: %s · %s · %s\n", result.Hardware.Model, result.Hardware.Chip, result.Hardware.RAM)
	for _, c := range result.Categories {
		fmt.Printf("  %s: %d/%d\n", c.Name, c.Score, c.MaxScore)
	}
	fmt.Printf("Total: %d/%d\n", result.TotalScore, result.MaxScore)

	if elapsed > 8*time.Second {
		t.Errorf("runAllChecks took %s, want < 8s", elapsed)
	}
}
