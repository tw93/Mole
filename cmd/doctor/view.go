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
		case "q", "ctrl+c":
			return m, tea.Quit
		case "up", "k":
			if m.selected > 0 {
				m.selected--
			}
		case "down", "j":
			if m.selected+1 < len(m.result.Categories) {
				m.selected++
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

	// Categories.
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

		fmt.Fprintf(&b, "%s%s %s%s%s %s\n",
			cursor, arrow, name, strings.Repeat(" ", padding), icon, scoreStr)

		// Expanded checks.
		if m.expanded[i] {
			for _, check := range cat.Checks {
				checkIcon := statusIcon(check.Status)
				fmt.Fprintf(&b, "      %s %s — %s\n",
					checkIcon, check.Name, check.Detail)
			}
			fmt.Fprintln(&b)
		}
	}

	// Footer.
	fmt.Fprintln(&b)
	fmt.Fprintf(&b, "  %s↑↓%s navigate  %sEnter%s expand  %sq%s quit\n",
		colorBold, colorReset, colorBold, colorReset, colorBold, colorReset)

	// Tips.
	if len(m.result.Tips) > 0 {
		fmt.Fprintf(&b, "  ─────────────────────────────────────────\n")
		fmt.Fprintf(&b, "  %sTip:%s %s\n", colorCyan, colorReset, m.result.Tips[0])
	}

	fmt.Fprintln(&b)
	return b.String()
}
