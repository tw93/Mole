package main

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"

	"github.com/shirou/gopsutil/v3/host"
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
		for line := range strings.Lines(out) {
			line = strings.TrimSpace(line)

			// Battery temperature ("Temperature" = 3055).
			if _, after, found := strings.Cut(line, "\"Temperature\" = "); found {
				valStr := strings.TrimSpace(after)
				if tempRaw, err := strconv.Atoi(valStr); err == nil && tempRaw > 0 {
					thermal.CPUTemp = float64(tempRaw) / 100.0
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
				if powerMW, err := strconv.ParseFloat(valStr, 64); err == nil && powerMW > 0 {
					thermal.SystemPower = powerMW / 1000.0
				}
			}

			// Battery power (mW -> W, positive = discharging).
			if _, after, found := strings.Cut(line, "\"BatteryPower\"="); found {
				valStr := strings.TrimSpace(after)
				valStr, _, _ = strings.Cut(valStr, ",")
				valStr, _, _ = strings.Cut(valStr, "}")
				valStr = strings.TrimSpace(valStr)
				// Parse as int64 first to handle negative values (charging)
				if powerMW, err := strconv.ParseInt(valStr, 10, 64); err == nil {
					thermal.BatteryPower = float64(powerMW) / 1000.0
				}
			}
		}
	}

	// Fallback: thermal level proxy.
	if thermal.CPUTemp == 0 {
		ctx2, cancel2 := context.WithTimeout(context.Background(), 500*time.Millisecond)
		defer cancel2()
		out2, err := runCmd(ctx2, "sysctl", "-n", "machdep.xcpm.cpu_thermal_level")
		if err == nil {
			level, _ := strconv.Atoi(strings.TrimSpace(out2))
			if level >= 0 {
				thermal.CPUTemp = 45 + float64(level)*0.5
			}
		}
	}

	return thermal
}

func collectSensors() ([]SensorReading, error) {
	temps, err := host.SensorsTemperatures()
	if err != nil {
		return nil, err
	}
	var out []SensorReading
	for _, t := range temps {
		if t.Temperature <= 0 || t.Temperature > 150 {
			continue
		}
		out = append(out, SensorReading{
			Label: prettifyLabel(t.SensorKey),
			Value: t.Temperature,
			Unit:  "°C",
		})
	}
	return out, nil
}

func prettifyLabel(key string) string {
	key = strings.TrimSpace(key)
	key = strings.TrimPrefix(key, "TC")
	key = strings.ReplaceAll(key, "_", " ")
	return key
}
