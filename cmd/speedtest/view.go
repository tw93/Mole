package main

import (
"context"
"fmt"
"strings"

tea "github.com/charmbracelet/bubbletea"
"github.com/charmbracelet/lipgloss"
)

// Colour palette — consistent with cmd/status.
var (
accentColor  = lipgloss.Color("#C79FD7")
subtleColor  = lipgloss.Color("#737373")
successColor = lipgloss.Color("#A8CC8C")
warnColor    = lipgloss.Color("#FFD75F")
)

var (
titleStyle   = lipgloss.NewStyle().Foreground(accentColor).Bold(true)
subtleStyle  = lipgloss.NewStyle().Foreground(subtleColor)
successStyle = lipgloss.NewStyle().Foreground(successColor)
warnStyle    = lipgloss.NewStyle().Foreground(warnColor)
dangerStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#E88388"))
labelStyle   = lipgloss.NewStyle().Foreground(subtleColor).Width(12)
valueStyle   = lipgloss.NewStyle().Bold(true)

barFillColor  = lipgloss.Color("#C79FD7")
barEmptyColor = lipgloss.Color("#444444")
)

// tea message types.
type progressMsg Progress
type doneMsg struct{ result Result }
type errMsg struct{ err error }

// tuiModel is the Bubble Tea model for the speed test TUI.
// ch is a reference type (channel) so it survives model copies.
type tuiModel struct {
runner  *Runner
ch      chan Progress
phase   Phase
pct     float64
instant float64
result  Result
err     error
width   int
}

type tuiProgram struct {
runner *Runner
}

func newTUIProgram(r *Runner) *tuiProgram {
return &tuiProgram{runner: r}
}

// Start creates the channel, launches the test goroutine, then runs the TUI.
func (tp *tuiProgram) Start() error {
ch := make(chan Progress, 128)
go tp.runner.RunWithProgress(context.Background(), ch)
m := tuiModel{runner: tp.runner, ch: ch}
p := tea.NewProgram(m)
_, err := p.Run()
return err
}

// Init returns the first Cmd that waits for a progress update.
func (m tuiModel) Init() tea.Cmd {
return waitForProgress(m.ch)
}

// waitForProgress returns a Cmd that blocks until the next Progress arrives.
func waitForProgress(ch chan Progress) tea.Cmd {
return func() tea.Msg {
p, ok := <-ch
if !ok {
return doneMsg{}
}
if p.Err != nil {
return errMsg{err: p.Err}
}
if p.Phase == PhaseDone {
return doneMsg{}
}
return progressMsg(p)
}
}

func (m tuiModel) Update(msg tea.Msg) (tea.Model, tea.Cmd) {
switch msg := msg.(type) {
case tea.KeyMsg:
if msg.String() == "q" || msg.String() == "ctrl+c" || msg.String() == "esc" {
return m, tea.Quit
}
case tea.WindowSizeMsg:
m.width = msg.Width
case progressMsg:
m.phase = msg.Phase
m.pct = msg.PctDone
m.instant = msg.InstantMbps
// Schedule next read — m.ch is shared across copies since it's a channel.
return m, waitForProgress(m.ch)
case doneMsg:
m.phase = PhaseDone
m.runner.mu.Lock()
m.result = m.runner.result
m.runner.mu.Unlock()
return m, tea.Quit
case errMsg:
m.phase = PhaseError
m.err = msg.err
return m, tea.Quit
}
return m, nil
}

func (m tuiModel) View() string {
w := m.width
if w <= 0 {
w = 80
}

var sb strings.Builder
sb.WriteString("\n")
sb.WriteString(titleStyle.Render("  ⚡ Mole Network Speed Test") + "\n")
sb.WriteString(subtleStyle.Render("  Powered by Cloudflare") + "\n\n")

if m.phase == PhaseError {
sb.WriteString(dangerStyle.Render(fmt.Sprintf("  Error: %v\n", m.err)))
return sb.String()
}

if m.phase == PhaseDone {
sb.WriteString(renderResult(m.result, w))
sb.WriteString("\n")
sb.WriteString(subtleStyle.Render("  Press q to quit\n"))
return sb.String()
}

// In-progress view.
phases := []struct {
phase Phase
label string
}{
{PhasePing, "Latency"},
{PhaseDownload, "Download"},
{PhaseUpload, "Upload"},
}
for _, ph := range phases {
label := labelStyle.Render(ph.label)
switch {
case ph.phase < m.phase:
sb.WriteString(fmt.Sprintf("  %s %s\n", label, successStyle.Render("✓ done")))
case ph.phase == m.phase:
bar := renderBar(m.pct/100, 24)
pct := subtleStyle.Render(fmt.Sprintf("%.0f%%", m.pct))
sb.WriteString(fmt.Sprintf("  %s %s %s", label, bar, pct))
if m.instant > 0 {
sb.WriteString("  " + subtleStyle.Render(fmt.Sprintf("%.1f Mbps", m.instant)))
}
sb.WriteString("\n")
default:
sb.WriteString(fmt.Sprintf("  %s %s\n", label, subtleStyle.Render("waiting...")))
}
}
sb.WriteString("\n" + subtleStyle.Render("  Press q to quit\n"))
return sb.String()
}

func renderResult(r Result, _ int) string {
var sb strings.Builder

row := func(label, value string) {
sb.WriteString(fmt.Sprintf("  %s %s\n",
labelStyle.Render(label),
valueStyle.Render(value),
))
}

sb.WriteString(successStyle.Render("  ✓ Test complete\n\n"))
row("Latency", fmt.Sprintf("%.1f ms  (jitter %.1f ms)", r.LatencyMS, r.JitterMS))
if r.PacketLoss > 0 {
row("Packet loss", fmt.Sprintf("%.1f%%", r.PacketLoss))
}
row("Download", fmt.Sprintf("%.2f Mbps", r.DownloadMbps))
row("Upload", fmt.Sprintf("%.2f Mbps", r.UploadMbps))
row("Server", r.Server)

sb.WriteString("\n")
quality, style := qualityLabel(r)
sb.WriteString(fmt.Sprintf("  %s\n", style.Render(quality)))

return sb.String()
}

func qualityLabel(r Result) (string, lipgloss.Style) {
switch {
case r.DownloadMbps >= 100 && r.LatencyMS < 20:
return "● Excellent — suitable for 4K streaming, gaming, video calls", successStyle
case r.DownloadMbps >= 25 && r.LatencyMS < 50:
return "● Good — suitable for HD streaming and remote work", successStyle
case r.DownloadMbps >= 5 && r.LatencyMS < 100:
return "○ Fair — adequate for basic browsing and SD video", warnStyle
default:
return "○ Poor — may experience slowdowns on demanding tasks", warnStyle
}
}

// renderBar renders an ASCII progress bar of width w filled to pct (0–1).
func renderBar(pct float64, w int) string {
filled := int(pct * float64(w))
if filled > w {
filled = w
}
fill := lipgloss.NewStyle().Foreground(barFillColor).Render(strings.Repeat("█", filled))
empty := lipgloss.NewStyle().Foreground(barEmptyColor).Render(strings.Repeat("░", w-filled))
return fill + empty
}
