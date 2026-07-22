// Package main: status preferences store.
//
// Persisted preferences live in a tiny `key=value` file (one pair per line) at
// ~/.config/mole/status_prefs. This file replaces the previous single-value
// implementation, which compared the whole file against one exact string and so
// could only ever hold a single preference. The map-based store below lets any
// number of preferences coexist: writing one key preserves all the others.
package main

import (
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

// getConfigPath returns the path to the status preferences file, or "" if the
// user's home directory cannot be resolved.
func getConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "mole", "status_prefs")
}

// loadPrefs reads the preferences file into a map. A missing or unreadable file
// yields an empty (never nil) map, so callers can index it safely. Blank lines
// and lines starting with '#' are ignored, so the file stays hand-editable.
func loadPrefs() map[string]string {
	prefs := map[string]string{}

	path := getConfigPath()
	if path == "" {
		return prefs
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return prefs
	}

	for line := range strings.SplitSeq(string(data), "\n") {
		line = strings.TrimSpace(line)
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		key, value, ok := strings.Cut(line, "=")
		if !ok {
			continue // no '=' on the line, skip it rather than guess
		}
		prefs[strings.TrimSpace(key)] = strings.TrimSpace(value)
	}
	return prefs
}

// savePref sets a single preference and rewrites the file, preserving every
// other key already stored. Failures are silently ignored: a preference that
// cannot be persisted must never crash the status TUI.
func savePref(key, value string) {
	path := getConfigPath()
	if path == "" {
		return
	}

	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o755); err != nil {
		return
	}

	lock, err := os.OpenFile(path+".lock", os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return
	}
	defer func() {
		_ = lock.Close()
	}()
	if err := unix.Flock(int(lock.Fd()), unix.LOCK_EX); err != nil {
		return
	}
	defer unix.Flock(int(lock.Fd()), unix.LOCK_UN) //nolint:errcheck

	// Read only after acquiring the inter-process lock. Otherwise two status
	// instances can both load the same old map and the later writer drops the
	// other instance's new key.
	prefs := loadPrefs()
	prefs[key] = value

	// Sort keys so the file is deterministic: stable on disk, clean diffs,
	// and testable (map iteration order is randomized in Go).
	keys := make([]string, 0, len(prefs))
	for k := range prefs {
		keys = append(keys, k)
	}
	sort.Strings(keys)

	var b strings.Builder
	for _, k := range keys {
		b.WriteString(k)
		b.WriteByte('=')
		b.WriteString(prefs[k])
		b.WriteByte('\n')
	}
	if err := writePrefsAtomically(path, []byte(b.String())); err != nil {
		return
	}
}

func writePrefsAtomically(path string, data []byte) error {
	temp, err := os.CreateTemp(filepath.Dir(path), ".status_prefs.*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)

	if err := temp.Chmod(0o644); err != nil {
		_ = temp.Close()
		return err
	}
	if _, err := temp.Write(data); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Sync(); err != nil {
		_ = temp.Close()
		return err
	}
	if err := temp.Close(); err != nil {
		return err
	}
	if err := os.Rename(tempPath, path); err != nil {
		return fmt.Errorf("replace preferences: %w", err)
	}
	return nil
}

// Typed accessors: the rest of the code speaks in bools/ints, not raw strings.

// loadCatHidden reports whether the ASCII cat should be hidden.
func loadCatHidden() bool {
	return loadPrefs()["cat_hidden"] == "true"
}

// saveCatHidden persists the cat visibility preference.
func saveCatHidden(hidden bool) {
	savePref("cat_hidden", strconv.FormatBool(hidden))
}

// gpuDetailCycle is how many GPU utilization rows the 'g' key steps through:
// 1 = Device only, 2 = +Renderer, 3 = +Tiler. Apple exposes no finer breakdown.
var gpuDetailCycle = []int{1, 2, 3}

// loadGPUDetail reports how many GPU utilization rows to show (1..3), defaulting
// to 1 when unset or invalid.
func loadGPUDetail() int {
	raw, ok := loadPrefs()["gpu_detail"]
	if !ok {
		return gpuDetailCycle[0]
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < gpuDetailCycle[0] || n > gpuDetailCycle[len(gpuDetailCycle)-1] {
		return gpuDetailCycle[0]
	}
	return n
}

// saveGPUDetail persists the GPU detail-level preference.
func saveGPUDetail(n int) {
	savePref("gpu_detail", strconv.Itoa(n))
}

// nextGPUDetail returns the value after current in gpuDetailCycle, wrapping.
func nextGPUDetail(current int) int {
	for i, v := range gpuDetailCycle {
		if v == current {
			return gpuDetailCycle[(i+1)%len(gpuDetailCycle)]
		}
	}
	return gpuDetailCycle[0]
}

// cpuCoresCycle is the sequence the 'c' key steps through. 0 means "all cores".
// The default (first entry) is 2, matching the historical hard-coded behaviour.
var cpuCoresCycle = []int{2, 4, 8, 0}

// loadCPUCores reports how many CPU cores the status card should list. 0 means
// "all". It falls back to the default (2) when unset or invalid, so a corrupt
// pref never breaks the display.
func loadCPUCores() int {
	raw, ok := loadPrefs()["cpu_cores"]
	if !ok {
		return cpuCoresCycle[0]
	}
	n, err := strconv.Atoi(raw)
	if err != nil || n < 0 {
		return cpuCoresCycle[0]
	}
	return n
}

// saveCPUCores persists the CPU core count preference (0 = all).
func saveCPUCores(n int) {
	savePref("cpu_cores", strconv.Itoa(n))
}

// nextCPUCores returns the value after current in cpuCoresCycle, wrapping around.
// An unrecognised current value restarts the cycle at its first entry.
func nextCPUCores(current int) int {
	for i, v := range cpuCoresCycle {
		if v == current {
			return cpuCoresCycle[(i+1)%len(cpuCoresCycle)]
		}
	}
	return cpuCoresCycle[0]
}

// smallerCPUCores returns the entry before current in cpuCoresCycle, without
// wrapping: the first entry is the floor. Used by the view to shrink the CPU
// card when the rendered frame does not fit the window.
func smallerCPUCores(current int) int {
	for i, v := range cpuCoresCycle {
		if v == current {
			if i == 0 {
				return cpuCoresCycle[0]
			}
			return cpuCoresCycle[i-1]
		}
	}
	return cpuCoresCycle[0]
}
