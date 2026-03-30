//go:build darwin

package main

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

func checkMole() categoryResult {
	checks := []checkResult{
		checkMoleVersion(),
		checkMoleConfig(),
		checkMolePermissions(),
	}
	return buildCategory("Mole", scoreMole, checks)
}

func checkMoleVersion() checkResult {
	r := checkResult{Name: "Version", MaxScore: 2}

	out, err := exec.Command("mo", "--version").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not determine installed version"
		return r
	}
	// mo --version outputs multiple lines; version is on the first line.
	firstLine := strings.Split(strings.TrimSpace(string(out)), "\n")[0]
	installed := strings.TrimPrefix(firstLine, "Mole ")
	installed = strings.TrimPrefix(installed, "version ")

	client := &http.Client{Timeout: 3 * time.Second}
	resp, err := client.Get("https://api.github.com/repos/tw93/Mole/releases/latest")
	if err != nil {
		r.Status = statusPass
		r.Score = 2
		r.Detail = installed + " (could not check latest)"
		return r
	}
	defer resp.Body.Close()

	if resp.StatusCode != 200 {
		r.Status = statusPass
		r.Score = 2
		r.Detail = installed + " (could not check latest)"
		return r
	}

	var release struct {
		TagName string `json:"tag_name"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&release); err != nil {
		r.Status = statusPass
		r.Score = 2
		r.Detail = installed + " (could not parse latest)"
		return r
	}

	latest := strings.TrimPrefix(strings.TrimPrefix(release.TagName, "V"), "v")
	if installed == latest {
		r.Status = statusPass
		r.Score = 2
		r.Detail = installed + " (latest)"
	} else {
		r.Status = statusWarn
		r.Score = 0
		r.Detail = fmt.Sprintf("%s → %s available", installed, latest)
	}
	return r
}

func countWhitelistErrors(content string) int {
	errorCount := 0
	for line := range strings.SplitSeq(content, "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		if strings.HasPrefix(line, "..") || strings.Contains(line, "/..") {
			errorCount++
		}
	}
	return errorCount
}

func checkMoleConfig() checkResult {
	r := checkResult{Name: "Config", MaxScore: 2}

	home, err := os.UserHomeDir()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read home directory"
		return r
	}

	whitelistPath := filepath.Join(home, ".config", "mole", "whitelist")
	if _, err := os.Stat(whitelistPath); os.IsNotExist(err) {
		r.Status = statusPass
		r.Score = 2
		r.Detail = "Using default config"
		return r
	}

	data, err := os.ReadFile(whitelistPath)
	if err != nil {
		r.Status = statusWarn
		r.Score = 0
		r.Detail = "Whitelist file unreadable"
		return r
	}

	errorCount := countWhitelistErrors(string(data))

	if errorCount > 0 {
		r.Status = statusWarn
		r.Score = 1
		r.Detail = fmt.Sprintf("Whitelist has %d invalid entries", errorCount)
	} else {
		r.Status = statusPass
		r.Score = 2
		r.Detail = "Config valid"
	}
	return r
}

func checkMolePermissions() checkResult {
	r := checkResult{Name: "Permissions", MaxScore: 1}

	moPath, err := exec.LookPath("mo")
	if err != nil {
		r.Status = statusWarn
		r.Score = 0
		r.Detail = "mo not found in PATH"
		return r
	}

	info, err := os.Stat(moPath)
	if err != nil {
		r.Status = statusWarn
		r.Score = 0
		r.Detail = "Could not stat mo binary"
		return r
	}

	if info.Mode()&0111 == 0 {
		r.Status = statusFail
		r.Score = 0
		r.Detail = "mo binary is not executable"
		return r
	}

	home, err2 := os.UserHomeDir()
	if err2 != nil {
		r.Status = statusPass
		r.Score = 1
		r.Detail = "OK (could not verify config dir)"
		return r
	}
	configDir := filepath.Join(home, ".config", "mole")
	if _, err := os.Stat(configDir); err == nil {
		f, err := os.CreateTemp(configDir, ".doctor_check_*")
		if err != nil {
			r.Status = statusWarn
			r.Score = 0
			r.Detail = "Config directory not writable"
			return r
		}
		_ = f.Close()
		_ = os.Remove(f.Name())
	}

	r.Status = statusPass
	r.Score = 1
	r.Detail = "OK"
	return r
}
