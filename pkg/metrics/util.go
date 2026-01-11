package metrics

import (
	"fmt"
	"strconv"
)

func humanBytes(v uint64) string {
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
