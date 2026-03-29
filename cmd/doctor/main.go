//go:build darwin

package main

import (
	"flag"
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

var hasSudo = flag.Bool("sudo", false, "enable checks requiring admin access")

type checkStatus int

const (
	statusPass checkStatus = iota
	statusWarn
	statusFail
	statusSkipped
)

type cacheBreakdownItem struct {
	Name   string
	Path   string
	Size   int64
	Status checkStatus
}

type checkResult struct {
	Name      string
	Status    checkStatus
	Detail    string
	Score     int
	MaxScore  int
	Breakdown []cacheBreakdownItem
}

type categoryResult struct {
	Name     string
	Checks   []checkResult
	Score    int
	MaxScore int
}

type hardwareProfile struct {
	Model     string
	Chip      string
	RAM       string
	SSDTotal  string
	SSDFree   string
	MacOS     string
	Build     string
	ThermalOK bool
}

type diagnosisResult struct {
	Hardware   hardwareProfile
	Categories []categoryResult
	TotalScore int
	MaxScore   int
	Tips       []string
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

	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
