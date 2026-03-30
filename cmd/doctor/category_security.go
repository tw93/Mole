//go:build darwin

package main

import (
	"os/exec"
	"strconv"
	"strings"
)

func checkSecurity() categoryResult {
	checks := []checkResult{
		checkFileVault(),
		checkFirewall(),
		checkSIP(),
		checkMacOSUpdated(),
	}
	return buildCategory("Security", scoreSecurity, checks)
}

func checkFileVault() checkResult {
	r := checkResult{Name: "FileVault", MaxScore: 4}

	out, err := exec.Command("fdesetup", "status").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not check FileVault"
		return r
	}

	if strings.Contains(string(out), "FileVault is On") {
		r.Status = statusPass
		r.Score = 4
		r.Detail = "Enabled"
	} else {
		r.Status = statusFail
		r.Score = 0
		r.Detail = "Disabled — disk is not encrypted"
	}
	return r
}

func checkFirewall() checkResult {
	r := checkResult{Name: "Firewall", MaxScore: 4}

	// Try socketfilterfw first (works on macOS 15 Sequoia+).
	out, err := exec.Command("/usr/libexec/ApplicationFirewall/socketfilterfw",
		"--getglobalstate").Output()
	if err == nil {
		if strings.Contains(string(out), "enabled") {
			r.Status = statusPass
			r.Score = 4
			r.Detail = "Enabled"
		} else {
			r.Status = statusFail
			r.Score = 0
			r.Detail = "Disabled"
		}
		return r
	}

	// Fallback to defaults read (pre-Sequoia).
	out, err = exec.Command("defaults", "read",
		"/Library/Preferences/com.apple.alf", "globalstate").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not check firewall status"
		return r
	}

	state := strings.TrimSpace(string(out))
	if state == "1" || state == "2" {
		r.Status = statusPass
		r.Score = 4
		r.Detail = "Enabled"
	} else {
		r.Status = statusFail
		r.Score = 0
		r.Detail = "Disabled"
	}
	return r
}

func checkSIP() checkResult {
	r := checkResult{Name: "SIP", MaxScore: 4}

	out, err := exec.Command("csrutil", "status").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not check SIP status"
		return r
	}

	sipOutput := string(out)
	if strings.Contains(sipOutput, "enabled") {
		if strings.Contains(sipOutput, "Custom Configuration") {
			r.Status = statusWarn
			r.Score = 2
			r.Detail = "Partially enabled (custom configuration)"
		} else {
			r.Status = statusPass
			r.Score = 4
			r.Detail = "Enabled"
		}
	} else {
		r.Status = statusFail
		r.Score = 0
		r.Detail = "Disabled — system integrity at risk"
	}
	return r
}

func checkMacOSUpdated() checkResult {
	r := checkResult{Name: "macOS version", MaxScore: 3}

	out, err := exec.Command("sw_vers", "-productVersion").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read macOS version"
		return r
	}

	version := strings.TrimSpace(string(out))
	r.Detail = "macOS " + version

	parts := strings.Split(version, ".")
	if len(parts) == 0 {
		r.Status = statusSkipped
		r.Detail = "Could not parse macOS version"
		return r
	}

	majorNum, _ := strconv.Atoi(parts[0])

	// Apple supports the current and two prior major macOS releases with security updates.
	// Use the build version prefix to derive the current release generation:
	// Build prefix 20=macOS 11, 21=12, 22=13, 23=14, 24=15, 25=16, 26=17...
	// Formula: latestMajor = buildPrefix - 9
	latestMajor := majorNum // default: assume we're on latest
	buildOut, err := exec.Command("sw_vers", "-buildVersion").Output()
	if err == nil {
		buildStr := strings.TrimSpace(string(buildOut))
		if len(buildStr) >= 2 {
			if bp, e := strconv.Atoi(buildStr[:2]); e == nil && bp >= 20 {
				latestMajor = bp - 9
			}
		}
	}

	// Warn if more than 1 major version behind the latest supported.
	if majorNum >= latestMajor {
		r.Status = statusPass
		r.Score = 3
	} else if majorNum >= latestMajor-1 {
		r.Status = statusWarn
		r.Score = 2
		r.Detail = "macOS " + version + " — one version behind"
	} else {
		r.Status = statusWarn
		r.Score = 1
		r.Detail = "macOS " + version + " — consider updating"
	}
	return r
}
