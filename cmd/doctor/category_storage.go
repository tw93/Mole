//go:build darwin

package main

import (
	"os"
	"os/exec"
	"strconv"
	"strings"
	"syscall"
)

func checkStorage() categoryResult {
	cat := categoryResult{
		Name:     "Storage",
		MaxScore: scoreStorage,
	}

	cat.Checks = append(cat.Checks, checkFreeSpace())
	cat.Checks = append(cat.Checks, checkRecoverableCache())
	cat.Checks = append(cat.Checks, checkPurgeableSpace())

	for _, c := range cat.Checks {
		cat.Score += c.Score
	}
	if cat.Score > cat.MaxScore {
		cat.Score = cat.MaxScore
	}
	return cat
}

func checkFreeSpace() checkResult {
	r := checkResult{Name: "Free space", MaxScore: 10}

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
		r.Score = 5
	} else {
		r.Status = statusPass
		r.Score = 10
	}
	return r
}

func checkRecoverableCache() checkResult {
	r := checkResult{Name: "Recoverable cache", MaxScore: 10}

	cachePaths := []string{
		"~/Library/Caches",
		"~/Library/Logs",
	}

	var totalBytes int64
	for _, p := range cachePaths {
		expanded := expandHome(p)
		out, err := exec.Command("du", "-sk", expanded).Output()
		if err != nil {
			continue
		}
		fields := strings.Fields(string(out))
		if len(fields) > 0 {
			kb, _ := strconv.ParseInt(fields[0], 10, 64)
			totalBytes += kb * 1024
		}
	}

	gb := float64(totalBytes) / (1024 * 1024 * 1024)
	r.Detail = humanizeBytes(totalBytes) + " in caches"

	if gb > cacheRecoverableHighGB {
		r.Status = statusWarn
		r.Score = 5
	} else if gb > cacheRecoverableMedGB {
		r.Status = statusPass
		r.Score = 8
	} else {
		r.Status = statusPass
		r.Score = 10
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

	for _, line := range strings.Split(string(out), "\n") {
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

func expandHome(path string) string {
	if strings.HasPrefix(path, "~/") {
		home, err := os.UserHomeDir()
		if err == nil {
			return home + path[1:]
		}
	}
	return path
}
