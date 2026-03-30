//go:build darwin

package main

import (
	"fmt"
	"strings"

	tea "github.com/charmbracelet/bubbletea"
)

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "ctrl+c", "esc":
			if diagCancel != nil {
				diagCancel()
			}
			return m, tea.Quit
		case "up", "k":
			if m.selected > 0 {
				m.selected--
				m.ensureSelectedVisible()
			}
		case "down", "j":
			if m.selected+1 < len(m.result.Categories) {
				m.selected++
				m.ensureSelectedVisible()
			}
		case "enter", " ":
			m.expanded[m.selected] = !m.expanded[m.selected]
		}
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	case diagnosisDoneMsg:
		m.result = msg.result
		m.ready = true
		m.running = false
		m.err = msg.err
	case tickMsg:
		m.spinner = (m.spinner + 1) % len(spinnerFrames)
		if m.running {
			return m, tickSpinner()
		}
	}
	return m, nil
}

// ensureSelectedVisible adjusts the scroll offset so the selected category is on screen.
func (m *model) ensureSelectedVisible() {
	// Estimate the line number of the selected category within the scrollable area.
	line := 0
	for i := 0; i < m.selected; i++ {
		line++ // category header line
		if m.expanded[i] {
			for _, check := range m.result.Categories[i].Checks {
				line++ // check line
				line += len(check.Breakdown)
			}
			line++ // blank line after expanded
		}
	}

	// Reserve lines for header (~6) and footer (~5).
	viewportHeight := m.height - 11
	if viewportHeight < 5 {
		viewportHeight = 5
	}

	if line < m.offset {
		m.offset = line
	} else if line >= m.offset+viewportHeight {
		m.offset = line - viewportHeight + 1
	}
}

func (m model) View() string {
	var b strings.Builder
	fmt.Fprintln(&b)

	if m.running {
		fmt.Fprintf(&b, "  %sMac Doctor%s\n\n", colorPurpleBold, colorReset)
		fmt.Fprintf(&b, "  %s%s%s Running checks...\n", colorCyan, spinnerFrames[m.spinner], colorReset)
		return b.String()
	}

	if m.err != nil {
		fmt.Fprintf(&b, "  %sError:%s %v\n", colorRed, colorReset, m.err)
		return b.String()
	}

	// Hardware profile header.
	hw := m.result.Hardware
	if hw.Model != "" {
		fmt.Fprintf(&b, "  %s%s · %s · %s%s\n",
			colorGray, hw.Model, hw.Chip, hw.RAM, colorReset)
		macosLine := "macOS " + hw.MacOS
		if hw.Build != "" {
			macosLine += " (" + hw.Build + ")"
		}
		if hw.SSDTotal != "" {
			macosLine += " · " + hw.SSDTotal + " SSD (" + hw.SSDFree + " free)"
		}
		fmt.Fprintf(&b, "  %s%s%s\n", colorGray, macosLine, colorReset)
		if !hw.ThermalOK {
			fmt.Fprintf(&b, "  %s⚠ Thermal throttling detected%s\n", colorYellow, colorReset)
		}
		fmt.Fprintln(&b)
	}

	// Header with score.
	scoreColor := colorGreen
	ratio := 0.0
	if m.result.MaxScore > 0 {
		ratio = float64(m.result.TotalScore) / float64(m.result.MaxScore)
	}
	if ratio < 0.6 {
		scoreColor = colorRed
	} else if ratio < 0.8 {
		scoreColor = colorYellow
	}
	fmt.Fprintf(&b, "  %sMac Doctor%s", colorPurpleBold, colorReset)
	fmt.Fprintf(&b, "                        %sScore: %d%s/%d\n",
		scoreColor, m.result.TotalScore, colorReset, m.result.MaxScore)

	// Progress bar.
	fmt.Fprintf(&b, "  %s\n\n", progressBar(m.result.TotalScore, m.result.MaxScore, 36))

	// Categories — build scrollable lines, then apply viewport.
	var catLines []string
	for i, cat := range m.result.Categories {
		cursor := "  "
		if i == m.selected {
			cursor = colorPurple + "▸ " + colorReset
		}

		arrow := "▸"
		if m.expanded[i] {
			arrow = "▾"
		}

		icon := categoryIcon(cat.Score, cat.MaxScore)
		scoreStr := fmt.Sprintf("%d/%d", cat.Score, cat.MaxScore)

		name := cat.Name
		padding := 24 - len(name)
		if padding < 1 {
			padding = 1
		}

		catLines = append(catLines, fmt.Sprintf("%s%s %s%s%s %s",
			cursor, arrow, name, strings.Repeat(" ", padding), icon, scoreStr))

		// Expanded checks.
		if m.expanded[i] {
			for _, check := range cat.Checks {
				checkIcon := statusIcon(check.Status)
				catLines = append(catLines, fmt.Sprintf("      %s %s — %s",
					checkIcon, check.Name, check.Detail))

				for _, item := range check.Breakdown {
					bdIcon := statusIcon(item.Status)
					catLines = append(catLines, fmt.Sprintf("          %s %s: %s",
						bdIcon, item.Name, humanizeBytes(item.Size)))
				}
			}
			catLines = append(catLines, "")
		}
	}

	// Apply viewport scrolling.
	viewportHeight := m.height - 11
	if viewportHeight < 5 {
		viewportHeight = 5
	}
	start := m.offset
	if start > len(catLines) {
		start = len(catLines)
	}
	end := start + viewportHeight
	if end > len(catLines) {
		end = len(catLines)
	}
	visible := catLines[start:end]

	if start > 0 {
		fmt.Fprintf(&b, "  %s↑ %d more%s\n", colorGray, start, colorReset)
	}
	for _, line := range visible {
		fmt.Fprintln(&b, line)
	}
	if end < len(catLines) {
		fmt.Fprintf(&b, "  %s↓ %d more%s\n", colorGray, len(catLines)-end, colorReset)
	}

	// Footer.
	fmt.Fprintln(&b)
	fmt.Fprintf(&b, "  %s↑↓%s navigate  %sEnter%s expand  %sq%s quit\n",
		colorBold, colorReset, colorBold, colorReset, colorBold, colorReset)

	// Tips.
	if len(m.result.Tips) > 0 {
		fmt.Fprintf(&b, "  ─────────────────────────────────────────\n")
		for i, tip := range m.result.Tips {
			if i == 0 {
				fmt.Fprintf(&b, "  %sTips:%s %s\n", colorCyan, colorReset, tip)
			} else {
				fmt.Fprintf(&b, "        %s\n", tip)
			}
		}
	}

	fmt.Fprintln(&b)
	return b.String()
}
