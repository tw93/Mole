// Package main provides the mo status command for real-time system monitoring.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const refreshInterval = time.Second

var (
	Version   = "dev"
	BuildTime = ""

	// Command-line flags
	jsonOutput       = flag.Bool("json", false, "output metrics as JSON instead of TUI")
	procCPUThreshold = flag.Float64("proc-cpu-threshold", 100, "alert when a process stays above this CPU percent")
	procCPUWindow    = flag.Duration("proc-cpu-window", 5*time.Minute, "continuous duration a process must exceed the CPU threshold")
	procCPUAlerts    = flag.Bool("proc-cpu-alerts", true, "enable persistent high-CPU process alerts")
)

func shouldUseJSONOutput(forceJSON bool, stdout *os.File) bool {
	if forceJSON {
		return true
	}
	if stdout == nil {
		return false
	}
	info, err := stdout.Stat()
	if err != nil {
		return false
	}
	return (info.Mode() & os.ModeCharDevice) == 0
}

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

// padViewToHeight ensures the rendered frame always overwrites the full
// terminal region by padding with empty lines up to the current height.
func padViewToHeight(view string, height int) string {
	if height <= 0 {
		return view
	}

	contentHeight := lipgloss.Height(view)
	if contentHeight >= height {
		return view
	}

	return view + strings.Repeat("\n", height-contentHeight)
}

// getConfigPath returns the path to the status preferences file.
func getConfigPath() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	return filepath.Join(home, ".config", "mole", "status_prefs")
}

// loadCatHidden loads the cat hidden preference from config file.
func loadCatHidden() bool {
	path := getConfigPath()
	if path == "" {
		return false
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return false
	}
	return strings.TrimSpace(string(data)) == "cat_hidden=true"
}

// saveCatHidden saves the cat hidden preference to config file.
func saveCatHidden(hidden bool) {
	path := getConfigPath()
	if path == "" {
		return
	}
	// Ensure directory exists
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0755); err != nil {
		return
	}
	value := "cat_hidden=false"
	if hidden {
		value = "cat_hidden=true"
	}
	_ = os.WriteFile(path, []byte(value+"\n"), 0644)
}

func newModel() model {
	return model{
		collector: NewCollector(processWatchOptionsFromFlags()),
		catHidden: loadCatHidden(),
	}
}

func processWatchOptionsFromFlags() ProcessWatchOptions {
	return ProcessWatchOptions{
		Enabled:      *procCPUAlerts,
		CPUThreshold: *procCPUThreshold,
		Window:       *procCPUWindow,
	}
}

func validateFlags() error {
	if *procCPUThreshold < 0 {
		return fmt.Errorf("--proc-cpu-threshold must be >= 0")
	}
	if *procCPUWindow <= 0 {
		return fmt.Errorf("--proc-cpu-window must be > 0")
	}
	return nil
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
			// Toggle cat visibility and persist preference
			m.catHidden = !m.catHidden
			saveCatHidden(m.catHidden)
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

	termWidth := m.width
	if termWidth <= 0 {
		termWidth = 80
	}

	header, mole := renderHeader(m.metrics, m.errMessage, m.animFrame, termWidth, m.catHidden)
	alertBar := renderProcessAlertBar(m.metrics.ProcessAlerts, termWidth)

	var cardContent string
	if termWidth <= 80 {
		cardWidth := termWidth
		if cardWidth > 2 {
			cardWidth -= 2
		}
		cards := buildCards(m.metrics, cardWidth)

		var rendered []string
		for i, c := range cards {
			if i > 0 {
				rendered = append(rendered, "")
			}
			rendered = append(rendered, renderCard(c, cardWidth, 0))
		}
		cardContent = lipgloss.JoinVertical(lipgloss.Left, rendered...)
	} else {
		cardWidth := max(24, termWidth/2-4)
		cards := buildCards(m.metrics, cardWidth)
		cardContent = renderTwoColumns(cards, termWidth)
	}

	// Combine header, mole, and cards with consistent spacing
	parts := []string{header}
	if alertBar != "" {
		parts = append(parts, alertBar)
	}
	if mole != "" {
		parts = append(parts, mole)
	}
	parts = append(parts, cardContent)
	output := lipgloss.JoinVertical(lipgloss.Left, parts...)
	return padViewToHeight(output, m.height)
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

// runJSONMode collects metrics once and outputs as JSON.
func runJSONMode() {
	collector := NewCollector(processWatchOptionsFromFlags())

	// First collection initializes network state (returns nil for network)
	_, _ = collector.Collect()

	// Wait 1 second for network rate calculation
	time.Sleep(1 * time.Second)

	// Second collection has actual network data
	data, err := collector.Collect()
	if err != nil {
		fmt.Fprintf(os.Stderr, "error collecting metrics: %v\n", err)
		os.Exit(1)
	}

	encoder := json.NewEncoder(os.Stdout)
	encoder.SetIndent("", "  ")
	if err := encoder.Encode(data); err != nil {
		fmt.Fprintf(os.Stderr, "error encoding JSON: %v\n", err)
		os.Exit(1)
	}
}

// runTUIMode runs the interactive terminal UI.
func runTUIMode() {
	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "system status error: %v\n", err)
		os.Exit(1)
	}
}

func main() {
	flag.Parse()
	if err := validateFlags(); err != nil {
		fmt.Fprintf(os.Stderr, "%v\n", err)
		os.Exit(2)
	}

	if shouldUseJSONOutput(*jsonOutput, os.Stdout) {
		runJSONMode()
	} else {
		runTUIMode()
	}
}

func activeAlerts(alerts []ProcessAlert) []ProcessAlert {
	var active []ProcessAlert
	for _, alert := range alerts {
		if alert.Status == "active" {
			active = append(active, alert)
		}
	}
	return active
}
