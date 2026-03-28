//go:build darwin

package main

import (
	"flag"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

var (
	jsonMode = flag.Bool("json", false, "output diagnosis as JSON instead of TUI")
	hasSudo  = flag.Bool("sudo", false, "enable checks requiring admin access")
)

type checkStatus int

const (
	statusPass checkStatus = iota
	statusWarn
	statusFail
	statusSkipped
)

type cacheBreakdownItem struct {
	Name   string      `json:"name"`
	Path   string      `json:"path"`
	Size   int64       `json:"size"`
	Status checkStatus `json:"status"`
}

type checkResult struct {
	Name      string               `json:"name"`
	Status    checkStatus          `json:"status"`
	Detail    string               `json:"detail"`
	Score     int                  `json:"score"`
	MaxScore  int                  `json:"max_score"`
	Breakdown []cacheBreakdownItem `json:"breakdown,omitempty"`
}

type categoryResult struct {
	Name     string        `json:"name"`
	Checks   []checkResult `json:"checks"`
	Score    int           `json:"score"`
	MaxScore int           `json:"max_score"`
}

type hardwareProfile struct {
	Model    string `json:"model"`
	Chip     string `json:"chip"`
	RAM      string `json:"ram"`
	SSDTotal string `json:"ssd_total"`
	SSDFree  string `json:"ssd_free"`
	MacOS    string `json:"macos_version"`
	Build    string `json:"macos_build"`
	ThermalOK bool  `json:"thermal_ok"`
}

type diagnosisResult struct {
	Hardware   hardwareProfile  `json:"hardware"`
	Categories []categoryResult `json:"categories"`
	TotalScore int              `json:"total_score"`
	MaxScore   int              `json:"max_score"`
	Tips       []string         `json:"tips"`
}

type model struct {
	width    int
	height   int
	result   diagnosisResult
	ready    bool
	running  bool
	spinner  int
	selected int
	expanded map[int]bool
	err      error
}

type diagnosisDoneMsg struct {
	result diagnosisResult
	err    error
}

type tickMsg struct{}

func newModel() model {
	return model{
		expanded: make(map[int]bool),
		running:  true,
	}
}

func (m model) Init() tea.Cmd {
	return tea.Batch(
		runDiagnosis(*hasSudo),
		tickSpinner(),
	)
}

func main() {
	flag.Parse()

	if *jsonMode {
		runJSONMode()
		return
	}

	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
