//go:build darwin

package main

import (
	"fmt"
	"os/exec"
	"strconv"
	"strings"
)

func checkBattery() categoryResult {
	cat := categoryResult{
		Name:     "Battery",
		MaxScore: scoreBattery,
	}

	out, err := exec.Command("ioreg", "-r", "-c", "AppleSmartBattery", "-d", "1").Output()
	if err != nil || len(out) == 0 || !strings.Contains(string(out), "AppleSmartBattery") {
		cat.MaxScore = 0
		cat.Checks = append(cat.Checks, checkResult{
			Name:   "Battery",
			Status: statusSkipped,
			Detail: "No battery detected (desktop Mac)",
		})
		return cat
	}

	ioregOutput := string(out)

	cat.Checks = append(cat.Checks, checkBatteryCycles(ioregOutput))
	cat.Checks = append(cat.Checks, checkBatteryHealth(ioregOutput))

	for _, c := range cat.Checks {
		cat.Score += c.Score
	}
	if cat.Score > cat.MaxScore {
		cat.Score = cat.MaxScore
	}
	return cat
}

func checkBatteryCycles(ioregOutput string) checkResult {
	r := checkResult{Name: "Cycle count", MaxScore: 10}

	cycles := parseIORegInt(ioregOutput, "CycleCount")
	if cycles < 0 {
		r.Status = statusSkipped
		r.Detail = "Could not read cycle count"
		return r
	}

	r.Detail = fmt.Sprintf("%d cycles", cycles)

	if cycles > batteryCycleHigh {
		r.Status = statusFail
		r.Score = 2
	} else if cycles > batteryCycleMedium {
		r.Status = statusWarn
		r.Score = 7
	} else {
		r.Status = statusPass
		r.Score = 10
	}
	return r
}

func checkBatteryHealth(ioregOutput string) checkResult {
	r := checkResult{Name: "Health", MaxScore: 10}

	// Prefer AppleRawMaxCapacity (mAh) over MaxCapacity (percentage on newer macOS).
	maxCap := parseIORegInt(ioregOutput, "AppleRawMaxCapacity")
	designCap := parseIORegInt(ioregOutput, "DesignCapacity")

	if maxCap <= 0 || designCap <= 0 {
		maxCap = parseIORegInt(ioregOutput, "MaxCapacity")
		designCap = parseIORegInt(ioregOutput, "DesignCapacity")
	}

	if maxCap <= 0 || designCap <= 0 {
		r.Status = statusSkipped
		r.Detail = "Could not read battery capacity"
		return r
	}

	healthPct := int(int64(maxCap) * 100 / int64(designCap))
	r.Detail = fmt.Sprintf("%d%% health", healthPct)

	if healthPct < batteryHealthLow {
		r.Status = statusFail
		r.Score = 2
	} else if healthPct < batteryHealthMed {
		r.Status = statusWarn
		r.Score = 7
	} else {
		r.Status = statusPass
		r.Score = 10
	}
	return r
}

func parseIORegInt(output, key string) int {
	for _, line := range strings.Split(output, "\n") {
		trimmed := strings.TrimSpace(line)
		if strings.HasPrefix(trimmed, "\""+key+"\"") {
			parts := strings.SplitN(trimmed, "=", 2)
			if len(parts) == 2 {
				val := strings.TrimSpace(parts[1])
				n, err := strconv.Atoi(val)
				if err == nil {
					return n
				}
			}
		}
	}
	return -1
}
