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

const tooSmallMessage = "Terminal too small. Enlarge the window to view status."

// linuxRichSnapshot fills the cards only Linux has (memory pressure, zram,
// btrfs allocation) on top of a 20-core CPU, so the minimum layout is the
// tallest one the dashboard can draw.
func linuxRichSnapshot() MetricsSnapshot {
	cpu := CPUStatus{Usage: 25, LogicalCPU: 20}
	for i := range 20 {
		cpu.PerCore = append(cpu.PerCore, float64(i))
	}
	return MetricsSnapshot{
		CPU: cpu,
		Memory: MemoryStatus{
			Total: 16 << 30, Used: 8 << 30, Available: 8 << 30, SwapTotal: 4 << 30, SwapUsed: 1 << 30,
			Pressure: "warn",
			PSI:      &MemoryPressureStats{SomeAvg10: 3, SomeAvg60: 2, FullAvg10: 1},
			Zram:     &ZramStatus{Devices: 1, Original: 2 << 30, Compressed: 1 << 29, MemUsed: 1 << 29, Ratio: 4},
		},
		Disks: []DiskStatus{{
			Mount: "/", Device: "/dev/nvme0n1p2", Total: 100 << 30, Used: 50 << 30, Fstype: "btrfs",
			Btrfs: &BtrfsAlloc{DataTotal: 60 << 30, DataUsed: 40 << 30, MetadataTotal: 2 << 30, MetadataUsed: 1 << 30, Unallocated: 30 << 30, UnallocatedOK: true},
		}},
		Network:   []NetworkStatus{{Name: "eth0", RxRateMBs: 1, TxRateMBs: 0.5}},
		Batteries: []BatteryStatus{{Percent: 70, Status: "Discharging"}},
	}
}

func TestStatusViewFitsShortViewport(t *testing.T) {
	snapshot := linuxRichSnapshot()
	for _, width := range []int{120, 80} {
		for _, height := range []int{1, 10, 12, 20, 60} {
			t.Run(fmt.Sprintf("%dx%d", width, height), func(t *testing.T) {
				m := model{width: width, height: 60, schedule: collectionSchedule{hasSnapshot: true}, metrics: snapshot, cpuCores: 0, fullCollected: true}
				next, _ := m.Update(tea.WindowSizeMsg{Width: width, Height: height})
				m = next.(model)
				view := m.View()
				plain := stripANSI(view)
				got := lipgloss.Height(view)
				t.Logf("frame=%d terminal=%d", got, height)
				if !strings.Contains(plain, "Network") && !strings.Contains(plain, "Terminal too small") {
					t.Fatal("neither dashboard nor resize guidance visible")
				}
				for line := range strings.SplitSeq(view, "\n") {
					if lipgloss.Width(line) > width {
						t.Fatal("frame exceeds terminal width")
					}
				}
				if m.cpuCores != 0 {
					t.Fatal("resize changed saved core preference")
				}
				if got != height {
					t.Fatalf("frame is %d lines for a %d-row terminal", got, height)
				}
				grown, _ := m.Update(tea.WindowSizeMsg{Width: width, Height: 100})
				restored := grown.(model)
				rv := stripANSI(restored.View())
				if strings.Count(rv, "Core") != 20 || lipgloss.Height(restored.View()) != 100 || !strings.Contains(rv, "Network") || strings.Contains(rv, "Terminal too small") {
					t.Fatal("tall resize did not recover")
				}
			})
		}
	}
}

// The guidance appears exactly when even the smallest CPU layout does not fit,
// so the smallest usable height is the frame height at the smallest core
// count. The Linux cards (pressure, zram, btrfs) are part of that frame.
func TestStatusTooSmallThresholdFollowsTheLinuxLayout(t *testing.T) {
	for _, width := range []int{120, 80} {
		base := model{width: width, height: 500, schedule: collectionSchedule{hasSnapshot: true}, metrics: linuxRichSnapshot(), cpuCores: cpuCoresCycle[0], fullCollected: true}
		// A terminal this tall only pads, so trimming the padding leaves the frame.
		min := lipgloss.Height(strings.TrimRight(base.View(), "\n"))
		t.Logf("width=%d smallest dashboard frame=%d rows", width, min)

		fits := base
		fits.height = min
		if v := stripANSI(fits.View()); strings.Contains(v, "Terminal too small") || !strings.Contains(v, "Network") {
			t.Fatalf("width=%d height=%d: dashboard should fit", width, min)
		}
		short := base
		short.height = min - 1
		v := stripANSI(short.View())
		if !strings.Contains(v, tooSmallMessage) || strings.Contains(v, "Network") {
			t.Fatalf("width=%d height=%d: want only the guidance, got %q", width, min-1, v)
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
			for line := range strings.SplitSeq(view, "\n") {
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
			for range 20 {
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
			if hasCPU != (height == 60) {
				t.Fatalf("unexpected CPU visibility at height %d: %q", height, plain)
			}
			if strings.Contains(plain, "Terminal too small") != (height == 10) {
				t.Fatalf("unexpected resize guidance at height %d: %q", height, plain)
			}
		})
	}
}
