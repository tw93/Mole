package programstatus

import (
	"errors"
	"io"
	"os"
	"sync"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/x/term"
)

const AppName = "mole"

// Reporter is a helper for sending OSC 7501 program status messages to a terminal. It is safe to use from multiple goroutines.
// https://www.superlogical.com/rex/docs/build/program-status
type Reporter struct {
	mu          sync.Mutex
	output      io.Writer
	title       string
	lastState   State
	lastKind    Kind
	interrupted bool
}

func NewReporter(title string) *Reporter {
	reporter := &Reporter{title: title}
	if term.IsTerminal(os.Stdin.Fd()) && term.IsTerminal(os.Stdout.Fd()) && term.IsTerminal(os.Stderr.Fd()) {
		reporter.output = os.Stderr
	}
	return reporter
}

func (reporter *Reporter) Report(state State, kind Kind) {
	if reporter == nil {
		return
	}
	reporter.mu.Lock()
	defer reporter.mu.Unlock()
	reporter.report(state, kind)
}

func (reporter *Reporter) report(state State, kind Kind) {
	if reporter.output == nil || (state == reporter.lastState && kind == reporter.lastKind) {
		return
	}
	record := Record{State: state, Kind: kind, App: AppName}
	if state != StateBlocked {
		record.Title = reporter.title
	}
	sequence, err := record.Encode()
	if err == nil {
		if _, err := io.WriteString(reporter.output, sequence); err == nil {
			reporter.lastState, reporter.lastKind = state, kind
		}
	}
}

func (reporter *Reporter) Filter(_ tea.Model, msg tea.Msg) tea.Msg {
	if reporter == nil {
		return msg
	}
	if key, ok := msg.(tea.KeyMsg); ok && key.Type == tea.KeyCtrlC {
		reporter.mu.Lock()
		reporter.interrupted = true
		reporter.mu.Unlock()
	}
	return msg
}

func (reporter *Reporter) Finish(err error) {
	if reporter == nil {
		return
	}
	reporter.mu.Lock()
	defer reporter.mu.Unlock()
	switch {
	case reporter.interrupted || errors.Is(err, tea.ErrInterrupted):
		reporter.report(StateIdle, "")
	case err != nil:
		reporter.report(StateError, "")
	default:
		reporter.report(StateClear, "")
	}
}
