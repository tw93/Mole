//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"
)

// System processes that commonly show high resource usage but are expected.
var systemProcesses = map[string]bool{
	"kernel_task":    true,
	"WindowServer":   true,
	"mds":            true,
	"mds_stores":     true,
	"distnoted":      true,
	"launchd":        true,
	"syslogd":        true,
	"opendirectoryd": true,
}

func checkMaintenance() categoryResult {
	checks := []checkResult{
		checkBrokenLaunchAgents(),
		checkUnusedApps(),
		checkHeavyProcesses(),
	}
	return buildCategory("Maintenance", scoreMaintenance, checks)
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
			lines := strings.SplitSeq(program, "\n")
			for line := range lines {
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

	var apps []string
	for _, entry := range entries {
		if strings.HasSuffix(entry.Name(), ".app") {
			apps = append(apps, filepath.Join("/Applications", entry.Name()))
		}
	}

	threshold := time.Now().AddDate(0, 0, -unusedAppsDays)
	type result struct{ unused bool }
	ch := make(chan result, len(apps))
	sem := make(chan struct{}, 10) // bounded concurrency

	var wg sync.WaitGroup
	for _, appPath := range apps {
		wg.Add(1)
		go func(path string) {
			defer wg.Done()
			sem <- struct{}{}
			defer func() { <-sem }()

			out, err := exec.Command("mdls", "-name", "kMDItemLastUsedDate", "-raw", path).Output()
			if err != nil {
				ch <- result{false}
				return
			}

			dateStr := strings.TrimSpace(string(out))
			if dateStr == "(null)" || dateStr == "" {
				ch <- result{false}
				return
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
				ch <- result{false}
				return
			}

			ch <- result{unused: t.Before(threshold)}
		}(appPath)
	}

	wg.Wait()
	close(ch)

	unusedCount := 0
	for r := range ch {
		if r.unused {
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

		if systemProcesses[name] {
			continue
		}
		// Skip our own process.
		if name == "mo" || strings.HasPrefix(name, "doctor") {
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
