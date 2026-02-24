package metrics

import (
	"fmt"
	"strconv"
)

// HumanBytes formats bytes into a human-readable string with units (e.g., "1.5 GB").
func HumanBytes(v uint64) string {
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

// HumanBytesShort formats bytes into a short string (e.g., "500G").
func HumanBytesShort(v uint64) string {
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

// HumanBytesCompact formats bytes with one decimal place (e.g., "1.5G").
func HumanBytesCompact(v uint64) string {
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

// FormatRate formats a network rate in MB/s.
func FormatRate(mb float64) string {
	if mb < 0.01 {
		return "0 MB/s"
	}
	if mb < 1 {
		return fmt.Sprintf("%.2f MB/s", mb)
	}
	if mb < 10 {
		return fmt.Sprintf("%.1f MB/s", mb)
	}
	return fmt.Sprintf("%.0f MB/s", mb)
}
