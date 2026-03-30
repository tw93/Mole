//go:build darwin

package main

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"
)

func checkStorage() categoryResult {
	checks := []func() checkResult{
		checkFreeSpace,
		checkRecoverableCache,
		checkPurgeableSpace,
		checkNodeModules,
		checkIOSBackups,
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

	return buildCategory("Storage", scoreStorage, results)
}

func checkFreeSpace() checkResult {
	r := checkResult{Name: "Free space", MaxScore: 8}

	var stat syscall.Statfs_t
	if err := syscall.Statfs("/", &stat); err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read disk stats"
		return r
	}

	total := stat.Blocks * uint64(stat.Bsize)
	free := stat.Bavail * uint64(stat.Bsize)
	ratio := float64(free) / float64(total)

	r.Detail = humanizeBytes(int64(free)) + " free of " + humanizeBytes(int64(total))

	if ratio < diskFreeCritical {
		r.Status = statusFail
		r.Score = 0
	} else if ratio < diskFreeWarning {
		r.Status = statusWarn
		r.Score = 4
	} else {
		r.Status = statusPass
		r.Score = 8
	}
	return r
}

type cacheTarget struct {
	Name     string
	Paths    []string
	WarnSize int64
	FailSize int64
}

func checkRecoverableCache() checkResult {
	r := checkResult{Name: "Recoverable cache", MaxScore: 4}

	cachePaths := []string{
		"~/Library/Caches",
		"~/Library/Logs",
	}

	var totalBytes int64
	for _, p := range cachePaths {
		expanded := expandHome(p)
		ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
		out, err := exec.CommandContext(ctx, "du", "-sk", expanded).Output()
		cancel()
		if err != nil {
			continue
		}
		fields := strings.Fields(string(out))
		if len(fields) > 0 {
			kb, err2 := strconv.ParseInt(fields[0], 10, 64)
			if err2 == nil {
				totalBytes += kb * 1024
			}
		}
	}

	gb := float64(totalBytes) / (1024 * 1024 * 1024)
	r.Detail = humanizeBytes(totalBytes) + " in caches"

	if gb > cacheRecoverableHighGB {
		r.Status = statusWarn
		r.Score = 1
	} else if gb > cacheRecoverableMedGB {
		r.Status = statusPass
		r.Score = 3
	} else {
		r.Status = statusPass
		r.Score = 4
	}

	// Per-app cache breakdown (informational) — run in parallel.
	targets := []cacheTarget{
		{"Spotify", []string{"~/Library/Caches/com.spotify.client/Data"}, cacheBreakdownWarnDefault, cacheBreakdownFailDefault},
		{"JetBrains", []string{"~/Library/Caches/JetBrains"}, cacheBreakdownWarnDefault, cacheBreakdownFailDefault},
		{"Playwright", []string{"~/Library/Caches/ms-playwright", "~/Library/Caches/ms-playwright-go"}, cacheBreakdownWarnSmall, cacheBreakdownFailSmall},
		{"npx cache", []string{"~/.npm/_npx"}, cacheBreakdownWarnSmall, cacheBreakdownFailSmall},
		{"Xcode DerivedData", []string{"~/Library/Developer/Xcode/DerivedData"}, cacheBreakdownWarnXcode, cacheBreakdownFailXcode},
	}

	type bdResult struct {
		item cacheBreakdownItem
		size int64
	}
	bdCh := make(chan bdResult, len(targets))
	var bdWg sync.WaitGroup
	for _, t := range targets {
		bdWg.Add(1)
		go func(target cacheTarget) {
			defer bdWg.Done()
			var size int64
			for _, p := range target.Paths {
				size += dirSizeBytes(expandHome(p))
			}
			if size == 0 {
				return
			}
			status := statusPass
			if size >= target.FailSize {
				status = statusFail
			} else if size >= target.WarnSize {
				status = statusWarn
			}
			bdCh <- bdResult{item: cacheBreakdownItem{
				Name:   target.Name,
				Path:   target.Paths[0],
				Size:   size,
				Status: status,
			}, size: size}
		}(t)
	}
	bdWg.Wait()
	close(bdCh)
	for bd := range bdCh {
		r.Breakdown = append(r.Breakdown, bd.item)
	}

	return r
}

func checkPurgeableSpace() checkResult {
	r := checkResult{Name: "Purgeable space", MaxScore: 0}

	out, err := exec.Command("diskutil", "info", "/").Output()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read disk info"
		return r
	}

	for line := range strings.SplitSeq(string(out), "\n") {
		if strings.Contains(line, "Purgeable") {
			parts := strings.SplitN(line, ":", 2)
			if len(parts) == 2 {
				r.Detail = strings.TrimSpace(parts[1]) + " purgeable"
				r.Status = statusPass
				return r
			}
		}
	}

	r.Detail = "Not available"
	r.Status = statusSkipped
	return r
}

func checkNodeModules() checkResult {
	r := checkResult{Name: "node_modules", MaxScore: 2}

	home, err := os.UserHomeDir()
	if err != nil {
		r.Status = statusSkipped
		r.Detail = "Could not read home directory"
		return r
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()

	// Use find + du -sk in a single shell command to avoid walking each dir in Go.
	out, err := exec.CommandContext(ctx, "bash", "-c",
		fmt.Sprintf(`find %q -maxdepth 4 -name node_modules -type d -not -path '*/.*' -exec du -sk {} + 2>/dev/null`, home),
	).Output()
	if err != nil && ctx.Err() == context.DeadlineExceeded {
		r.Status = statusSkipped
		r.Detail = "Scan timed out"
		return r
	}

	lines := strings.Split(strings.TrimSpace(string(out)), "\n")
	var totalBytes int64
	var count int
	for _, line := range lines {
		if line == "" {
			continue
		}
		fields := strings.Fields(line)
		if len(fields) >= 1 {
			kb, err := strconv.ParseInt(fields[0], 10, 64)
			if err == nil {
				totalBytes += kb * 1024
				count++
			}
		}
	}

	if count == 0 {
		r.Status = statusPass
		r.Score = 2
		r.Detail = "No node_modules found"
		return r
	}

	gb := float64(totalBytes) / (1024 * 1024 * 1024)
	r.Detail = fmt.Sprintf("%s across %d directories", humanizeBytes(totalBytes), count)

	if gb > nodeModulesHighGB {
		r.Status = statusFail
		r.Score = 0
	} else if gb > nodeModulesMedGB {
		r.Status = statusWarn
		r.Score = 1
	} else {
		r.Status = statusPass
		r.Score = 2
	}
	return r
}

func checkIOSBackups() checkResult {
	r := checkResult{Name: "iOS backups", MaxScore: 1}

	backupDir := expandHome("~/Library/Application Support/MobileSync/Backup")
	info, err := os.Stat(backupDir)
	if err != nil || !info.IsDir() {
		r.Status = statusPass
		r.Score = 1
		r.Detail = "No iOS backups"
		return r
	}

	size := dirSizeBytes(backupDir)
	gb := float64(size) / (1024 * 1024 * 1024)
	r.Detail = humanizeBytes(size) + " in iOS backups"

	if gb >= iosBackupHighGB {
		r.Status = statusWarn
		r.Score = 0
	} else {
		r.Status = statusPass
		r.Score = 1
	}
	return r
}

// dirSizeBytes returns the total size of all files in a directory tree.
func dirSizeBytes(path string) int64 {
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "du", "-sk", path).Output()
	if err != nil {
		return 0
	}
	fields := strings.Fields(string(out))
	if len(fields) > 0 {
		kb, err := strconv.ParseInt(fields[0], 10, 64)
		if err == nil {
			return kb * 1024
		}
	}
	return 0
}

func expandHome(path string) string {
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return home + path[1:]
		}
	}
	return path
}
