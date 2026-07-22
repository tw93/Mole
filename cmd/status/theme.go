package main

import "github.com/charmbracelet/lipgloss"

// theme.go is the design system for the status TUI: one source of truth for
// colors, text styles, layout sizes and section icons. Render code should use
// the semantic styles and tokens below rather than inline hex or magic numbers.

// Palette — raw colors. Prefer the semantic styles over referencing these
// directly, so a re-theme only touches this block.
var (
	colorAccent    = lipgloss.Color("#BD93F9") // primary purple (model name, bars)
	colorTitle     = lipgloss.Color("#C79FD7") // section titles
	colorOk        = lipgloss.Color("#A5D6A7") // healthy / low usage
	colorScoreHigh = lipgloss.Color("#87FF87") // excellent health score
	colorScoreMid  = lipgloss.Color("#87D787") // good health score
	colorWarn      = lipgloss.Color("#FFD75F") // caution / mid usage
	colorDanger    = lipgloss.Color("#FF5F5F") // critical / high usage
	colorMuted     = lipgloss.Color("#737373") // secondary text
	colorFaint     = lipgloss.Color("#404040") // separators / rules
	colorInkOnWarn = lipgloss.Color("#2B1200") // text drawn on a warn background
)

// Semantic text styles — the vocabulary render code speaks in.
var (
	titleStyle   = lipgloss.NewStyle().Foreground(colorTitle).Bold(true)
	subtleStyle  = lipgloss.NewStyle().Foreground(colorMuted)
	warnStyle    = lipgloss.NewStyle().Foreground(colorWarn)
	dangerStyle  = lipgloss.NewStyle().Foreground(colorDanger).Bold(true)
	okStyle      = lipgloss.NewStyle().Foreground(colorOk)
	lineStyle    = lipgloss.NewStyle().Foreground(colorFaint)
	primaryStyle = lipgloss.NewStyle().Foreground(colorAccent)

	alertBarStyle = lipgloss.NewStyle().
			Foreground(colorInkOnWarn).
			Background(colorWarn).
			Bold(true).
			Padding(0, 1)
)

// getScoreStyle maps a 0-100 health score to its band style.
func getScoreStyle(score int) lipgloss.Style {
	switch {
	case score >= scoreExcellentThreshold:
		return lipgloss.NewStyle().Foreground(colorScoreHigh).Bold(true)
	case score >= scoreGoodThreshold:
		return lipgloss.NewStyle().Foreground(colorScoreMid).Bold(true)
	case score >= scoreFairThreshold:
		return lipgloss.NewStyle().Foreground(colorWarn).Bold(true)
	default:
		// Unified with the danger red (was a near-duplicate #FF6B6B).
		return lipgloss.NewStyle().Foreground(colorDanger).Bold(true)
	}
}

// Layout tokens — sizes shared across cards.
const (
	colWidth            = 38 // default card column width
	metricLabelWidth    = 6  // left-hand label column inside a card ("Usage", "Core1", ...)
	processMemoryWidth  = 7
	processWideMinWidth = 46
)

// Section icons.
const (
	iconCPU     = "◉"
	iconMemory  = "◫"
	iconGPU     = "◧"
	iconDisk    = "▥"
	iconNetwork = "⇅"
	iconBattery = "◪"
	iconSensors = "◈"
	iconProcs   = "❊"
)
