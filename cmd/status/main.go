package main

import (
	"fmt"
	"os"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const refreshInterval = time.Second

var (
	Version   = "dev"
	BuildTime = ""
)

type tickMsg struct{}
type animTickMsg struct{}

type metricsMsg struct {
	data MetricsSnapshot
	err  error
}

type model struct {
	collector   *Collector
	width       int
	height      int
	metrics     MetricsSnapshot
	errMessage  string
	ready       bool
	lastUpdated time.Time
	collecting  bool
	animFrame   int
	catHidden   bool // true = hidden, false = visible
}

func newModel() model {
	return model{
		collector: NewCollector(),
		catHidden: false,
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(tickAfter(0), animTick())
}

func (m model) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	switch msg := msg.(type) {
	case tea.KeyMsg:
		switch msg.String() {
		case "q", "esc", "ctrl+c":
			return m, tea.Quit
		case "k":
			// Toggle cat visibility
			m.catHidden = !m.catHidden
			return m, nil
		}
	case tea.WindowSizeMsg:
		m.width = msg.Width
		m.height = msg.Height
		return m, nil
	case tickMsg:
		if m.collecting {
			return m, nil
		}
		m.collecting = true
		return m, m.collectCmd()
	case metricsMsg:
		if msg.err != nil {
			m.errMessage = msg.err.Error()
		} else {
			m.errMessage = ""
		}
		m.metrics = msg.data
		m.lastUpdated = msg.data.CollectedAt
		m.collecting = false
		// Mark ready after first successful data collection.
		if !m.ready {
			m.ready = true
		}
		return m, tickAfter(refreshInterval)
	case animTickMsg:
		m.animFrame++
		return m, animTickWithSpeed(m.metrics.CPU.Usage)
	}
	return m, nil
}

func (m model) View() string {
	if !m.ready {
		return "Loading..."
	}

	header := renderHeader(m.metrics, m.errMessage, m.animFrame, m.width, m.catHidden)
	cardWidth := 0
	if m.width > 80 {
		cardWidth = maxInt(24, m.width/2-4)
	}
	cards := buildCards(m.metrics, cardWidth)

	if m.width <= 80 {
		var rendered []string
		for i, c := range cards {
			if i > 0 {
				rendered = append(rendered, "")
			}
			rendered = append(rendered, renderCard(c, cardWidth, 0))
		}
		result := header + "\n" + lipgloss.JoinVertical(lipgloss.Left, rendered...)
		// Add extra newline if cat is hidden for better spacing
		if m.catHidden {
			result = header + "\n\n" + lipgloss.JoinVertical(lipgloss.Left, rendered...)
		}
		return result
	}

	twoCol := renderTwoColumns(cards, m.width)
	// Add extra newline if cat is hidden for better spacing
	if m.catHidden {
		return header + "\n\n" + twoCol
	}
	return header + "\n" + twoCol
}

func (m model) collectCmd() tea.Cmd {
	return func() tea.Msg {
		data, err := m.collector.Collect()
		return metricsMsg{data: data, err: err}
	}
}

func tickAfter(delay time.Duration) tea.Cmd {
	return tea.Tick(delay, func(time.Time) tea.Msg { return tickMsg{} })
}

func animTick() tea.Cmd {
	return tea.Tick(200*time.Millisecond, func(time.Time) tea.Msg { return animTickMsg{} })
}

func animTickWithSpeed(cpuUsage float64) tea.Cmd {
	// Higher CPU = faster animation.
	interval := max(300-int(cpuUsage*2.5), 50)
	return tea.Tick(time.Duration(interval)*time.Millisecond, func(time.Time) tea.Msg { return animTickMsg{} })
}

func main() {
	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "system status error: %v\n", err)
		os.Exit(1)
	}
}
