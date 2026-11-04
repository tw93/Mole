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

// BytesBin formats an unsigned byte count using binary (1024-based) units with
// a trailing space and unit label (e.g. "1.0 GB"). Boundary uses '>' so values
// at exactly 1<<n stay in the smaller unit (e.g. 1024 -> "1024 B").
func BytesBin(v uint64) string {
	switch {
	case v > 1<<40:
		return fmt.Sprintf("%.1f TB", float64(v)/(1<<40))
	case v > 1<<30:
		return fmt.Sprintf("%.1f GB", float64(v)/(1<<30))
	case v > 1<<20:
		return fmt.Sprintf("%.1f MB", float64(v)/(1<<20))
	case v > 1<<10:
		return fmt.Sprintf("%.1f KB", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10) + " B"
	}
}

// BytesBinShort formats an unsigned byte count using binary units, no decimal
// places, single-letter suffix and no space (e.g. "100G"). Boundary uses '>='
// so values at exactly 1<<n promote to the larger unit.
func BytesBinShort(v uint64) string {
	switch {
	case v >= 1<<40:
		return fmt.Sprintf("%.0fT", float64(v)/(1<<40))
	case v >= 1<<30:
		return fmt.Sprintf("%.0fG", float64(v)/(1<<30))
	case v >= 1<<20:
		return fmt.Sprintf("%.0fM", float64(v)/(1<<20))
	case v >= 1<<10:
		return fmt.Sprintf("%.0fK", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10)
	}
}

// BytesBinCompact formats an unsigned byte count using binary units, one
// decimal place, single-letter suffix and no space (e.g. "1.5G"). Boundary
// uses '>=' to mirror BytesBinShort.
func BytesBinCompact(v uint64) string {
	switch {
	case v >= 1<<40:
		return fmt.Sprintf("%.1fT", float64(v)/(1<<40))
	case v >= 1<<30:
		return fmt.Sprintf("%.1fG", float64(v)/(1<<30))
	case v >= 1<<20:
		return fmt.Sprintf("%.1fM", float64(v)/(1<<20))
	case v >= 1<<10:
		return fmt.Sprintf("%.1fK", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10)
	}
}
