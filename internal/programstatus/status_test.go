package programstatus

import (
	"bytes"
	"errors"
	"reflect"
	"strings"
	"sync"
	"testing"

	tea "github.com/charmbracelet/bubbletea"
)

func TestReporterConcurrentCalls(t *testing.T) {
	var output bytes.Buffer
	reporter := &Reporter{output: &output}
	var calls sync.WaitGroup
	for range 16 {
		calls.Go(func() { reporter.Report(StateWorking, "") })
	}
	calls.Wait()
	if count := strings.Count(output.String(), "state=working"); count != 1 {
		t.Fatalf("working reports = %d, want 1", count)
	}

	for range 16 {
		calls.Go(func() { reporter.Filter(nil, tea.KeyMsg{Type: tea.KeyCtrlC}) })
		calls.Go(func() { reporter.Finish(nil) })
	}
	calls.Wait()
	reporter.Finish(nil)
	if count := strings.Count(output.String(), "state=idle"); count != 1 {
		t.Fatalf("idle reports = %d, want 1", count)
	}
}

func TestNilReporterIsInert(t *testing.T) {
	var reporter *Reporter
	msg := tea.KeyMsg{Type: tea.KeyCtrlC}
	reporter.Report(StateWorking, "")
	if got := reporter.Filter(nil, msg); !reflect.DeepEqual(got, msg) {
		t.Fatalf("Filter() = %v, want the message unchanged", got)
	}
	reporter.Finish(nil)
	reporter.Finish(tea.ErrInterrupted)
}

func TestReporterResendsWhenKindChanges(t *testing.T) {
	var output strings.Builder
	reporter := Reporter{output: &output, title: "mole analyze"}
	reporter.Report(StateBlocked, "")
	reporter.Report(StateBlocked, "")
	reporter.Report(StateBlocked, KindPermission)
	want := prefix + "state=blocked:app=mole" + terminator +
		prefix + "state=blocked:kind=permission:app=mole" + terminator
	if output.String() != want {
		t.Fatalf("reports = %q; want %q", output.String(), want)
	}
}

func TestFinishReportsByOutcome(t *testing.T) {
	for _, test := range []struct {
		name string
		err  error
		want string
	}{
		{"clean exit clears", nil, "state=clear"},
		{"error reports error", errors.New("boom"), "state=error"},
		{"interrupt reports idle", tea.ErrInterrupted, "state=idle"},
	} {
		var output strings.Builder
		reporter := &Reporter{output: &output}
		reporter.Finish(test.err)
		if !strings.Contains(output.String(), test.want) {
			t.Errorf("%s: output = %q, want %q", test.name, output.String(), test.want)
		}
	}
}
