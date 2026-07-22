//go:build !darwin || !cgo

package main

import "time"

// readGPUPowerWatts is unavailable off Apple Silicon (or when cgo is disabled):
// GPU power comes from the private IOReport framework, which only exists on
// macOS and needs cgo. The status card hides the row when this returns -1.
func readGPUPowerWatts(window time.Duration) float64 {
	return -1
}
