package main

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

var (
	// Cache for heavy system_profiler output.
	lastPowerAt   time.Time
	cachedPower   string
	powerCacheTTL = 30 * time.Second
)

func collectBatteries() (batts []BatteryStatus, err error) {
	defer func() {
		if r := recover(); r != nil {
			// Swallow panics to keep UI alive.
			err = fmt.Errorf("battery collection failed: %v", r)
		}
	}()

	// macOS: pmset for real-time percentage/status.
	if runtime.GOOS == "darwin" && commandExists("pmset") {
		if out, err := runCmd(context.Background(), "pmset", "-g", "batt"); err == nil {
			// Health/cycles/capacity from cached system_profiler.
			health, cycles, capacity := getCachedPowerData()
			if batts := parsePMSet(out, health, cycles, capacity); len(batts) > 0 {
				return batts, nil
			}
		}
	}

	// Linux: /sys/class/power_supply.
	matches, _ := filepath.Glob("/sys/class/power_supply/BAT*/capacity")
	for _, capFile := range matches {
		statusFile := filepath.Join(filepath.Dir(capFile), "status")
		capData, err := os.ReadFile(capFile)
		if err != nil {
			continue
		}
		statusData, _ := os.ReadFile(statusFile)
		percentStr := strings.TrimSpace(string(capData))
		percent, _ := strconv.ParseFloat(percentStr, 64)
		status := strings.TrimSpace(string(statusData))
		if status == "" {
			status = "Unknown"
		}
		batts = append(batts, BatteryStatus{
			Percent: percent,
			Status:  status,
		})
	}
	if len(batts) > 0 {
		return batts, nil
	}

	return nil, errors.New("no battery data found")
}

func parsePMSet(raw string, health string, cycles int, capacity int) []BatteryStatus {
	var out []BatteryStatus
	var timeLeft string

	for line := range strings.Lines(raw) {
		// Time remaining.
		if strings.Contains(line, "remaining") {
			parts := strings.Fields(line)
			for i, p := range parts {
				if p == "remaining" && i > 0 {
					timeLeft = parts[i-1]
				}
			}
		}

		if !strings.Contains(line, "%") {
			continue
		}
		fields := strings.Fields(line)
		var (
			percent float64
			found   bool
			status  = "Unknown"
		)
		for i, f := range fields {
			if strings.Contains(f, "%") {
				value := strings.TrimSuffix(strings.TrimSuffix(f, ";"), "%")
				if p, err := strconv.ParseFloat(value, 64); err == nil {
					percent = p
					found = true
					if i+1 < len(fields) {
						status = strings.TrimSuffix(fields[i+1], ";")
					}
				}
				break
			}
		}
		if !found {
			continue
		}

		out = append(out, BatteryStatus{
			Percent:    percent,
			Status:     status,
			TimeLeft:   timeLeft,
			Health:     health,
			CycleCount: cycles,
			Capacity:   capacity,
		})
	}
	return out
}

// getCachedPowerData returns condition, cycles, and capacity from cached system_profiler.
func getCachedPowerData() (health string, cycles int, capacity int) {
	out := getSystemPowerOutput()
	if out == "" {
		return "", 0, 0
	}

	for line := range strings.Lines(out) {
		lower := strings.ToLower(line)
		if strings.Contains(lower, "cycle count") {
			if _, after, found := strings.Cut(line, ":"); found {
				cycles, _ = strconv.Atoi(strings.TrimSpace(after))
			}
		}
		if strings.Contains(lower, "condition") {
			if _, after, found := strings.Cut(line, ":"); found {
				health = strings.TrimSpace(after)
			}
		}
		if strings.Contains(lower, "maximum capacity") {
			if _, after, found := strings.Cut(line, ":"); found {
				capacityStr := strings.TrimSpace(after)
				capacityStr = strings.TrimSuffix(capacityStr, "%")
				capacity, _ = strconv.Atoi(strings.TrimSpace(capacityStr))
			}
		}
	}
	return health, cycles, capacity
}

func getSystemPowerOutput() string {
	if runtime.GOOS != "darwin" {
		return ""
	}

	now := time.Now()
	if cachedPower != "" && now.Sub(lastPowerAt) < powerCacheTTL {
		return cachedPower
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	out, err := runCmd(ctx, "system_profiler", "SPPowerDataType")
	if err == nil {
		cachedPower = out
		lastPowerAt = now
	}
	return cachedPower
}

func collectThermal() ThermalStatus {
	if runtime.GOOS != "darwin" {
		return ThermalStatus{}
	}

	var thermal ThermalStatus

	// Fan info from cached system_profiler.
	out := getSystemPowerOutput()
	if out != "" {
		for line := range strings.Lines(out) {
			lower := strings.ToLower(line)
			if strings.Contains(lower, "fan") && strings.Contains(lower, "speed") {
				if _, after, found := strings.Cut(line, ":"); found {
					numStr := strings.TrimSpace(after)
					numStr, _, _ = strings.Cut(numStr, " ")
					thermal.FanSpeed, _ = strconv.Atoi(numStr)
				}
			}
		}
	}

	// Power metrics from ioreg (fast, real-time).
	ctxPower, cancelPower := context.WithTimeout(context.Background(), 500*time.Millisecond)
	defer cancelPower()
	if out, err := runCmd(ctxPower, "ioreg", "-rn", "AppleSmartBattery"); err == nil {
		powerThermal := parseAppleSmartBatteryThermal(out)
		thermal.BatteryTemp = powerThermal.BatteryTemp
		thermal.SystemPower = powerThermal.SystemPower
		thermal.AdapterPower = powerThermal.AdapterPower
		thermal.BatteryPower = powerThermal.BatteryPower
	}

	// Do not synthesize CPU temperature from battery sensors or cpu_thermal_level.
	// Those values are not CPU-package temperatures and produce false overheating data.
	return thermal
}

func parseAppleSmartBatteryThermal(out string) ThermalStatus {
	var thermal ThermalStatus

	for line := range strings.Lines(out) {
		line = strings.TrimSpace(line)

		// AppleSmartBattery reports battery temperature in centi-degrees Celsius.
		if _, after, found := strings.Cut(line, "\"Temperature\" = "); found {
			valStr := strings.TrimSpace(after)
			if tempRaw, err := strconv.Atoi(valStr); err == nil && tempRaw > 0 {
				thermal.BatteryTemp = float64(tempRaw) / 100.0
			}
		}

		// Adapter power (Watts) from current adapter.
		if strings.Contains(line, "\"AdapterDetails\" = {") && !strings.Contains(line, "AppleRaw") {
			if _, after, found := strings.Cut(line, "\"Watts\"="); found {
				valStr := strings.TrimSpace(after)
				valStr, _, _ = strings.Cut(valStr, ",")
				valStr, _, _ = strings.Cut(valStr, "}")
				valStr = strings.TrimSpace(valStr)
				if watts, err := strconv.ParseFloat(valStr, 64); err == nil && watts > 0 {
					thermal.AdapterPower = watts
				}
			}
		}

		// System power consumption (mW -> W).
		if _, after, found := strings.Cut(line, "\"SystemPowerIn\"="); found {
			valStr := strings.TrimSpace(after)
			valStr, _, _ = strings.Cut(valStr, ",")
			valStr, _, _ = strings.Cut(valStr, "}")
			valStr = strings.TrimSpace(valStr)
			if powerMW, err := strconv.ParseFloat(valStr, 64); err == nil {
				// SystemPower should always be positive, reject invalid values
				if powerMW >= 0 && powerMW < 1000000 { // 0 to 1000W
					thermal.SystemPower = powerMW / 1000.0
				}
			}
		}

		// Battery power (mW -> W, positive = discharging, negative = charging).
		if _, after, found := strings.Cut(line, "\"BatteryPower\"="); found {
			valStr := strings.TrimSpace(after)
			valStr, _, _ = strings.Cut(valStr, ",")
			valStr, _, _ = strings.Cut(valStr, "}")
			valStr = strings.TrimSpace(valStr)

			var powerMW float64
			var parsed bool

			// Strategy 1: Try parsing as a signed integer first.
			// This handles standard positive values and explicit negative strings like "-12345".
			if valInt, err := strconv.ParseInt(valStr, 10, 64); err == nil {
				powerMW = float64(valInt)
				parsed = true
			} else if valUint, err := strconv.ParseUint(valStr, 10, 64); err == nil {
				// Strategy 2: Try parsing as an unsigned integer (Two's Complement).
				// ioreg often returns negative values as huge uint64 numbers (e.g. 2^64 - 100).
				// Explicitly handle two's complement rather than relying on an unchecked cast.
				var signed int64
				if valUint <= math.MaxInt64 {
					// Fits in positive int64 range directly.
					signed = int64(valUint)
				} else {
					// Interpret as negative two's complement value.
					// For a uint64 v > MaxInt64, the corresponding negative int64 is:
					// -(^v + 1) where ^ is bitwise NOT in 64 bits.
					negMag := ^valUint + 1
					// negMag now holds the magnitude of the negative value as uint64.
					if negMag <= math.MaxInt64 {
						signed = -int64(negMag)
					} else {
						// Magnitude too large to represent; skip this parsing strategy.
						goto skipUintParse
					}
				}
				powerMW = float64(signed)
				parsed = true
			skipUintParse:
			}

			if parsed {
				// Validate reasonable battery power range: -200W to 200W
				if powerMW > -200000 && powerMW < 200000 {
					thermal.BatteryPower = powerMW / 1000.0
				}
			}
		}
	}

	return thermal
}
