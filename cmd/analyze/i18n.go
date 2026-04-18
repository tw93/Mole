//go:build darwin

package main

import (
	"fmt"
	"os"
)

// isTurkish returns true if the system is running in Turkish locale.
// This mirrors the shell-side detection in lib/core/tr.sh — the parent
// shell exports MOLE_IS_TURKISH_SYSTEM before launching the Go binary.
func isTurkish() bool {
	return os.Getenv("MOLE_IS_TURKISH_SYSTEM") == "true"
}

// t returns the Turkish translation when running on a Turkish system,
// or the English original otherwise.
func t(en, tr string) string {
	if isTurkish() {
		return tr
	}
	return en
}

// tf selects the format string by locale then applies fmt.Sprintf.
func tf(formatEn, formatTr string, args ...any) string {
	if isTurkish() {
		return fmt.Sprintf(formatTr, args...)
	}
	return fmt.Sprintf(formatEn, args...)
}
