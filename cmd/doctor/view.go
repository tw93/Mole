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
			if m.finalized && m.selected > 0 {
				m.selected--
				m.ensureSelectedVisible()
			}
		case "down", "j":
			if m.finalized && m.selected+1 < len(m.categories) {
				m.selected++
				m.ensureSelectedVisible()
			}
		case "enter", " ":
			if m.finalized {
				m.expanded[m.selected] = !m.expanded[m.selected]
			}
		}
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
	case hardwareDoneMsg:
		m.hardware = msg.hardware
		m.hardwareDone = true
	case categoryDoneMsg:
		m.categories[msg.index] = msg.result
		m.catDone[msg.index] = true
	case revealTickMsg:
		// Reveal the next category in order, if its data is ready.
		if m.revealedCount < len(m.catDone) && m.catDone[m.revealedCount] {
			m.revealedCount++
		}
		if !m.allRevealed() {
			return m, scheduleReveal()
		}
		// All revealed — finalize scores and tips.
		if !m.finalized {
			m.categories = redistributeBatteryScore(m.categories)
			m.totalScore, m.maxScore = calculateTotalScore(m.categories)
			m.tips = generateTips(m.categories)
			m.finalized = true
		}
	case tickMsg:
		m.spinner = (m.spinner + 1) % len(spinnerFrames)
		if !m.finalized {
			return m, tickSpinner()
		}
	}
	return m, nil
}

// ensureSelectedVisible adjusts the scroll offset so the selected category is on screen.
func (m *model) ensureSelectedVisible() {
	line := 0
	for i := 0; i < m.selected; i++ {
		line++ // category header line
		if m.expanded[i] {
			for _, check := range m.categories[i].Checks {
				line++
				line += len(check.Breakdown)
			}
			line++ // blank line after expanded
		}
	}

	viewportHeight := max(m.height-11, 5)

	if line < m.offset {
		m.offset = line
	} else if line >= m.offset+viewportHeight {
		m.offset = line - viewportHeight + 1
	}
}

func (m model) View() string {
	var b strings.Builder
	fmt.Fprintln(&b)

	// Hardware profile header (shown as soon as available).
	hw := m.hardware
	if m.hardwareDone && hw.Model != "" {
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

	// Title line.
	fmt.Fprintf(&b, "  %sMac Doctor%s", colorPurpleBold, colorReset)

	if m.finalized {
		// Show final score.
		scoreColor := colorGreen
		ratio := 0.0
		if m.maxScore > 0 {
			ratio = float64(m.totalScore) / float64(m.maxScore)
		}
		if ratio < 0.6 {
			scoreColor = colorRed
		} else if ratio < 0.8 {
			scoreColor = colorYellow
		}
		fmt.Fprintf(&b, "                        %sScore: %d%s/%d\n",
			scoreColor, m.totalScore, colorReset, m.maxScore)
		fmt.Fprintf(&b, "  %s\n\n", progressBar(m.totalScore, m.maxScore, 36))
	} else {
		// Show progress counter.
		fmt.Fprintf(&b, "  %s(%d/%d)%s\n\n",
			colorGray, m.revealedCount, len(m.catDone), colorReset)
	}

	if m.finalized {
		// Interactive mode — expandable categories with scroll.
		b.WriteString(m.viewInteractive())
	} else {
		// Progressive mode — streaming results.
		b.WriteString(m.viewProgressive())
	}

	// Footer.
	fmt.Fprintln(&b)
	if m.finalized {
		fmt.Fprintf(&b, "  %s↑↓%s navigate  %sEnter%s expand  %sq%s quit\n",
			colorBold, colorReset, colorBold, colorReset, colorBold, colorReset)
	} else {
		fmt.Fprintf(&b, "  %sq%s quit\n", colorBold, colorReset)
	}

	// Tips (only after finalized).
	if m.finalized && len(m.tips) > 0 {
		fmt.Fprintf(&b, "  ─────────────────────────────────────────\n")
		for i, tip := range m.tips {
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

// viewProgressive renders compact one-liners during scanning.
// Full check details only appear in the final interactive view.
func (m model) viewProgressive() string {
	var b strings.Builder

	// Compact one-liners for revealed categories.
	for i := 0; i < m.revealedCount; i++ {
		cat := m.categories[i]
		icon := categoryIcon(cat.Score, cat.MaxScore)
		padding := max(28-len(cat.Name), 1)
		bar := progressBar(cat.Score, cat.MaxScore, 12)
		fmt.Fprintf(&b, "  %s %s%s%s %s%d/%d%s\n",
			icon, cat.Name, strings.Repeat(" ", padding),
			bar, colorGray, cat.Score, cat.MaxScore, colorReset)
	}

	// Spinner for the category currently being checked.
	if m.revealedCount < len(categorySpecs) {
		spec := categorySpecs[m.revealedCount]
		frame := spinnerFrames[m.spinner]
		fmt.Fprintf(&b, "  %s%s%s %sChecking %s ...%s\n",
			colorCyan, frame, colorReset,
			colorGray, spec.name, colorReset)
	}

	return b.String()
}

// viewInteractive renders the final expandable/scrollable view.
func (m model) viewInteractive() string {
	var catLines []string
	for i, cat := range m.categories {
		arrow := "  ▸"
		if m.expanded[i] {
			arrow = "  ▾"
		}
		if i == m.selected {
			if m.expanded[i] {
				arrow = colorPurple + "▸ ▾" + colorReset
			} else {
				arrow = colorPurple + "▸ ▸" + colorReset
			}
		}

		icon := categoryIcon(cat.Score, cat.MaxScore)
		name := cat.Name
		padding := max(24-len(name), 1)
		bar := progressBar(cat.Score, cat.MaxScore, 12)

		catLines = append(catLines, fmt.Sprintf("%s %s %s%s%s %s%d/%d%s",
			arrow, name, icon, strings.Repeat(" ", padding),
			bar, colorGray, cat.Score, cat.MaxScore, colorReset))

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
	var b strings.Builder
	viewportHeight := max(m.height-11, 5)
	start := min(m.offset, len(catLines))
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

	return b.String()
}
