package main

import (
	"bytes"
	"fmt"
	"strings"
	"testing"
	"time"

	tea "github.com/charmbracelet/bubbletea"
	"github.com/charmbracelet/lipgloss"
)

func TestStatusViewFitsShortViewport(t *testing.T) {
	cpu := CPUStatus{Usage: 25, LogicalCPU: 20}
	for i := 0; i < 20; i++ {
		cpu.PerCore = append(cpu.PerCore, float64(i))
	}
	snapshot := MetricsSnapshot{CPU: cpu, Memory: MemoryStatus{Total: 16 << 30, Used: 8 << 30, Available: 8 << 30}, Disks: []DiskStatus{{Mount: "/", Device: "/dev/disk3s1", Total: 100 << 30, Used: 50 << 30, Fstype: "apfs"}}, Network: []NetworkStatus{{Name: "en0", RxRateMBs: 1, TxRateMBs: 0.5}}, Batteries: []BatteryStatus{{Percent: 70, Status: "Discharging"}}}
	for _, width := range []int{120, 80} {
		for _, height := range []int{1, 10, 12, 20, 60} {
			t.Run(fmt.Sprintf("%dx%d", width, height), func(t *testing.T) {
				m := model{width: width, height: 60, schedule: collectionSchedule{hasSnapshot: true}, metrics: snapshot, cpuCores: 0, fullCollected: true}
				next, _ := m.Update(tea.WindowSizeMsg{Width: width, Height: height})
				m = next.(model)
				view := m.View()
				got := lipgloss.Height(view)
				t.Logf("frame=%d terminal=%d", got, height)
				if !strings.Contains(stripANSI(view), "Network") && !strings.Contains(stripANSI(view), "Terminal too small") {
					t.Fatal("neither dashboard nor resize guidance visible")
				}
				for _, line := range strings.Split(view, "\n") {
					if lipgloss.Width(line) > width {
						t.Fatal("frame exceeds terminal width")
					}
				}
				if m.cpuCores != 0 {
					t.Fatal("resize changed saved core preference")
				}
				grown, _ := m.Update(tea.WindowSizeMsg{Width: width, Height: 100})
				restored := grown.(model)
				if strings.Count(stripANSI(restored.View()), "Core") != 20 || lipgloss.Height(restored.View()) != 100 || !strings.Contains(stripANSI(restored.View()), "Network") || strings.Contains(restored.View(), "Terminal too small") {
					t.Fatal("tall resize did not recover")
				}
				if got > height {
					t.Fatalf("frame overflows: %d lines for %d-row terminal", got, height)
				}
			})
		}
	}
}

func TestStatusHeightFallbackFitsTinyWidths(t *testing.T) {
	for _, width := range []int{1, 2, 10, 30} {
		for _, height := range []int{1, 2, 10} {
			m := model{width: width, height: height, schedule: collectionSchedule{hasSnapshot: true}, catHidden: true}
			view := m.View()
			if lipgloss.Height(view) != height {
				t.Fatalf("%dx%d: rendered %d rows", width, height, lipgloss.Height(view))
			}
			for _, line := range strings.Split(view, "\n") {
				if lipgloss.Width(line) > width {
					t.Fatalf("%dx%d: line exceeds width: %q", width, height, line)
				}
			}
		}
	}
}

type heightTestRuntime struct {
	dashboard model
	ready     bool
}

func (m heightTestRuntime) Init() tea.Cmd {
	return tea.Sequence(func() tea.Msg { return tea.WindowSizeMsg{Width: m.dashboard.width, Height: m.dashboard.height} }, tea.Tick(150*time.Millisecond, func(time.Time) tea.Msg { return tea.Quit() }))
}
func (m heightTestRuntime) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
	if _, ok := msg.(tea.WindowSizeMsg); ok {
		next, _ := m.dashboard.Update(msg)
		m.dashboard = next.(model)
		m.ready = true
	}
	return m, nil
}
func (m heightTestRuntime) View() string {
	if !m.ready {
		return ""
	}
	return m.dashboard.View()
}
func TestStatusRendererShowsHeightFallback(t *testing.T) {
	for _, height := range []int{10, 60} {
		t.Run(fmt.Sprint(height), func(t *testing.T) {
			cpu := CPUStatus{Usage: 25, LogicalCPU: 20}
			for i := 0; i < 20; i++ {
				cpu.PerCore = append(cpu.PerCore, 25)
			}
			m := model{width: 120, height: height, schedule: collectionSchedule{hasSnapshot: true}, metrics: MetricsSnapshot{CPU: cpu}, fullCollected: true}
			var out bytes.Buffer
			p := tea.NewProgram(heightTestRuntime{dashboard: m}, tea.WithInput(nil), tea.WithOutput(&out), tea.WithAltScreen(), tea.WithoutSignalHandler())
			if _, err := p.Run(); err != nil {
				t.Fatal(err)
			}
			plain := stripANSI(out.String())
			hasCPU := strings.Contains(plain, "CPU")
			t.Logf("renderer terminal=%d CPU title visible=%v", height, hasCPU)
			if hasCPU != (height == 60) {
				t.Fatalf("unexpected CPU visibility at height %d: %q", height, plain)
			}
			if strings.Contains(plain, "Terminal too small") != (height == 10) {
				t.Fatalf("unexpected resize guidance at height %d: %q", height, plain)
			}
		})
	}
}
