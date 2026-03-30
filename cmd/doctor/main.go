//go:build darwin

package main

import (
	"fmt"
	"os"

	tea "github.com/charmbracelet/bubbletea"
)

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

// Messages for progressive output.
type categoryDoneMsg struct {
	index  int
	result categoryResult
}

type hardwareDoneMsg struct {
	hardware hardwareProfile
}

type tickMsg struct{}
type revealTickMsg struct{}

// categorySpec defines a check to run.
type categorySpec struct {
	name string
	fn   func() categoryResult
}

var categorySpecs = []categorySpec{
	{"Storage", checkStorage},
	{"Performance", checkPerformance},
	{"Battery", checkBattery},
	{"Security", checkSecurity},
	{"Maintenance", checkMaintenance},
	{"Dev Environment", checkDevEnvironment},
	{"Mole", checkMole},
}

type model struct {
	width   int
	height  int
	spinner int

	// Progressive results.
	categories    []categoryResult
	catDone       []bool
	revealedCount int // how many categories are visible in the UI
	hardware      hardwareProfile
	hardwareDone  bool

	// Final (computed after all categories revealed).
	totalScore int
	maxScore   int
	tips       []string
	finalized  bool

	// UI state.
	selected int
	expanded map[int]bool
	offset int
}

func newModel() model {
	n := len(categorySpecs)
	return model{
		categories: make([]categoryResult, n),
		catDone:    make([]bool, n),
		expanded:   make(map[int]bool),
	}
}

func (m model) Init() tea.Cmd {
	cmds := []tea.Cmd{runHardware(), tickSpinner(), scheduleReveal()}
	for i, spec := range categorySpecs {
		cmds = append(cmds, runCategory(i, spec.fn))
	}
	return tea.Batch(cmds...)
}

func (m model) allRevealed() bool {
	return m.revealedCount >= len(m.catDone)
}

func main() {
	p := tea.NewProgram(newModel(), tea.WithAltScreen())
	if _, err := p.Run(); err != nil {
		fmt.Fprintf(os.Stderr, "error: %v\n", err)
		os.Exit(1)
	}
}
