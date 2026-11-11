// Package units centralizes byte-size formatting helpers shared by the analyze
// and status commands.
//
// The two callers intentionally use different conventions: analyze formats
// disk-related figures with SI (1000-based) units to match Finder/diskutil,
// while status reports memory and live counters with binary (1024-based)
// units to match macOS Activity Monitor and gopsutil. Both styles live here so
// that any future tweak (precision, rounding, label set) stays in one place.
package units

import (
	"fmt"
	"strconv"
)

// BytesSI formats a signed byte count using SI (1000-based) units, matching
// Finder/diskutil. Negative inputs are clamped to "0 B".
func BytesSI(size int64) string {
	if size < 0 {
		return "0 B"
	}
	const unit = 1000
	if size < unit {
		return fmt.Sprintf("%d B", size)
	}
	div, exp := int64(unit), 0
	for n := size / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	value := float64(size) / float64(div)
	label := fmt.Sprintf("%.1f", value)
	// One decimal place can round a value just under the next unit up to
	// "1000.0" (999,999 B -> "1000.0 kB"); Finder and diskutil show that size
	// as 1 MB, so step up a unit instead. int64 tops out at 9.2 EB, so the
	// last prefix is never stepped past.
	if label == "1000.0" {
		value /= unit
		exp++
		label = fmt.Sprintf("%.1f", value)
	}
	return fmt.Sprintf("%s %cB", label, "kMGTPE"[exp])
}

// binScale picks the binary unit for v (0 = bytes, 1 = K ... 4 = T) and the
// value in that unit. When rounding to prec decimals would print the unit base
// (1024) and a larger unit exists, it steps up one unit, so no size prints as
// "1024.0 MB" or "1024K". Exactly 1<<n therefore belongs to the larger unit.
func binScale(v uint64, prec int) (float64, int) {
	exp := 0
	for exp < 4 && v >= uint64(1)<<(10*uint(exp+1)) {
		exp++
	}
	value := float64(v) / float64(uint64(1)<<(10*uint(exp)))
	if exp < 4 && fmt.Sprintf("%.*f", prec, value) == fmt.Sprintf("%.*f", prec, 1024.0) {
		value /= 1024
		exp++
	}
	return value, exp
}

// BytesBin formats an unsigned byte count using binary (1024-based) units with
// a trailing space and unit label (e.g. "1.0 GB"). Values equal to or rounding
// up to 1024 of a unit step up to the next one (1024 -> "1.0 KB").
func BytesBin(v uint64) string {
	value, exp := binScale(v, 1)
	if exp == 0 {
		return strconv.FormatUint(v, 10) + " B"
	}
	return fmt.Sprintf("%.1f %cB", value, "KMGT"[exp-1])
}

// BytesBinShort formats an unsigned byte count using binary units, no decimal
// places, single-letter suffix and no space (e.g. "100G"). Values equal to or
// rounding up to 1024 of a unit step up to the next one.
func BytesBinShort(v uint64) string {
	value, exp := binScale(v, 0)
	if exp == 0 {
		return strconv.FormatUint(v, 10)
	}
	return fmt.Sprintf("%.0f%c", value, "KMGT"[exp-1])
}

// BytesBinCompact formats an unsigned byte count using binary units, one
// decimal place, single-letter suffix and no space (e.g. "1.5G"). Stepping up
// mirrors BytesBinShort.
func BytesBinCompact(v uint64) string {
	value, exp := binScale(v, 1)
	if exp == 0 {
		return strconv.FormatUint(v, 10)
	}
	return fmt.Sprintf("%.1f%c", value, "KMGT"[exp-1])
}
