package main

import (
	"fmt"
	"sort"
	"strings"

	"github.com/charmbracelet/lipgloss"

	"github.com/tw93/mole/internal/units"
)

var (
	titleStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#C79FD7")).Bold(true)
	subtleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#737373"))
	warnStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFD75F"))
	dangerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF5F5F")).Bold(true)
	okStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#A5D6A7"))
	lineStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#404040"))

	primaryStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#BD93F9"))
	alertBarStyle = lipgloss.NewStyle().
			Foreground(lipgloss.Color("#2B1200")).
			Background(lipgloss.Color("#FFD75F")).
			Bold(true).
			Padding(0, 1)
)

const (
	colWidth    = 38
	iconCPU     = "◉"
	iconMemory  = "◫"
	iconGPU     = "◧"
	iconDisk    = "▥"
	iconNetwork = "⇅"
	iconBattery = "◪"
	iconSensors = "◈"
	iconProcs   = "❊"

	metricLabelWidth    = 6
	processMemoryWidth  = 7
	processWideMinWidth = 46
)

// Mole body frames (facing right).
var moleBody = [][]string{
	{
		`     /\_/\`,
		` ___/ o o \`,
		`/___   =-= /`,
		`\____)-m-m)`,
	},
	{
		`     /\_/\`,
		` ___/ o o \`,
		`/___   =-= /`,
		`\____)mm__)`,
	},
	{
		`     /\_/\`,
		` ___/ · · \`,
		`/___   =-= /`,
		`\___)-m__m)`,
	},
	{
		`     /\_/\`,
		` ___/ o o \`,
		`/___   =-= /`,
		`\____)-mm-)`,
	},
}

// Mirror mole body frames (facing left).
var moleBodyMirror = [][]string{
	{
		`    /\_/\`,
		`   / o o \___`,
		`  \ =-=   ___\`,
		`  (m-m-(____/`,
	},
	{
		`    /\_/\`,
		`   / o o \___`,
		`  \ =-=   ___\`,
		`  (__mm(____/`,
	},
	{
		`    /\_/\`,
		`   / · · \___`,
		`  \ =-=   ___\`,
		`  (m__m-(___/`,
	},
	{
		`    /\_/\`,
		`   / o o \___`,
		`  \ =-=   ___\`,
		`  (-mm-(____/`,
	},
}

// getMoleFrame renders the animated mole.
func getMoleFrame(animFrame int, termWidth int) string {
	moleWidth := 15
	maxPos := max(termWidth-moleWidth, 0)

	cycleLength := maxPos * 2
	if cycleLength == 0 {
		cycleLength = 1
	}
	pos := animFrame % cycleLength
	movingLeft := pos > maxPos
	if movingLeft {
		pos = cycleLength - pos
	}

	// Use mirror frames when moving left
	var frames [][]string
	if movingLeft {
		frames = moleBodyMirror
	} else {
		frames = moleBody
	}

	bodyIdx := animFrame % len(frames)
	body := frames[bodyIdx]

	padding := strings.Repeat(" ", pos)
	var lines []string

	for _, line := range body {
		lines = append(lines, padding+line)
	}

	return strings.Join(lines, "\n")
}

type cardData struct {
	icon  string
	title string
	lines []string
}

func renderHeader(m MetricsSnapshot, errMsg string, animFrame int, termWidth int, catHidden bool) (string, string) {
	if termWidth <= 0 {
		termWidth = 80
	}
	compactHeader := termWidth <= 80

	title := titleStyle.Render("Status")

	scoreStyle := getScoreStyle(m.HealthScore)
	scoreText := subtleStyle.Render("Health ") + scoreStyle.Render(fmt.Sprintf("● %d", m.HealthScore))
	if errMsg == "" {
		diagnosis := statusDiagnosisLine(m)
		scoreText += " " + subtleStyle.Render(diagnosis)
	}

	// Hardware info for a single line.
	identityParts := []string{}
	if m.Hardware.Model != "" {
		identityParts = append(identityParts, primaryStyle.Render(m.Hardware.Model))
	}
	if m.Hardware.CPUModel != "" {
		cpuInfo := m.Hardware.CPUModel
		// Append GPU core count when available.
		if len(m.GPU) > 0 && m.GPU[0].CoreCount > 0 {
			cpuInfo += fmt.Sprintf(", %dGPU", m.GPU[0].CoreCount)
		}
		identityParts = append(identityParts, cpuInfo)
	}
	specParts := []string{}
	if m.Hardware.TotalRAM != "" {
		specParts = append(specParts, "RAM "+m.Hardware.TotalRAM)
	} else if m.Memory.Total > 0 {
		specParts = append(specParts, "RAM "+humanBytes(m.Memory.Total))
	}
	if m.Hardware.DiskSize != "" {
		specParts = append(specParts, "Disk "+m.Hardware.DiskSize)
	} else if disk, ok := rootDisk(m.Disks); ok && disk.Total > 0 {
		specParts = append(specParts, "Disk "+humanBytes(disk.Total))
	}
	refreshParts := []string{}
	if m.Hardware.RefreshRate != "" {
		refreshParts = append(refreshParts, m.Hardware.RefreshRate)
	}
	optionalInfoParts := []string{}
	if !compactHeader && m.Hardware.OSVersion != "" {
		optionalInfoParts = append(optionalInfoParts, m.Hardware.OSVersion)
	}
	if !compactHeader && m.Uptime != "" {
		uptimeText := "up " + m.Uptime
		switch uptimeSeverity(m.UptimeSeconds) {
		case "danger":
			uptimeText = dangerStyle.Render(uptimeText + " ↻")
		case "warn":
			uptimeText = warnStyle.Render(uptimeText)
		default:
			uptimeText = subtleStyle.Render(uptimeText)
		}
		optionalInfoParts = append(optionalInfoParts, uptimeText)
	}
	joinInfoParts := func(groups ...[]string) []string {
		parts := []string{}
		for _, group := range groups {
			parts = append(parts, group...)
		}
		return parts
	}

	headLeft := title + "  " + scoreText
	headerLine := headLeft
	if termWidth > 0 && lipgloss.Width(headerLine) > termWidth {
		headerLine = wrapToWidth(headLeft, termWidth)[0]
	}
	if termWidth > 0 {
		fitHeaderParts := func(parts []string) (string, bool) {
			if len(parts) == 0 {
				return "", false
			}
			combined := headLeft + "  " + strings.Join(parts, " · ")
			if lipgloss.Width(combined) <= termWidth {
				return combined, true
			}
			return "", false
		}
		candidates := [][]string{
			joinInfoParts(identityParts, specParts, refreshParts, optionalInfoParts),
			joinInfoParts(identityParts, specParts, refreshParts),
			joinInfoParts(identityParts, specParts),
		}
		if len(identityParts) > 1 {
			// Keep labeled RAM/Disk visible on narrow terminals before CPU details.
			candidates = append(candidates, joinInfoParts(identityParts[:1], specParts))
		}
		candidates = append(candidates, specParts)
		for _, parts := range candidates {
			if line, ok := fitHeaderParts(parts); ok {
				headerLine = line
				break
			}
		}
		if headerLine == headLeft {
			// Last resort: preserve the existing tail-drop behavior for unusual
			// hardware strings that still do not fit the priority candidates.
			fitParts := joinInfoParts(identityParts, specParts, refreshParts)
			for len(fitParts) > 0 {
				if line, ok := fitHeaderParts(fitParts); ok {
					headerLine = line
					break
				}
				fitParts = fitParts[:len(fitParts)-1]
			}
		}
	}

	// Show cat unless hidden - render mole centered below header
	var mole string
	if !catHidden {
		mole = getMoleFrame(animFrame, termWidth)
	}

	if errMsg != "" {
		if mole == "" {
			return lipgloss.JoinVertical(lipgloss.Left, headerLine, "", dangerStyle.Render("ERROR: "+errMsg)), ""
		}
		return lipgloss.JoinVertical(lipgloss.Left, headerLine, "", mole, dangerStyle.Render("ERROR: "+errMsg)), ""
	}
	if mole == "" {
		return headerLine, ""
	}
	return headerLine, mole
}

func getScoreStyle(score int) lipgloss.Style {
	switch {
	case score >= scoreExcellentThreshold:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#87FF87")).Bold(true)
	case score >= scoreGoodThreshold:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#87D787")).Bold(true)
	case score >= scoreFairThreshold:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#FFD75F")).Bold(true)
	default:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#FF6B6B")).Bold(true)
	}
}

func renderProcessAlertBar(alerts []ProcessAlert, width int) string {
	active := activeAlerts(alerts)
	if len(active) == 0 {
		return ""
	}

	focus := active[0]

	text := fmt.Sprintf(
		"ALERT %s at %.1f%% for %s (threshold %.1f%%)",
		formatProcessLabel(ProcessInfo{PID: focus.PID, Name: focus.Name}),
		focus.CPU,
		focus.Window,
		focus.Threshold,
	)
	if len(active) > 1 {
		text += fmt.Sprintf(" · +%d more", len(active)-1)
	}

	return renderBanner(alertBarStyle, text, width)
}

func renderBanner(style lipgloss.Style, text string, width int) string {
	if width > 0 {
		style = style.MaxWidth(width)
	}
	return style.Render(text)
}

func renderCPUCard(cpu CPUStatus, thermal ThermalStatus, cpuCores int) cardData {
	var lines []string

	// Line 1: Usage + Temp (Format: 15% @ 30.4°C)
	usageBar := progressBar(cpu.Usage)

	headerText := fmt.Sprintf("%5.1f%%", cpu.Usage)
	if thermal.CPUTemp > 0 {
		headerText += fmt.Sprintf(" @ %s°C", colorizeTemp(thermal.CPUTemp))
	}

	lines = append(lines, fmt.Sprintf("Total  %s  %s", usageBar, headerText))

	if cpu.PerCoreEstimated {
		lines = append(lines, subtleStyle.Render("Per-core data unavailable, using averaged load"))
	} else if len(cpu.PerCore) > 0 {
		type coreUsage struct {
			idx int
			val float64
		}
		var cores []coreUsage
		for i, v := range cpu.PerCore {
			cores = append(cores, coreUsage{i, v})
		}
		sort.Slice(cores, func(i, j int) bool { return cores[i].val > cores[j].val })

		// cpuCores selects how many of the busiest cores to list; 0 (or any
		// value >= the core count) means "all". Set via the 'c' key, persisted.
		maxCores := len(cores)
		if cpuCores > 0 {
			maxCores = min(len(cores), cpuCores)
		}
		for i := range maxCores {
			c := cores[i]
			lines = append(lines, fmt.Sprintf("Core%-2d %s  %5.1f%%", c.idx+1, progressBar(c.val), c.val))
		}
	}

	// Load line at the end
	if cpu.PCoreCount > 0 && cpu.ECoreCount > 0 {
		lines = append(lines, fmt.Sprintf("Load   %.2f / %.2f / %.2f, %dP+%dE",
			cpu.Load1, cpu.Load5, cpu.Load15, cpu.PCoreCount, cpu.ECoreCount))
	} else {
		lines = append(lines, fmt.Sprintf("Load   %.2f / %.2f / %.2f, %d cores",
			cpu.Load1, cpu.Load5, cpu.Load15, cpu.LogicalCPU))
	}

	return cardData{icon: iconCPU, title: "CPU", lines: lines}
}

// hasGPUCard reports whether there is enough GPU data to be worth its own card.
// Placeholder entries (e.g. "No GPU metrics available" on machines without a
// readable GPU) carry neither usage nor a core count and are skipped.
func hasGPUCard(gpus []GPUStatus) bool {
	if len(gpus) == 0 {
		return false
	}
	g := gpus[0]
	return g.Usage >= 0 || g.CoreCount > 0
}

// renderGPUCard renders the standalone GPU section. On Apple Silicon the usage
// figures come from IOKit (no root); when they cannot be read the row says so
// instead of showing a misleading 0%.
//
// detail controls how many utilization rows appear (1=Device, 2=+Renderer,
// 3=+Tiler). Apple exposes no per-core/per-SM breakdown, so these three
// whole-device figures are the finest granularity available. A row is skipped
// when its figure is unknown (-1), e.g. the non-Apple / powermetrics paths.
func renderGPUCard(gpus []GPUStatus, detail int) cardData {
	var lines []string
	g := gpus[0]

	if g.Usage >= 0 {
		lines = append(lines, fmt.Sprintf("%-6s %s  %5.1f%%", "Usage", progressBar(g.Usage), g.Usage))
	} else {
		lines = append(lines, subtleStyle.Render("Usage  unavailable"))
	}
	if detail >= 2 && g.Renderer >= 0 {
		lines = append(lines, fmt.Sprintf("%-6s %s  %5.1f%%", "Render", progressBar(g.Renderer), g.Renderer))
	}
	if detail >= 3 && g.Tiler >= 0 {
		lines = append(lines, fmt.Sprintf("%-6s %s  %5.1f%%", "Tiler", progressBar(g.Tiler), g.Tiler))
	}
	if g.CoreCount > 0 {
		lines = append(lines, fmt.Sprintf("%-6s %d", "Cores", g.CoreCount))
	}
	if g.Note != "" {
		lines = append(lines, subtleStyle.Render(g.Note))
	}

	return cardData{icon: iconGPU, title: "GPU", lines: lines}
}

func renderMemoryCard(mem MemoryStatus, cardWidth int) cardData {
	// Check if swap is being used (or at least allocated).
	hasSwap := mem.SwapTotal > 0 || mem.SwapUsed > 0

	var lines []string
	// Line 1: Used
	lines = append(lines, fmt.Sprintf("Used   %s  %5.1f%%", progressBar(mem.UsedPercent), mem.UsedPercent))

	// Line 2: Free
	var freePercent float64
	if mem.Total > 0 {
		freePercent = (float64(mem.Available) / float64(mem.Total)) * 100.0
	}
	lines = append(lines, fmt.Sprintf("Free   %s  %5.1f%%", progressBar(freePercent), freePercent))

	if hasSwap {
		// Layout with Swap:
		// 3. Swap (progress bar + text)
		// 4. Total + Avail
		var swapPercent float64
		if mem.SwapTotal > 0 {
			swapPercent = (float64(mem.SwapUsed) / float64(mem.SwapTotal)) * 100.0
		}
		swapLine := fmt.Sprintf("Swap   %s  %5.1f%%", progressBar(swapPercent), swapPercent)
		swapText := fmt.Sprintf("%s/%s", humanBytesCompact(mem.SwapUsed), humanBytesCompact(mem.SwapTotal))
		swapLineWithText := swapLine + " " + swapText
		if cardWidth > 0 && lipgloss.Width(swapLineWithText) <= cardWidth {
			lines = append(lines, swapLineWithText)
		} else if cardWidth <= 0 {
			lines = append(lines, swapLineWithText)
		} else {
			lines = append(lines, swapLine)
		}

		lines = append(lines, formatMemoryDetailLine("Total", humanBytes(mem.Used)+" / "+humanBytes(mem.Total), mem.Available, cardWidth))
	} else {
		// Layout without Swap:
		// 3. Total
		// 4. Cache + Avail
		lines = append(lines, fmt.Sprintf("Total  %s / %s", humanBytes(mem.Used), humanBytes(mem.Total)))

		if mem.Cached > 0 {
			lines = append(lines, formatMemoryDetailLine("Cache", humanBytes(mem.Cached), mem.Available, cardWidth))
		} else {
			lines = append(lines, fmt.Sprintf("Avail  %s", humanBytes(mem.Available)))
		}
	}
	// Memory pressure status.
	if mem.Pressure != "" {
		pressureStyle := okStyle
		pressureText := "Status " + mem.Pressure
		switch mem.Pressure {
		case "warn":
			pressureStyle = warnStyle
		case "critical":
			pressureStyle = dangerStyle
		}
		lines = append(lines, pressureStyle.Render(pressureText))
	}
	return cardData{icon: iconMemory, title: "Memory", lines: lines}
}

func formatMemoryDetailLine(label string, value string, available uint64, cardWidth int) string {
	line := fmt.Sprintf("%-6s %s · Avail %s", label, value, humanBytes(available))
	if cardWidth <= 0 || lipgloss.Width(line) <= cardWidth {
		return line
	}
	return fmt.Sprintf("%-6s %s · Avail %s", label, value, humanBytesCompact(available))
}

func renderDiskCard(disks []DiskStatus, io DiskIOStatus, _ uint64, _ bool) cardData {
	var lines []string
	if len(disks) == 0 {
		lines = append(lines, subtleStyle.Render("Collecting..."))
	} else {
		internal, external := splitDisks(disks)
		addGroup := func(prefix string, list []DiskStatus) {
			if len(list) == 0 {
				return
			}
			for i, d := range list {
				label := diskLabel(prefix, i, len(list))
				lines = append(lines, formatDiskLine(label, d))
			}
		}
		addGroup("INTR", internal)
		addGroup("EXTR", external)
		if len(lines) == 0 {
			lines = append(lines, subtleStyle.Render("No disks detected"))
		} else if len(disks) == 1 {
			lines = append(lines, formatDiskMetaLine(disks[0]))
		}
		lines = append(lines, formatDiskSMARTLine(disks))
	}
	lines = append(lines, formatDiskIOLine(io))
	return cardData{icon: iconDisk, title: "Disk", lines: lines}
}

func splitDisks(disks []DiskStatus) (internal, external []DiskStatus) {
	for _, d := range disks {
		if d.External {
			external = append(external, d)
		} else {
			internal = append(internal, d)
		}
	}
	return internal, external
}

func diskLabel(prefix string, index int, total int) string {
	if total <= 1 {
		return prefix
	}
	return fmt.Sprintf("%s%d", prefix, index+1)
}

func formatDiskLine(label string, d DiskStatus) string {
	if label == "" {
		label = "DISK"
	}
	bar := progressBar(d.UsedPercent)
	used := humanBytesShort(d.Used)
	free := uint64(0)
	if d.Total > d.Used {
		free = d.Total - d.Used
	}
	return fmt.Sprintf("%-6s %s  %s used, %s free", label, bar, used, humanBytesShort(free))
}

func formatDiskMetaLine(d DiskStatus) string {
	parts := []string{humanBytesShort(d.Total)}
	if d.Fstype != "" {
		parts = append(parts, strings.ToUpper(d.Fstype))
	}
	return fmt.Sprintf("Total  %s", strings.Join(parts, " · "))
}

func formatDiskSMARTLine(disks []DiskStatus) string {
	if len(disks) == 1 {
		status, failing := formatSMARTStatus(disks[0].SmartStatus, false)
		if failing {
			status += " · " + dangerStyle.Render("Back up now")
		}
		return fmt.Sprintf("%-*s %s", metricLabelWidth, "SMART", status)
	}

	internal, external := splitDisks(disks)
	parts := make([]string, 0, len(disks)+1)
	hasFailing := false
	addGroup := func(prefix string, list []DiskStatus) {
		for index, disk := range list {
			status, failing := formatSMARTStatus(disk.SmartStatus, true)
			parts = append(parts, diskLabel(prefix, index, len(list))+" "+status)
			hasFailing = hasFailing || failing
		}
	}
	addGroup("INTR", internal)
	addGroup("EXTR", external)
	if hasFailing {
		parts = append([]string{dangerStyle.Render("Back up now")}, parts...)
	}
	return fmt.Sprintf("%-*s %s", metricLabelWidth, "SMART", strings.Join(parts, " · "))
}

func formatSMARTStatus(status string, compact bool) (string, bool) {
	switch status {
	case smartStatusVerified:
		if compact {
			return okStyle.Render("OK"), false
		}
		return okStyle.Render("Verified"), false
	case smartStatusFailing:
		if compact {
			return dangerStyle.Render("FAIL"), true
		}
		return dangerStyle.Render("Failing"), true
	case smartStatusUnsupported:
		if compact {
			return subtleStyle.Render("N/A"), false
		}
		return subtleStyle.Render("Unsupported"), false
	default:
		if compact {
			return subtleStyle.Render("?"), false
		}
		return subtleStyle.Render("Unknown"), false
	}
}

func formatDiskIOLine(io DiskIOStatus) string {
	text := fmt.Sprintf("%s R %s · %s W %s MB/s",
		ioBar(io.ReadRate),
		formatRateCompact(io.ReadRate),
		ioBar(io.WriteRate),
		formatRateCompact(io.WriteRate),
	)
	return fmt.Sprintf("%-*s %s", metricLabelWidth, "I/O", text)
}

func ioBar(rate float64) string {
	filled := max(min(int(rate/10.0), 5), 0)
	bar := strings.Repeat("▮", filled) + strings.Repeat("▯", 5-filled)
	if rate > 80 {
		return dangerStyle.Render(bar)
	}
	if rate > 30 {
		return warnStyle.Render(bar)
	}
	return okStyle.Render(bar)
}

func renderProcessCard(procs []ProcessInfo, cardWidth int) cardData {
	var lines []string
	maxProcs := 3
	for i, p := range procs {
		if i >= maxProcs {
			break
		}
		rank := fmt.Sprintf("#%d", i+1)
		cpuBar := processBar(p.CPU, cardWidth)
		line := fmt.Sprintf(
			"%-*s %s %5.1f%% %*s",
			metricLabelWidth,
			rank,
			cpuBar,
			p.CPU,
			processMemoryWidth,
			processMemoryText(p),
		)
		if nameWidth := remainingLineWidth(cardWidth, line); nameWidth > 0 {
			line += " " + shorten(p.Name, nameWidth)
		}
		lines = append(lines, strings.TrimRight(line, " "))
	}
	if len(lines) == 0 {
		lines = append(lines, subtleStyle.Render("Collecting..."))
	}
	return cardData{icon: iconProcs, title: "Processes", lines: lines}
}

func processBar(percent float64, cardWidth int) string {
	if cardWidth >= processWideMinWidth {
		return progressBar(percent)
	}
	return miniBar(percent)
}

func processMemoryText(p ProcessInfo) string {
	if p.MemoryBytes > 0 {
		return humanBytesCompact(p.MemoryBytes)
	}
	if p.Memory >= 10 {
		return fmt.Sprintf("M%.0f%%", p.Memory)
	}
	return ""
}

func buildCards(m MetricsSnapshot, width int, cpuCores int, gpuDetail int) []cardData {
	cards := []cardData{renderCPUCard(m.CPU, m.Thermal, cpuCores)}
	// GPU sits right after CPU when there is real data to show.
	if hasGPUCard(m.GPU) {
		cards = append(cards, renderGPUCard(m.GPU, gpuDetail))
	}
	cards = append(cards,
		renderMemoryCard(m.Memory, width),
		renderDiskCard(m.Disks, m.DiskIO, m.TrashSize, m.TrashApprox),
		renderBatteryCard(m.Batteries, m.Thermal),
		renderProcessCard(m.TopProcesses, width),
		renderNetworkCard(m.Network, m.NetworkHistory, m.Proxy, width),
	)
	// Sensors card disabled - redundant with CPU temp
	// if hasSensorData(m.Sensors) {
	// 	cards = append(cards, renderSensorsCard(m.Sensors))
	// }
	return cards
}

func miniBar(percent float64) string {
	filled := max(min(int(percent/20), 5), 0)
	return colorizePercent(percent, strings.Repeat("▮", filled)+strings.Repeat("▯", 5-filled))
}

func renderNetworkCard(netStats []NetworkStatus, history NetworkHistory, proxy ProxyStatus, cardWidth int) cardData {
	var lines []string
	var totalRx, totalTx float64
	var primaryIP string

	for _, n := range netStats {
		totalRx += n.RxRateMBs
		totalTx += n.TxRateMBs
		if primaryIP == "" && n.IP != "" && n.Name == "en0" {
			primaryIP = n.IP
		}
	}

	if len(netStats) == 0 {
		lines = append(lines, subtleStyle.Render("Collecting..."))
	} else {
		// Calculate dynamic width
		// Layout: "Down   " (7) + graph + "  " (2) + rate (approx 10-12)
		// Safe margin: 22 chars.
		// We target 16 chars to match progressBar implementation for visual consistency.
		graphWidth := min(max(cardWidth-22, 5), 16)

		// sparkline graphs
		rxSparkline := sparkline(history.RxHistory, totalRx, graphWidth)
		txSparkline := sparkline(history.TxHistory, totalTx, graphWidth)
		lines = append(lines, fmt.Sprintf("Down   %s  %s", rxSparkline, formatRate(totalRx)))
		lines = append(lines, fmt.Sprintf("Up     %s  %s", txSparkline, formatRate(totalTx)))
		// Show proxy and IP on one line.
		var infoParts []string
		if proxy.Enabled {
			infoParts = append(infoParts, "Proxy "+proxy.Type)
		}
		if primaryIP != "" {
			infoParts = append(infoParts, primaryIP)
		}
		if len(infoParts) > 0 {
			lines = append(lines, strings.Join(infoParts, " · "))
		}
	}
	return cardData{icon: iconNetwork, title: "Network", lines: lines}
}

// 8 levels: ▁▂▃▄▅▆▇█
func sparkline(history []float64, current float64, width int) string {
	blocks := []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}

	data := make([]float64, 0, width)
	if len(history) > 0 {
		// Take the most recent points.
		start := 0
		if len(history) > width {
			start = len(history) - width
		}
		data = append(data, history[start:]...)
	}
	// padding with zeros at the start
	for len(data) < width {
		data = append([]float64{0}, data...)
	}
	if len(data) > width {
		data = data[len(data)-width:]
	}

	maxVal := 0.1
	for _, v := range data {
		if v > maxVal {
			maxVal = v
		}
	}

	var builder strings.Builder
	for _, v := range data {
		level := max(int((v/maxVal)*float64(len(blocks)-1)), 0)
		if level >= len(blocks) {
			level = len(blocks) - 1
		}
		builder.WriteRune(blocks[level])
	}

	result := builder.String()
	if current > 8 {
		return dangerStyle.Render(result)
	}
	if current > 3 {
		return warnStyle.Render(result)
	}
	return okStyle.Render(result)
}

func renderBatteryCard(batts []BatteryStatus, thermal ThermalStatus) cardData {
	var lines []string
	if len(batts) == 0 {
		lines = append(lines, subtleStyle.Render("No battery"))
	} else {
		b := batts[0]
		statusLower := strings.ToLower(b.Status)
		percentText := fmt.Sprintf("%5.1f%%", b.Percent)
		if b.Percent < 20 && statusLower != "charging" && statusLower != "charged" {
			percentText = dangerStyle.Render(percentText)
		}
		lines = append(lines, fmt.Sprintf("Level  %s  %s", batteryProgressBar(b.Percent), percentText))

		// Add capacity line if available.
		if b.Capacity > 0 {
			capacityText := fmt.Sprintf("%5d%%", b.Capacity)
			if b.Capacity < 70 {
				capacityText = dangerStyle.Render(capacityText)
			} else if b.Capacity < 85 {
				capacityText = warnStyle.Render(capacityText)
			}
			lines = append(lines, fmt.Sprintf("Health %s  %s", batteryProgressBar(float64(b.Capacity)), capacityText))
		}

		if thermal.AdapterPower > 0 && isPoweredByAC(statusLower) {
			lines = append(lines, fmt.Sprintf("%-6s %s  %6s",
				"Input",
				okStyle.Render(plainProgressBar(100)),
				fmt.Sprintf("%.0fW max", thermal.AdapterPower),
			))
		}

		statusStyle := subtleStyle
		if isPoweredByAC(statusLower) {
			statusStyle = okStyle
		} else if b.Percent < 20 {
			statusStyle = dangerStyle
		}
		statusText := formatBatteryStatus(b.Status)
		if b.TimeLeft != "" && b.TimeLeft != "0:00" {
			statusText += " · " + b.TimeLeft
		}

		healthParts := []string{}

		// Battery health assessment label.
		if b.CycleCount > 0 || b.Capacity > 0 {
			label, severity := batteryHealthLabel(b.CycleCount, b.Capacity)
			switch severity {
			case "danger":
				healthParts = append(healthParts, dangerStyle.Render(label))
			case "warn":
				healthParts = append(healthParts, warnStyle.Render(label))
			default:
				healthParts = append(healthParts, okStyle.Render(label))
			}
		} else if b.Health != "" {
			healthParts = append(healthParts, b.Health)
		}

		if b.CycleCount > 0 {
			cycleText := fmt.Sprintf("%d cycles", b.CycleCount)
			if b.CycleCount > batteryCycleDanger {
				cycleText = dangerStyle.Render(cycleText)
			} else if b.CycleCount > batteryCycleWarn {
				cycleText = warnStyle.Render(cycleText)
			}
			healthParts = append(healthParts, cycleText)
		}

		if thermal.BatteryTemp > 0 {
			tempText := colorizeTemp(thermal.BatteryTemp) + "°C"
			healthParts = append(healthParts, tempText)
		}

		if thermal.FanSpeed > 0 {
			healthParts = append(healthParts, fmt.Sprintf("%d RPM", thermal.FanSpeed))
		}

		summaryParts := append([]string{statusStyle.Render(statusText)}, healthParts...)
		lines = append(lines, strings.Join(summaryParts, " · "))
	}

	return cardData{icon: iconBattery, title: "Power", lines: lines}
}

func isPoweredByAC(statusLower string) bool {
	return statusLower == "charging" ||
		statusLower == "charged" ||
		statusLower == "ac" ||
		strings.Contains(statusLower, "ac attached")
}

func formatBatteryStatus(status string) string {
	status = strings.TrimSpace(status)
	if status == "" {
		return "Unknown"
	}
	lower := strings.ToLower(status)
	switch lower {
	case "ac":
		return "AC"
	case "charged":
		return "Charged"
	case "charging":
		return "Charging"
	case "discharging":
		return "Discharging"
	}
	return strings.ToUpper(status[:1]) + strings.ToLower(status[1:])
}

func renderCard(data cardData, width int, height int) string {
	if width <= 0 {
		width = colWidth
	}

	titleText := data.icon + " " + data.title
	lineLen := max(width-lipgloss.Width(titleText)-2, 0)

	header := titleStyle.Render(titleText)
	if lineLen > 0 {
		header += "  " + lineStyle.Render(strings.Repeat("╌", lineLen))
	}

	lines := wrapToWidth(header, width)
	for _, line := range data.lines {
		lines = append(lines, wrapToWidth(line, width)...)
	}

	for len(lines) < height {
		lines = append(lines, "")
	}
	return strings.Join(lines, "\n")
}

func wrapToWidth(text string, width int) []string {
	if width <= 0 {
		return []string{text}
	}
	wrapped := lipgloss.NewStyle().MaxWidth(width).Render(text)
	return strings.Split(wrapped, "\n")
}

func progressBar(percent float64) string {
	return colorizePercent(percent, plainProgressBar(percent))
}

func plainProgressBar(percent float64) string {
	total := 16
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	filled := int(percent / 100 * float64(total))

	var builder strings.Builder
	for i := range total {
		if i < filled {
			builder.WriteString("█")
		} else {
			builder.WriteString("░")
		}
	}
	return builder.String()
}

func batteryProgressBar(percent float64) string {
	total := 16
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	filled := int(percent / 100 * float64(total))

	var builder strings.Builder
	for i := range total {
		if i < filled {
			builder.WriteString("█")
		} else {
			builder.WriteString("░")
		}
	}
	return colorizeBattery(percent, builder.String())
}

func colorizePercent(percent float64, s string) string {
	switch {
	case percent >= 85:
		return dangerStyle.Render(s)
	case percent >= 60:
		return warnStyle.Render(s)
	default:
		return okStyle.Render(s)
	}
}

func colorizeBattery(percent float64, s string) string {
	switch {
	case percent < 20:
		return dangerStyle.Render(s)
	case percent < 50:
		return warnStyle.Render(s)
	default:
		return okStyle.Render(s)
	}
}

func colorizeTemp(t float64) string {
	switch {
	case t >= thermalHighThreshold:
		return dangerStyle.Render(fmt.Sprintf("%.1f", t))
	case t >= thermalNormalThreshold:
		return warnStyle.Render(fmt.Sprintf("%.1f", t))
	default:
		return okStyle.Render(fmt.Sprintf("%.1f", t))
	}
}

func formatRate(mb float64) string {
	if mb < 0.01 {
		return "0 MB/s"
	}
	if mb < 1 {
		return fmt.Sprintf("%.2f MB/s", mb)
	}
	if mb < 10 {
		return fmt.Sprintf("%.1f MB/s", mb)
	}
	return fmt.Sprintf("%.0f MB/s", mb)
}

func formatRateCompact(mb float64) string {
	if mb < 0.01 {
		return "0"
	}
	if mb < 10 {
		return fmt.Sprintf("%.1f", mb)
	}
	return fmt.Sprintf("%.0f", mb)
}

func humanBytes(v uint64) string {
	return units.BytesBin(v)
}

func humanBytesShort(v uint64) string {
	return units.BytesBinShort(v)
}

func humanBytesCompact(v uint64) string {
	return units.BytesBinCompact(v)
}

func shorten(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-1] + "…"
}

func remainingLineWidth(width int, prefix string) int {
	if width <= 0 {
		width = colWidth
	}
	return max(width-lipgloss.Width(prefix)-1, 0)
}

func renderTwoColumns(cards []cardData, width int) string {
	if len(cards) == 0 {
		return ""
	}
	cw := colWidth
	if width > 0 && width/2-2 > cw {
		cw = width/2 - 2
	}
	var rows []string
	for i := 0; i < len(cards); i += 2 {
		left := renderCard(cards[i], cw, 0)
		right := ""
		if i+1 < len(cards) {
			right = renderCard(cards[i+1], cw, 0)
		}
		targetHeight := max(lipgloss.Height(left), lipgloss.Height(right))
		left = renderCard(cards[i], cw, targetHeight)
		if right != "" {
			right = renderCard(cards[i+1], cw, targetHeight)
			rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, left, "  ", right))
		} else {
			rows = append(rows, left)
		}
	}

	var spacedRows []string
	for i, r := range rows {
		if i > 0 {
			spacedRows = append(spacedRows, "")
		}
		spacedRows = append(spacedRows, r)
	}
	return lipgloss.JoinVertical(lipgloss.Left, spacedRows...)
}
