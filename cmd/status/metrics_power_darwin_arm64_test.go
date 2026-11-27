package main

import (
	"math"
	"testing"
)

func TestDesktopSMCWatts(t *testing.T) {
	for _, tc := range []struct {
		name                     string
		total, volts, amps, want float64
	}{
		{"system total wins", 38.75, 12, 4, 38.75},
		{"DC input when total is zero", 0, 12.05, 1.468, 17.6894},
		{"missing current", 0, 12.05, 0, 0},
		{"invalid signs", 0, -12, -3, 0},
		{"invalid total and excessive input", math.NaN(), 12, 100, 0},
		{"invalid current", 0, 12, math.Inf(1), 0},
	} {
		t.Run(tc.name, func(t *testing.T) {
			keys := map[string]float64{"PSTR": tc.total, "VD0R": tc.volts, "ID0R": tc.amps}
			got := desktopSMCWatts(func(key string) float64 { return keys[key] })
			if math.IsNaN(got) || math.Abs(got-tc.want) > 1e-6 {
				t.Errorf("got %v W, want %v W", got, tc.want)
			}
		})
	}
}
