package main

import (
	"fmt"
	"math"
	"strconv"
)

// Byte formatting matches main's internal/units, which this branch does not
// carry: binary (1024-based) units, the same convention Task Manager uses.

// stepUp moves a scaled value to the next unit when it would print as 1024
// at the given precision (1023.95 with one decimal), since that is the next
// unit's 1.0. The largest unit (index 4, T) has no next one and stays.
func stepUp(value float64, level, decimals int) (float64, int) {
	p := math.Pow10(decimals)
	if level < 4 && math.Round(value*p) >= 1024*p {
		return value / 1024, level + 1
	}
	return value, level
}

// humanBytes formats with one decimal and a spaced unit label ("1.0 GB").
// Values at exactly 1<<n sit in the smaller unit's range, and a value that
// would print as 1024 steps up (1<<30 -> "1.0 GB", never "1024.0 MB").
func humanBytes(v uint64) string {
	level := 0
	switch {
	case v > 1<<40:
		level = 4
	case v > 1<<30:
		level = 3
	case v > 1<<20:
		level = 2
	case v > 1<<10:
		level = 1
	}
	decimals := 1
	if level == 0 {
		decimals = 0
	}
	value, level := stepUp(float64(v)/float64(uint64(1)<<(10*level)), level, decimals)
	if level == 0 {
		return strconv.FormatUint(v, 10) + " B"
	}
	return fmt.Sprintf("%.1f %cB", value, "KMGT"[level-1])
}

// humanBytesShort formats with no decimals and a one-letter suffix ("100G").
func humanBytesShort(v uint64) string {
	level := 0
	switch {
	case v >= 1<<40:
		level = 4
	case v >= 1<<30:
		level = 3
	case v >= 1<<20:
		level = 2
	case v >= 1<<10:
		level = 1
	}
	if level == 0 {
		return strconv.FormatUint(v, 10)
	}
	value, level := stepUp(float64(v)/float64(uint64(1)<<(10*level)), level, 0)
	return fmt.Sprintf("%.0f%c", value, "KMGT"[level-1])
}

// humanBytesCompact formats with one decimal and a one-letter suffix ("1.5G").
func humanBytesCompact(v uint64) string {
	level := 0
	switch {
	case v >= 1<<40:
		level = 4
	case v >= 1<<30:
		level = 3
	case v >= 1<<20:
		level = 2
	case v >= 1<<10:
		level = 1
	}
	if level == 0 {
		return strconv.FormatUint(v, 10)
	}
	value, level := stepUp(float64(v)/float64(uint64(1)<<(10*level)), level, 1)
	return fmt.Sprintf("%.1f%c", value, "KMGT"[level-1])
}
