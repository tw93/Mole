package main

import (
	"context"
	"errors"
	"fmt"
	"math"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/charmbracelet/x/ansi"
)

// Left-aligned block elements filling 1/8 through 7/8 of a cell, indexed by
// eighths. Index 0 is unused: no eighths means nothing to draw.
var subCellBlocks = [8]string{"", "▏", "▎", "▍", "▌", "▋", "▊", "▉"}

// displayPath shortens the user profile to "~". Windows paths compare
// case-insensitively, and the prefix must end at a separator so a sibling
// profile such as C:\Users\me2 is never rewritten.
func displayPath(path string) string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return path
	}
	home = strings.TrimRight(home, `\/`)
	if len(path) < len(home) || !strings.EqualFold(path[:len(home)], home) {
		return path
	}
	rest := path[len(home):]
	if rest != "" && rest[0] != filepath.Separator && rest[0] != '/' {
		return path
	}
	return "~" + rest
}

// truncateMiddle trims the middle, keeping head and tail.
func truncateMiddle(s string, maxWidth int) string {
	maxWidth = max(0, maxWidth)
	width := displayWidth(s)
	if width <= maxWidth {
		return s
	}
	if maxWidth < 10 {
		return ansi.Truncate(s, maxWidth, "")
	}
	head := (maxWidth - 3) / 3
	tail := maxWidth - 3 - head
	// TruncateLeft keeps a wide grapheme that straddles the cut, so an odd tail
	// over CJK or flags would overshoot the budget by one cell; cut once more.
	cut := width - tail
	right := ansi.TruncateLeft(s, cut, "")
	for displayWidth(right) > tail {
		cut++
		right = ansi.TruncateLeft(s, cut, "")
	}
	return ansi.Truncate(s, head, "") + "..." + right
}

func formatNumber(n int64) string {
	if n < 1000 {
		return fmt.Sprintf("%d", n)
	}
	if n < 1000000 {
		return fmt.Sprintf("%.1fk", float64(n)/1000)
	}
	return fmt.Sprintf("%.1fM", float64(n)/1000000)
}

// humanizeBytes uses binary (1024-based) units labeled KB/MB/GB, the
// convention Windows Explorer uses, the way the macOS analyzer follows Finder.
func humanizeBytes(size int64) string {
	if size < 0 {
		return "0 B"
	}
	const unit = 1024
	if size < unit {
		return fmt.Sprintf("%d B", size)
	}
	div, exp := int64(unit), 0
	for n := size / unit; n >= unit; n /= unit {
		div *= unit
		exp++
	}
	value := float64(size) / float64(div)
	// One decimal rounds 1023.95 up to 1024.0, which is the next unit's 1.0.
	if value >= 1023.95 && exp < len("KMGTPE")-1 {
		value /= unit
		exp++
	}
	return fmt.Sprintf("%.1f %cB", value, "KMGTPE"[exp])
}

func formatPercent(percent float64, known bool) string {
	const width = 6
	if !known {
		// No percentage is meaningful until the denominator is complete.
		return strings.Repeat(" ", width)
	}

	label := fmt.Sprintf("%.1f%%", percent)
	if percent > 0 && percent < 0.1 {
		label = "< 0.1%"
	}
	return fmt.Sprintf("%*s", width, label)
}

func coloredProgressBar(value, maxValue int64, percent float64, width int) string {
	if width <= 0 {
		return ""
	}
	if value <= 0 || maxValue <= 0 {
		return strings.Repeat(" ", width)
	}

	var barColor string
	if percent >= 50 {
		barColor = colorRed
	} else if percent >= 20 {
		barColor = colorYellow
	} else if percent >= 5 {
		barColor = colorBlue
	} else {
		barColor = colorGreen
	}

	// Length is measured in eighths of a cell, taken in float64 so a huge byte
	// count cannot overflow into a negative repeat count.
	eighths := max(int64(math.Round(float64(value)/float64(maxValue)*float64(width)*8)), 0)
	full := int(eighths / 8)
	remainder := int(eighths % 8)
	if full >= width {
		return barColor + strings.Repeat("█", width) + colorReset
	}

	if full == 0 && remainder == 0 {
		// Under an eighth of a cell there is no honest length left to draw, but
		// the row still holds a real value; a gray tick holds the place.
		return colorGray + subCellBlocks[1] + strings.Repeat(" ", width-1) + colorReset
	}

	var bar strings.Builder
	bar.WriteString(barColor)
	bar.WriteString(strings.Repeat("█", full))
	drawn := full
	if remainder > 0 {
		bar.WriteString(subCellBlocks[remainder])
		drawn++
	}
	bar.WriteString(strings.Repeat(" ", width-drawn))
	bar.WriteString(colorReset)
	return bar.String()
}

// Width and truncation share the terminal library's grapheme rules, including
// combining accents, halfwidth kana, CJK punctuation and joined emoji.
func displayWidth(s string) int { return ansi.StringWidth(s) }

// Shrink the bar before the name column when a console is narrower than the
// standard layout. Keep the existing 24-cell bar on wide terminals.
func calculateBarWidth(termWidth int) int {
	if termWidth <= 0 {
		termWidth = 85
	}
	return min(barWidth, max(0, termWidth-61))
}

func calculateNameWidth(termWidth int) int {
	if termWidth <= 0 {
		termWidth = 85
	}
	const fixedWithoutBar = 37
	return min(60, max(1, termWidth-fixedWithoutBar-calculateBarWidth(termWidth)))
}

func padName(name string, targetWidth int) string {
	currentWidth := displayWidth(name)
	if currentWidth >= targetWidth {
		return name
	}
	return name + strings.Repeat(" ", targetWidth-currentWidth)
}

// accessTrackedFrom reads the NtfsDisableLastAccessUpdate value: bit 0 set means
// NTFS does not record openings (1, 0x80000001 user managed, 0x80000003 system
// managed); 0, 0x80000000 and 0x80000002 mean it does.
func accessTrackedFrom(value uint64) bool {
	return value&1 == 0
}

// formatUnusedTime formats time since last access. Without NTFS recording
// openings, which is the default on a system volume over 128 GB, an often-opened
// file reads as a year old, so nothing is claimed.
func formatUnusedTime(lastAccess time.Time) string {
	if lastAccess.IsZero() || !lastAccessTracked() {
		return ""
	}

	duration := time.Since(lastAccess)
	days := int(duration.Hours() / 24)

	if days < 90 {
		return ""
	}

	months := days / 30
	years := days / 365

	if years >= 2 {
		return fmt.Sprintf(">%dyr", years)
	} else if years >= 1 {
		return ">1yr"
	} else if months >= 3 {
		return fmt.Sprintf(">%dmo", months)
	}

	return ""
}

func measurementErrorReason(err error) string {
	switch {
	case errors.Is(err, context.DeadlineExceeded):
		return "timed out"
	case errors.Is(err, context.Canceled):
		return "cancelled"
	case isPermissionFailure(err):
		return "access denied"
	}
	var pathFailure *os.PathError
	if errors.As(err, &pathFailure) {
		return pathFailure.Err.Error()
	}
	return "read error"
}

// Partial sizes are measured bytes, so '+' marks that additional bytes may be
// missing. An unavailable measurement must never look like a measured zero.
func measuredSizeLabel(size int64, state scanState) string {
	if state == scanUnavailable || (state == scanPartial && size == 0) {
		return "unknown"
	}
	label := humanizeBytes(size)
	if state == scanPartial {
		label += "+"
	}
	return label
}

// sizeColumn fills the 10-column size field with the partial marker in its
// own last column, so units line up whether or not a row is partial.
func sizeColumn(label string) string {
	if trimmed, partial := strings.CutSuffix(label, "+"); partial {
		return fmt.Sprintf("%9s+", trimmed)
	}
	return fmt.Sprintf("%9s ", label)
}

func scanSummary(size int64, state scanState) string {
	if state != scanComplete {
		return "Partial scan · " + measuredSizeLabel(size, state)
	}
	return "Scanned " + humanizeBytes(size)
}
