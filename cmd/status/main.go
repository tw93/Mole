// Package main provides the mo status command for real-time system monitoring.
package main

import (
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"os"
	"strings"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

const (
	refreshInterval      = time.Second
	processWatchInterval = refreshInterval
	slowRefreshInterval  = 30 * time.Second
)

var (
	// Command-line flags
	jsonOutput       = flag.Bool("json", false, "output metrics as JSON instead of TUI")
	procCPUThreshold = flag.Float64("proc-cpu-threshold", 100, "alert when a process stays above this CPU percent")
	procCPUWindow    = flag.Duration("proc-cpu-window", 5*time.Minute, "continuous duration a process must exceed the CPU threshold")
	procCPUAlerts    = flag.Bool("proc-cpu-alerts", true, "enable persistent high-CPU process alerts")

	// Watch mode: stream NDJSON (one snapshot per line) from a single warm collector.
	watchMode     = flag.Bool("watch", false, "stream metrics continuously as newline-delimited JSON instead of the one-shot TUI/JSON")
	watchInterval = flag.String("interval", "", "with --watch, collection interval (e.g. 1s, 2s); defaults to 1s")
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

type collectionMode int

const (
	collectionFast collectionMode = iota
	collectionProcess
	collectionFull
)

type metricsMsg struct {
	data MetricsSnapshot
	err  error
	mode collectionMode
}

type model struct {
	collector     *Collector
	width         int
	height        int
	metrics       MetricsSnapshot
	errMessage    string
	ready         bool
	lastUpdated   time.Time
	lastFullAt    time.Time
	lastProcessAt time.Time
	collecting    bool
	animFrame     int
	catHidden     bool // true = hidden, false = visible
	cpuCores      int  // how many CPU cores to list; 0 = all
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

func newModel() model {
	return model{
		collector: NewCollector(processWatchOptionsFromFlags()),
		catHidden: loadCatHidden(),
		cpuCores:  loadCPUCores(),
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
		case "c":
			// Cycle how many CPU cores the card lists (2 → 4 → 8 → all) and persist.
			m.cpuCores = nextCPUCores(m.cpuCores)
			saveCPUCores(m.cpuCores)
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
		return m, m.collectCmd(m.nextCollectionMode(time.Now()))
	case metricsMsg:
		wasReady := m.ready
		if msg.err != nil {
			m.errMessage = msg.err.Error()
		} else {
			m.errMessage = ""
		}
		m.metrics = msg.data
		m.lastUpdated = msg.data.CollectedAt
		if msg.err == nil {
			recordCollectionFreshness(msg.mode, msg.data.CollectedAt, &m.lastFullAt, &m.lastProcessAt)
		}
		m.collecting = false
		// Mark ready after first successful data collection.
		if !m.ready {
			m.ready = true
		}
		delay := refreshInterval
		if !wasReady {
			delay = 0
		}
		return m, tickAfter(delay)
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
	alertBar := renderProcessAlertBar(
		m.metrics.ProcessAlerts,
		m.metrics.ProcessStale,
		m.metrics.ProcessCollectedAt,
		termWidth,
	)

	renderFrame := func(cpuCores int) string {
		var cardContent string
		if termWidth <= 80 {
			cardWidth := termWidth
			if cardWidth > 2 {
				cardWidth -= 2
			}
			cards := buildCards(m.metrics, cardWidth, cpuCores, !m.lastFullAt.IsZero())

			var rendered []string
			for i, c := range cards {
				if i > 0 {
					rendered = append(rendered, "")
				}
				rendered = append(rendered, renderCard(c, cardWidth))
			}
			cardContent = lipgloss.JoinVertical(lipgloss.Left, rendered...)
		} else {
			cardWidth := max(24, termWidth/2-4)
			cards := buildCards(m.metrics, cardWidth, cpuCores, !m.lastFullAt.IsZero())
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
		return lipgloss.JoinVertical(lipgloss.Left, parts...)
	}

	// Every extra core is another card row, and the frame has no scrollback: on
	// a 20-core Mac "all" adds ~18 lines and pushes the lower cards off a short
	// window. Step the preference back down until the frame fits; the stored
	// preference is untouched, so a taller window gets it back.
	cpuCores := m.cpuCores
	output := renderFrame(cpuCores)
	for m.height > 0 && lipgloss.Height(output) > m.height && cpuCores != cpuCoresCycle[0] {
		cpuCores = smallerCPUCores(cpuCores)
		output = renderFrame(cpuCores)
	}
	return padViewToHeight(output, m.height)
}

func (m model) nextCollectionMode(now time.Time) collectionMode {
	return nextCollectionMode(m.ready, m.lastFullAt, m.lastProcessAt, now)
}

func nextCollectionMode(ready bool, lastFullAt, lastProcessAt, now time.Time) collectionMode {
	if !ready {
		return collectionFast
	}
	if lastFullAt.IsZero() || now.Sub(lastFullAt) >= slowRefreshInterval {
		return collectionFull
	}
	if lastProcessAt.IsZero() || now.Sub(lastProcessAt) >= processWatchInterval {
		return collectionProcess
	}
	return collectionFast
}

func recordCollectionFreshness(mode collectionMode, collectedAt time.Time, lastFullAt, lastProcessAt *time.Time) {
	if mode == collectionFull {
		*lastFullAt = collectedAt
	}
	if mode == collectionProcess || mode == collectionFull {
		*lastProcessAt = collectedAt
	}
}

func (m model) collectCmd(mode collectionMode) tea.Cmd {
	return func() tea.Msg {
		var (
			data MetricsSnapshot
			err  error
		)
		switch mode {
		case collectionFull:
			data, err = m.collector.Collect()
		case collectionProcess:
			data, err = m.collector.CollectProcesses()
		default:
			data, err = m.collector.CollectFast()
		}
		return metricsMsg{data: data, err: err, mode: mode}
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

func parseWatchInterval(raw string) (time.Duration, error) {
	if raw == "" {
		return refreshInterval, nil
	}

	d, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("invalid --interval %q (want e.g. 1s, 2s): %w", raw, err)
	}
	if d <= 0 {
		return 0, fmt.Errorf("invalid --interval %q (must be > 0)", raw)
	}
	return d, nil
}

// usageText is the help every other Mole subcommand prints by hand. The Go flag
// package would otherwise render "Usage of /usr/local/bin/status-go:", naming a
// bundled binary the user never typed, so the text is written out here instead.
const usageText = `Usage: mo status [OPTIONS]

Monitor system health. Without options it opens the interactive dashboard, and
switches to a single JSON snapshot when stdout is not a terminal.

Options:
  --json                          Output one metrics snapshot as JSON
  --watch                         Stream snapshots as newline-delimited JSON
  --interval DURATION             With --watch, collection interval (default 1s)
  --proc-cpu-alerts               Enable high-CPU process alerts (default true)
  --proc-cpu-threshold PERCENT    Alert above this CPU percent (default 100)
  --proc-cpu-window DURATION      Time above the threshold before alerting (default 5m)
  -h, --help                      Show this help message

Examples:
  mo status                       Interactive dashboard
  mo status --json                One machine-readable snapshot
  mo status --watch --interval 2s Continuous NDJSON stream
`

// parseArgs applies Mole's CLI conventions to the flag package: help goes to
// stdout and exits 0, and a bad invocation goes to stderr and exits 1 the way
// every bash subcommand does, rather than the flag package's stderr-and-2.
// It returns the exit code and whether main should keep running.
func parseArgs(args []string, stdout, stderr io.Writer) (int, bool) {
	flag.CommandLine.Init("mo status", flag.ContinueOnError)
	// Parse must not print: this function decides which stream each message
	// belongs on, and the default handler writes usage to stderr for both.
	flag.CommandLine.SetOutput(io.Discard)
	flag.CommandLine.Usage = func() {}

	err := flag.CommandLine.Parse(args)
	switch {
	case errors.Is(err, flag.ErrHelp):
		_, _ = fmt.Fprint(stdout, usageText)
		return 0, false
	case err != nil:
		_, _ = fmt.Fprintln(stderr, err)
		_, _ = fmt.Fprintln(stderr, "Use 'mo status --help' for usage information")
		return 1, false
	}

	if err := validateFlags(); err != nil {
		_, _ = fmt.Fprintln(stderr, err)
		_, _ = fmt.Fprintln(stderr, "Use 'mo status --help' for usage information")
		return 1, false
	}
	return 0, true
}

func main() {
	if code, keepGoing := parseArgs(os.Args[1:], os.Stdout, os.Stderr); !keepGoing {
		os.Exit(code)
	}

	if *watchMode {
		interval, err := parseWatchInterval(*watchInterval)
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			fmt.Fprintln(os.Stderr, "Use 'mo status --help' for usage information")
			os.Exit(1)
		}
		runWatchMode(interval)
		return
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
