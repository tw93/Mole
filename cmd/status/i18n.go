package main

import (
	"fmt"
	"os"
)

// isTurkish returns true if the system is running in Turkish locale.
// The parent shell (lib/core/tr.sh) exports MOLE_IS_TURKISH_SYSTEM before
// launching this binary.
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

func tf(formatEn, formatTr string, args ...any) string {
	if isTurkish() {
		return fmt.Sprintf(formatTr, args...)
	}
	return fmt.Sprintf(formatEn, args...)
}
