//go:build darwin

package main

import (
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"
)

func checkDevEnvironment() categoryResult {
	checks := []func() checkResult{
		checkVersionMismatches,
		checkMissingTools,
		checkXcodeCLI,
		checkDuplicateExtensions,
	}

	results := make([]checkResult, len(checks))
	var wg sync.WaitGroup
	for i, fn := range checks {
		wg.Add(1)
		go func(idx int, f func() checkResult) {
			defer wg.Done()
			results[idx] = f()
		}(i, fn)
	}
	wg.Wait()

	return buildCategory("Dev Environment", scoreDevEnv, results)
}

func checkVersionMismatches() checkResult {
	r := checkResult{Name: "Version mismatches", MaxScore: 5}

	var mismatches []string

	// PostgreSQL: client vs server.
	if psqlPath, _ := exec.LookPath("psql"); psqlPath != "" {
		clientOut, err := exec.Command("psql", "--version").Output()
		if err == nil {
			clientMajor := parseMajorVersion(string(clientOut))
			if err := exec.Command("pg_isready", "-q").Run(); err == nil {
				serverOut, err := exec.Command("psql", "-t", "-c", "SHOW server_version").Output()
				if err == nil {
					serverMajor := parseMajorVersion(strings.TrimSpace(string(serverOut)))
					if clientMajor != "" && serverMajor != "" && clientMajor != serverMajor {
						mismatches = append(mismatches, fmt.Sprintf("psql client v%s vs server v%s", clientMajor, serverMajor))
					}
				}
			}
		}
	}

	// Node.js + nvm.
	nvmDir := os.Getenv("NVM_DIR")
	if nvmDir != "" {
		nodeOut, err := exec.Command("node", "-v").Output()
		if err == nil {
			currentNode := parseMajorVersion(strings.TrimSpace(string(nodeOut)))
			defaultOut, err := exec.Command("bash", "-c", "source \"$NVM_DIR/nvm.sh\" && nvm version default 2>/dev/null").Output()
			if err == nil {
				defaultNode := parseMajorVersion(strings.TrimSpace(string(defaultOut)))
				if currentNode != "" && defaultNode != "" && currentNode != defaultNode {
					mismatches = append(mismatches, fmt.Sprintf("node v%s active vs nvm default v%s", currentNode, defaultNode))
				}
			}
		}
	}

	if len(mismatches) == 0 {
		r.Status = statusPass
		r.Score = 5
		r.Detail = "No version mismatches"
	} else if len(mismatches) == 1 {
		r.Status = statusWarn
		r.Score = 2
		r.Detail = mismatches[0]
	} else {
		r.Status = statusFail
		r.Score = 0
		r.Detail = strings.Join(mismatches, "; ")
	}
	return r
}

var versionRegex = regexp.MustCompile(`(\d+)(?:\.\d+)*`)

func parseMajorVersion(s string) string {
	match := versionRegex.FindStringSubmatch(s)
	if len(match) >= 2 {
		return match[1]
	}
	return ""
}

func checkMissingTools() checkResult {
	r := checkResult{Name: "Common tools", MaxScore: 6}

	tools := []string{"git", "node", "python3", "brew", "docker", "go", "xcode-select"}
	var missing []string

	for _, tool := range tools {
		if _, err := exec.LookPath(tool); err != nil {
			missing = append(missing, tool)
		}
	}

	if len(missing) == 0 {
		r.Status = statusPass
		r.Score = 6
		r.Detail = "All tools available"
	} else if len(missing) <= 2 {
		r.Status = statusWarn
		r.Score = 3
		r.Detail = "Missing: " + strings.Join(missing, ", ")
	} else {
		r.Status = statusFail
		r.Score = 0
		r.Detail = "Missing: " + strings.Join(missing, ", ")
	}
	return r
}

func checkXcodeCLI() checkResult {
	r := checkResult{Name: "Xcode CLI tools", MaxScore: 2}

	out, err := exec.Command("xcode-select", "-p").Output()
	if err != nil {
		r.Status = statusFail
		r.Score = 0
		r.Detail = "Not installed"
		return r
	}

	path := strings.TrimSpace(string(out))
	if _, err := os.Stat(path); err != nil {
		r.Status = statusFail
		r.Score = 0
		r.Detail = "Path not found: " + path
		return r
	}

	r.Status = statusPass
	r.Score = 2
	r.Detail = path
	return r
}

func checkDuplicateExtensions() checkResult {
	r := checkResult{Name: "IDE extensions", MaxScore: 2}

	home, err := os.UserHomeDir()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read home directory"
		return r
	}

	extDirs := []string{
		filepath.Join(home, ".vscode", "extensions"),
		filepath.Join(home, ".cursor", "extensions"),
	}

	var allDups []string
	for _, dir := range extDirs {
		dups := findDuplicateExtensions(dir)
		allDups = append(allDups, dups...)
	}

	if len(allDups) == 0 {
		r.Status = statusPass
		r.Score = 2
		r.Detail = "No duplicate extensions"
	} else if len(allDups) <= 2 {
		r.Status = statusWarn
		r.Score = 1
		r.Detail = fmt.Sprintf("%d duplicates: %s", len(allDups), strings.Join(allDups, ", "))
	} else {
		r.Status = statusFail
		r.Score = 0
		r.Detail = fmt.Sprintf("%d duplicates found", len(allDups))
	}
	return r
}

func findDuplicateExtensions(dir string) []string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}

	counts := make(map[string]int)
	for _, e := range entries {
		if !e.IsDir() {
			continue
		}
		name := e.Name()
		lastDash := strings.LastIndex(name, "-")
		if lastDash <= 0 {
			continue
		}
		extID := name[:lastDash]
		counts[extID]++
	}

	var dups []string
	for id, count := range counts {
		if count > 1 {
			dups = append(dups, id)
		}
	}
	sort.Strings(dups)
	return dups
}
