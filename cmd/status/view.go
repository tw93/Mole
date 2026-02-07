package main

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

var (
	titleStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#C79FD7")).Bold(true)
	subtleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#737373"))
	warnStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFD75F"))
	dangerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF5F5F")).Bold(true)
	okStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#A5D6A7"))
	lineStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#404040"))

	primaryStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#BD93F9"))
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

func renderHeader(m MetricsSnapshot, errMsg string, animFrame int, termWidth int, catHidden bool) string {
	title := titleStyle.Render("Status")

	scoreStyle := getScoreStyle(m.HealthScore)
	scoreText := subtleStyle.Render("Health ") + scoreStyle.Render(fmt.Sprintf("● %d", m.HealthScore))

	// Hardware info for a single line.
	infoParts := []string{}
	if m.Hardware.Model != "" {
		infoParts = append(infoParts, primaryStyle.Render(m.Hardware.Model))
	}
	if m.Hardware.CPUModel != "" {
		cpuInfo := m.Hardware.CPUModel
		// Append GPU core count when available.
		if len(m.GPU) > 0 && m.GPU[0].CoreCount > 0 {
			cpuInfo += fmt.Sprintf(", %dGPU", m.GPU[0].CoreCount)
		}
		infoParts = append(infoParts, cpuInfo)
	}
	var specs []string
	if m.Hardware.TotalRAM != "" {
		specs = append(specs, m.Hardware.TotalRAM)
	}
	if m.Hardware.DiskSize != "" {
		specs = append(specs, m.Hardware.DiskSize)
	}
	if len(specs) > 0 {
		infoParts = append(infoParts, strings.Join(specs, "/"))
	}
	if m.Hardware.RefreshRate != "" {
		infoParts = append(infoParts, m.Hardware.RefreshRate)
	}
	if m.Hardware.OSVersion != "" {
		infoParts = append(infoParts, m.Hardware.OSVersion)
	}
	if m.Uptime != "" {
		infoParts = append(infoParts, subtleStyle.Render("up "+m.Uptime))
	}

	headerLine := title + "  " + scoreText + "  " + strings.Join(infoParts, " · ")

	// Show cat unless hidden
	var mole string
	if !catHidden {
		mole = getMoleFrame(animFrame, termWidth)
	}

	if errMsg != "" {
		if mole == "" {
			return lipgloss.JoinVertical(lipgloss.Left, headerLine, "", dangerStyle.Render("ERROR: "+errMsg), "")
		}
		return lipgloss.JoinVertical(lipgloss.Left, headerLine, "", mole, dangerStyle.Render("ERROR: "+errMsg), "")
	}
	if mole == "" {
		return headerLine
	}
	return headerLine + "\n" + mole
}

func getScoreStyle(score int) lipgloss.Style {
	switch {
	case score >= 90:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#87FF87")).Bold(true)
	case score >= 75:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#87D787")).Bold(true)
	case score >= 60:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#FFD75F")).Bold(true)
	case score >= 40:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#FFAF5F")).Bold(true)
	default:
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#FF6B6B")).Bold(true)
	}
}

func renderCPUCard(cpu CPUStatus, thermal ThermalStatus) cardData {
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

		maxCores := min(len(cores), 3)
		for i := 0; i < maxCores; i++ {
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

func renderMemoryCard(mem MemoryStatus) cardData {
	// Check if swap is being used (or at least allocated).
	hasSwap := mem.SwapTotal > 0 || mem.SwapUsed > 0

	var lines []string
	// Line 1: Used
	lines = append(lines, fmt.Sprintf("Used   %s  %5.1f%%", progressBar(mem.UsedPercent), mem.UsedPercent))

	// Line 2: Free
	freePercent := 100 - mem.UsedPercent
	lines = append(lines, fmt.Sprintf("Free   %s  %5.1f%%", progressBar(freePercent), freePercent))

	if hasSwap {
		// Layout with Swap:
		// 3. Swap (progress bar + text)
		// 4. Total
		// 5. Avail
		var swapPercent float64
		if mem.SwapTotal > 0 {
			swapPercent = (float64(mem.SwapUsed) / float64(mem.SwapTotal)) * 100.0
		}
		swapText := fmt.Sprintf("%s/%s", humanBytesCompact(mem.SwapUsed), humanBytesCompact(mem.SwapTotal))
		lines = append(lines, fmt.Sprintf("Swap   %s  %5.1f%% %s", progressBar(swapPercent), swapPercent, swapText))

		lines = append(lines, fmt.Sprintf("Total  %s / %s", humanBytes(mem.Used), humanBytes(mem.Total)))
		lines = append(lines, fmt.Sprintf("Avail  %s", humanBytes(mem.Total-mem.Used))) // Simplified avail logic for consistency
	} else {
		// Layout without Swap:
		// 3. Total
		// 4. Cached (if > 0)
		// 5. Avail
		lines = append(lines, fmt.Sprintf("Total  %s / %s", humanBytes(mem.Used), humanBytes(mem.Total)))

		if mem.Cached > 0 {
			lines = append(lines, fmt.Sprintf("Cached %s", humanBytes(mem.Cached)))
		}
		// Calculate available if not provided directly, or use Total-Used as proxy if needed,
		// but typically available is more nuanced. Using what we have.
		// Re-calculating available based on logic if needed, but mem.Total - mem.Used is often "Avail"
		// in simple terms for this view or we could use the passed definition.
		// Original code calculated: available := mem.Total - mem.Used
		available := mem.Total - mem.Used
		lines = append(lines, fmt.Sprintf("Avail  %s", humanBytes(available)))
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

func renderDiskCard(disks []DiskStatus, io DiskIOStatus) cardData {
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
		}
	}
	readBar := ioBar(io.ReadRate)
	writeBar := ioBar(io.WriteRate)
	lines = append(lines, fmt.Sprintf("Read   %s  %.1f MB/s", readBar, io.ReadRate))
	lines = append(lines, fmt.Sprintf("Write  %s  %.1f MB/s", writeBar, io.WriteRate))
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
	total := humanBytesShort(d.Total)
	return fmt.Sprintf("%-6s %s  %5.1f%%, %s/%s", label, bar, d.UsedPercent, used, total)
}

func ioBar(rate float64) string {
	filled := min(int(rate/10.0), 5)
	if filled < 0 {
		filled = 0
	}
	bar := strings.Repeat("▮", filled) + strings.Repeat("▯", 5-filled)
	if rate > 80 {
		return dangerStyle.Render(bar)
	}
	if rate > 30 {
		return warnStyle.Render(bar)
	}
	return okStyle.Render(bar)
}

func renderProcessCard(procs []ProcessInfo) cardData {
	var lines []string
	maxProcs := 3
	for i, p := range procs {
		if i >= maxProcs {
			break
		}
		name := shorten(p.Name, 12)
		cpuBar := miniBar(p.CPU)
		lines = append(lines, fmt.Sprintf("%-12s  %s  %5.1f%%", name, cpuBar, p.CPU))
	}
	if len(lines) == 0 {
		lines = append(lines, subtleStyle.Render("No data"))
	}
	return cardData{icon: iconProcs, title: "Processes", lines: lines}
}

func buildCards(m MetricsSnapshot, width int) []cardData {
	cards := []cardData{
		renderCPUCard(m.CPU, m.Thermal),
		renderMemoryCard(m.Memory),
		renderDiskCard(m.Disks, m.DiskIO),
		renderBatteryCard(m.Batteries, m.Thermal),
		renderProcessCard(m.TopProcesses),
		renderNetworkCard(m.Network, m.NetworkHistory, m.Proxy, width),
	}
	// Sensors card disabled - redundant with CPU temp
	// if hasSensorData(m.Sensors) {
	// 	cards = append(cards, renderSensorsCard(m.Sensors))
	// }
	return cards
}

func miniBar(percent float64) string {
	filled := min(int(percent/20), 5)
	if filled < 0 {
		filled = 0
	}
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
		lines = []string{subtleStyle.Render("Collecting...")}
	} else {
		// Calculate dynamic width
		// Layout: "Down   " (7) + graph + "  " (2) + rate (approx 10-12)
		// Safe margin: 22 chars.
		// We target 16 chars to match progressBar implementation for visual consistency.
		graphWidth := cardWidth - 22
		if graphWidth < 5 {
			graphWidth = 5
		}
		if graphWidth > 16 {
			graphWidth = 16 // Match progressBar fixed width
		}

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
		level := int((v / maxVal) * float64(len(blocks)-1))
		if level < 0 {
			level = 0
		}
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

		statusIcon := ""
		statusStyle := subtleStyle
		if statusLower == "charging" || statusLower == "charged" {
			statusIcon = " ⚡"
			statusStyle = okStyle
		} else if b.Percent < 20 {
			statusStyle = dangerStyle
		}
		statusText := b.Status
		if len(statusText) > 0 {
			statusText = strings.ToUpper(statusText[:1]) + strings.ToLower(statusText[1:])
		}
		if b.TimeLeft != "" {
			statusText += " · " + b.TimeLeft
		}
		// Add power info.
		if statusLower == "charging" || statusLower == "charged" {
			if thermal.SystemPower > 0 {
				statusText += fmt.Sprintf(" · %.0fW", thermal.SystemPower)
			} else if thermal.AdapterPower > 0 {
				statusText += fmt.Sprintf(" · %.0fW Adapter", thermal.AdapterPower)
			}
		} else if thermal.BatteryPower > 0 {
			// Only show battery power when discharging (positive value)
			statusText += fmt.Sprintf(" · %.0fW", thermal.BatteryPower)
		}
		lines = append(lines, statusStyle.Render(statusText+statusIcon))

		healthParts := []string{}
		if b.Health != "" {
			healthParts = append(healthParts, b.Health)
		}
		if b.CycleCount > 0 {
			healthParts = append(healthParts, fmt.Sprintf("%d cycles", b.CycleCount))
		}

		if thermal.CPUTemp > 0 {
			tempText := colorizeTemp(thermal.CPUTemp) + "°C" // Reuse common color logic
			healthParts = append(healthParts, tempText)
		}

		if thermal.FanSpeed > 0 {
			healthParts = append(healthParts, fmt.Sprintf("%d RPM", thermal.FanSpeed))
		}

		if len(healthParts) > 0 {
			lines = append(lines, strings.Join(healthParts, " · "))
		}
	}

	return cardData{icon: iconBattery, title: "Power", lines: lines}
}

func renderCard(data cardData, width int, height int) string {
	titleText := data.icon + " " + data.title
	lineLen := max(width-lipgloss.Width(titleText)-2, 4)
	header := titleStyle.Render(titleText) + "  " + lineStyle.Render(strings.Repeat("╌", lineLen))
	content := header + "\n" + strings.Join(data.lines, "\n")

	lines := strings.Split(content, "\n")
	for len(lines) < height {
		lines = append(lines, "")
	}
	return strings.Join(lines, "\n")
}

func progressBar(percent float64) string {
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
	return colorizePercent(percent, builder.String())
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
	case t >= 76:
		return dangerStyle.Render(fmt.Sprintf("%.1f", t))
	case t >= 56:
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

func humanBytes(v uint64) string {
	switch {
	case v > 1<<40:
		return fmt.Sprintf("%.1f TB", float64(v)/(1<<40))
	case v > 1<<30:
		return fmt.Sprintf("%.1f GB", float64(v)/(1<<30))
	case v > 1<<20:
		return fmt.Sprintf("%.1f MB", float64(v)/(1<<20))
	case v > 1<<10:
		return fmt.Sprintf("%.1f KB", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10) + " B"
	}
}

func humanBytesShort(v uint64) string {
	switch {
	case v >= 1<<40:
		return fmt.Sprintf("%.0fT", float64(v)/(1<<40))
	case v >= 1<<30:
		return fmt.Sprintf("%.0fG", float64(v)/(1<<30))
	case v >= 1<<20:
		return fmt.Sprintf("%.0fM", float64(v)/(1<<20))
	case v >= 1<<10:
		return fmt.Sprintf("%.0fK", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10)
	}
}

func humanBytesCompact(v uint64) string {
	switch {
	case v >= 1<<40:
		return fmt.Sprintf("%.1fT", float64(v)/(1<<40))
	case v >= 1<<30:
		return fmt.Sprintf("%.1fG", float64(v)/(1<<30))
	case v >= 1<<20:
		return fmt.Sprintf("%.1fM", float64(v)/(1<<20))
	case v >= 1<<10:
		return fmt.Sprintf("%.1fK", float64(v)/(1<<10))
	default:
		return strconv.FormatUint(v, 10)
	}
}

func shorten(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-1] + "…"
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
