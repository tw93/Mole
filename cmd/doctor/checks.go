//go:build darwin

package main

import (
	"context"
	"time"

	tea "github.com/charmbracelet/bubbletea"
)

// diagCancel cancels in-flight checks when the user quits the TUI.
var diagCancel context.CancelFunc

func runCategory(index int, fn func() categoryResult) tea.Cmd {
	return func() tea.Msg {
		return categoryDoneMsg{index: index, result: fn()}
	}
}

func runHardware() tea.Cmd {
	return func() tea.Msg {
		_, diagCancel = context.WithCancel(context.Background())
		return hardwareDoneMsg{hardware: collectHardware()}
	}
}

func tickSpinner() tea.Cmd {
	return tea.Tick(100*time.Millisecond, func(t time.Time) tea.Msg {
		return tickMsg{}
	})
}

func scheduleReveal() tea.Cmd {
	return tea.Tick(5*time.Second, func(t time.Time) tea.Msg {
		return revealTickMsg{}
	})
}
