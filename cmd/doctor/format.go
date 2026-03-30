//go:build darwin

package main

import (
	"fmt"
	"strings"
)

func humanizeBytes(bytes int64) string {
	const (
		KB = 1024
		MB = KB * 1024
		GB = MB * 1024
		TB = GB * 1024
	)
	switch {
	case bytes >= TB:
		return fmt.Sprintf("%.1f TB", float64(bytes)/float64(TB))
	case bytes >= GB:
		return fmt.Sprintf("%.1f GB", float64(bytes)/float64(GB))
	case bytes >= MB:
		return fmt.Sprintf("%.1f MB", float64(bytes)/float64(MB))
	case bytes >= KB:
		return fmt.Sprintf("%.1f KB", float64(bytes)/float64(KB))
	default:
		return fmt.Sprintf("%d B", bytes)
	}
}

func progressBar(score, maxScore, width int) string {
	if maxScore == 0 {
		return strings.Repeat("░", width)
	}
	filled := min(score*width/maxScore, width)
	empty := max(width-filled, 0)

	color := colorGreen
	ratio := float64(score) / float64(maxScore)
	if ratio < 0.6 {
		color = colorRed
	} else if ratio < 0.8 {
		color = colorYellow
	}

	return fmt.Sprintf("%s%s%s%s%s",
		color, strings.Repeat("█", filled),
		colorGray, strings.Repeat("░", empty), colorReset)
}

func statusIcon(s checkStatus) string {
	switch s {
	case statusPass:
		return colorGreen + "✓" + colorReset
	case statusWarn:
		return colorYellow + "⚠" + colorReset
	case statusFail:
		return colorRed + "✗" + colorReset
	case statusSkipped:
		return colorGray + "–" + colorReset
	default:
		return " "
	}
}

func categoryIcon(score, maxScore int) string {
	if maxScore == 0 {
		return statusIcon(statusSkipped)
	}
	ratio := float64(score) / float64(maxScore)
	if ratio >= 0.8 {
		return statusIcon(statusPass)
	}
	if ratio >= 0.6 {
		return statusIcon(statusWarn)
	}
	return statusIcon(statusFail)
}
