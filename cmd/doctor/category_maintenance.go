//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

func checkMaintenance() categoryResult {
	cat := categoryResult{
		Name:     "Maintenance",
		MaxScore: scoreMaintenance,
	}

	cat.Checks = append(cat.Checks, checkBrokenLaunchAgents())
	cat.Checks = append(cat.Checks, checkUnusedApps())
	cat.Checks = append(cat.Checks, checkHeavyProcesses())

	for _, c := range cat.Checks {
		cat.Score += c.Score
	}
	if cat.Score > cat.MaxScore {
		cat.Score = cat.MaxScore
	}
	return cat
}

func checkBrokenLaunchAgents() checkResult {
	r := checkResult{Name: "Broken launch agents", MaxScore: 5}

	home, err := os.UserHomeDir()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read home directory"
		return r
	}

	agentDir := filepath.Join(home, "Library", "LaunchAgents")
	entries, err := os.ReadDir(agentDir)
	if err != nil {
		r.Status = statusPass
		r.Score = 5
		r.Detail = "No launch agents directory"
		return r
	}

	brokenCount := 0
	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".plist") {
			continue
		}
		plistPath := filepath.Join(agentDir, entry.Name())
		out, err := exec.Command("defaults", "read", plistPath, "Program").Output()
		if err != nil {
			out, err = exec.Command("defaults", "read", plistPath, "ProgramArguments").Output()
			if err != nil {
				continue
			}
		}

		program := strings.TrimSpace(string(out))
		if strings.HasPrefix(program, "(") {
			lines := strings.Split(program, "\n")
			for _, line := range lines {
				trimmed := strings.Trim(strings.TrimSpace(line), "(\",)")
				if trimmed != "" && !strings.HasPrefix(trimmed, "(") && !strings.HasPrefix(trimmed, ")") {
					program = trimmed
					break
				}
			}
		}
		program = strings.Trim(program, "\"")

		if program == "" || !strings.HasPrefix(program, "/") {
			continue
		}
		if _, err := os.Stat(program); os.IsNotExist(err) {
			brokenCount++
		}
	}

	r.Detail = fmt.Sprintf("%d broken agents found", brokenCount)
	if brokenCount > brokenAgentsHigh {
		r.Status = statusFail
		r.Score = 0
	} else if brokenCount > 0 {
		r.Status = statusWarn
		r.Score = 3
	} else {
		r.Status = statusPass
		r.Score = 5
		r.Detail = "All launch agents OK"
	}
	return r
}

func checkUnusedApps() checkResult {
	r := checkResult{Name: "Unused apps (90+ days)", MaxScore: 5}

	entries, err := os.ReadDir("/Applications")
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read /Applications"
		return r
	}

	unusedCount := 0
	threshold := time.Now().AddDate(0, 0, -unusedAppsDays)

	for _, entry := range entries {
		if !strings.HasSuffix(entry.Name(), ".app") {
			continue
		}
		appPath := filepath.Join("/Applications", entry.Name())
		out, err := exec.Command("mdls", "-name", "kMDItemLastUsedDate", "-raw", appPath).Output()
		if err != nil {
			continue
		}

		dateStr := strings.TrimSpace(string(out))
		if dateStr == "(null)" || dateStr == "" {
			continue
		}

		var t time.Time
		for _, layout := range []string{
			"2006-01-02 15:04:05 +0000",
			"2006-01-02 15:04:05 -0700",
		} {
			if parsed, err := time.Parse(layout, dateStr); err == nil {
				t = parsed
				break
			}
		}
		if t.IsZero() {
			continue
		}

		if t.Before(threshold) {
			unusedCount++
		}
	}

	r.Detail = fmt.Sprintf("%d apps unused for 90+ days", unusedCount)
	if unusedCount > unusedAppsHigh {
		r.Status = statusWarn
		r.Score = 0
	} else if unusedCount > 0 {
		r.Status = statusWarn
		r.Score = 3
	} else {
		r.Status = statusPass
		r.Score = 5
		r.Detail = "All apps recently used"
	}
	return r
}

func checkHeavyProcesses() checkResult {
	r := checkResult{Name: "Heavy processes", MaxScore: 5}

	out, err := exec.Command("ps", "axo", "pid,pcpu,rss,comm").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read process list"
		return r
	}

	heavyCount := 0
	var heavyNames []string

	lines := strings.Split(string(out), "\n")
	for _, line := range lines[1:] {
		fields := strings.Fields(line)
		if len(fields) < 4 {
			continue
		}

		cpu, _ := strconv.ParseFloat(fields[1], 64)
		rssKB, _ := strconv.ParseInt(fields[2], 10, 64)
		rssMB := float64(rssKB) / 1024
		name := filepath.Base(fields[3])

		if name == "kernel_task" || name == "WindowServer" || name == "doctor-go" {
			continue
		}

		if cpu > heavyProcessCPU || rssMB > heavyProcessMemMB {
			heavyCount++
			if len(heavyNames) < 3 {
				heavyNames = append(heavyNames, fmt.Sprintf("%s (%.0f%% CPU, %.0f MB)", name, cpu, rssMB))
			}
		}
	}

	if heavyCount > heavyProcessMax {
		r.Status = statusWarn
		r.Score = 0
		r.Detail = fmt.Sprintf("%d heavy processes: %s", heavyCount, strings.Join(heavyNames, ", "))
	} else if heavyCount > 0 {
		r.Status = statusWarn
		r.Score = 3
		procLabel := "process"
		if heavyCount > 1 {
			procLabel = "processes"
		}
		r.Detail = fmt.Sprintf("%d heavy %s: %s", heavyCount, procLabel, strings.Join(heavyNames, ", "))
	} else {
		r.Status = statusPass
		r.Score = 5
		r.Detail = "No heavy background processes"
	}
	return r
}
