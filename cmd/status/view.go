package main

import (
	"fmt"
	"sort"
	"strconv"
	"strings"

	"github.com/charmbracelet/lipgloss"
)

var (
	titleStyle  = lipgloss.NewStyle().Foreground(lipgloss.Color("#5FD7FF")).Bold(true)
	subtleStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#6C6C6C"))
	warnStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#FFD75F"))
	dangerStyle = lipgloss.NewStyle().Foreground(lipgloss.Color("#FF5F5F")).Bold(true)
	okStyle     = lipgloss.NewStyle().Foreground(lipgloss.Color("#87D787"))
	lineStyle   = lipgloss.NewStyle().Foreground(lipgloss.Color("#4A4A4A"))
)

const (
	colWidth    = 38
	iconCPU     = "⚙"
	iconMemory  = "▦"
	iconGPU     = "▣"
	iconDisk    = "▤"
	iconNetwork = "⇅"
	iconBattery = "▮"
	iconSensors = "♨"
	iconProcs   = "▶"
)

// Mole body frames (legs animate)
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

// Generate frames with horizontal movement
func getMoleFrame(animFrame int, termWidth int) string {
	bodyIdx := animFrame % len(moleBody)
	body := moleBody[bodyIdx]

	// Calculate mole width (approximate)
	moleWidth := 15
	// Move across terminal width
	maxPos := termWidth - moleWidth
	if maxPos < 0 {
		maxPos = 0
	}

	// Move position: 0 -> maxPos -> 0
	cycleLength := maxPos * 2
	if cycleLength == 0 {
		cycleLength = 1
	}
	pos := animFrame % cycleLength
	if pos > maxPos {
		pos = cycleLength - pos
	}

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

func renderHeader(m MetricsSnapshot, errMsg string, animFrame int, termWidth int) string {
	// Title
    title := titleStyle.Render(t("title_status"))

	// Health Score with color and label
	scoreStyle := getScoreStyle(m.HealthScore)
    scoreText := subtleStyle.Render(t("label_health")+" ") + scoreStyle.Render(fmt.Sprintf("● %d", m.HealthScore))

	// Hardware info
	infoParts := []string{}
	if m.Hardware.Model != "" {
		infoParts = append(infoParts, m.Hardware.Model)
	}
	if m.Hardware.CPUModel != "" {
		infoParts = append(infoParts, m.Hardware.CPUModel)
	}
	if m.Hardware.TotalRAM != "" {
		infoParts = append(infoParts, m.Hardware.TotalRAM)
	}
	if m.Hardware.DiskSize != "" {
		infoParts = append(infoParts, m.Hardware.DiskSize)
	}
	if m.Hardware.OSVersion != "" {
		infoParts = append(infoParts, m.Hardware.OSVersion)
	}

	headerLine := title + "  " + scoreText + "  " + subtleStyle.Render(strings.Join(infoParts, " · "))

	// Running mole animation
	mole := getMoleFrame(animFrame, termWidth)

	if errMsg != "" {
		return lipgloss.JoinVertical(lipgloss.Left, headerLine, "", mole, dangerStyle.Render(errMsg), "")
	}
	return headerLine + "\n\n" + mole
}

func getScoreStyle(score int) lipgloss.Style {
	if score >= 90 {
		// Excellent - Green
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#87D787")).Bold(true)
	} else if score >= 75 {
		// Good - Light Green
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#AFD787")).Bold(true)
	} else if score >= 60 {
		// Fair - Yellow
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#FFD75F")).Bold(true)
	} else if score >= 40 {
		// Poor - Orange
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#FFAF5F")).Bold(true)
	} else {
		// Critical - Red
		return lipgloss.NewStyle().Foreground(lipgloss.Color("#FF5F5F")).Bold(true)
	}
}

func buildCards(m MetricsSnapshot, _ int) []cardData {
	// Row 1: CPU + Memory
	// Row 2: Disk + Power
	// Row 3: Top Processes + Network
	cards := []cardData{
		renderCPUCard(m.CPU),
		renderMemoryCard(m.Memory),
		renderDiskCard(m.Disks, m.DiskIO),
		renderBatteryCard(m.Batteries, m.Thermal),
		renderProcessCard(m.TopProcesses),
		renderNetworkCard(m.Network, m.Proxy),
	}
	// Only show GPU card if there are GPUs with usage data
	if len(m.GPU) > 0 && m.GPU[0].Usage >= 0 {
		cards = append(cards, renderGPUCard(m.GPU))
	}
	// Only show sensors if we have valid temperature readings
	if hasSensorData(m.Sensors) {
		cards = append(cards, renderSensorsCard(m.Sensors))
	}
	return cards
}

func hasSensorData(sensors []SensorReading) bool {
	for _, s := range sensors {
		if s.Note == "" && s.Value > 0 {
			return true
		}
	}
	return false
}

func renderCPUCard(cpu CPUStatus) cardData {
	var lines []string
    lines = append(lines, fmt.Sprintf("%s  %s  %5.1f%%", t("label_total"), progressBar(cpu.Usage), cpu.Usage))
    lines = append(lines, subtleStyle.Render(fmt.Sprintf("%.2f / %.2f / %.2f  (%d %s)", cpu.Load1, cpu.Load5, cpu.Load15, cpu.LogicalCPU, t("label_cores"))))

	// Show top 3 busiest cores
	type coreUsage struct {
		idx int
		val float64
	}
	var cores []coreUsage
	for i, v := range cpu.PerCore {
		cores = append(cores, coreUsage{i, v})
	}
	sort.Slice(cores, func(i, j int) bool { return cores[i].val > cores[j].val })

	maxCores := 3
	if len(cores) < maxCores {
		maxCores = len(cores)
	}
	for i := 0; i < maxCores; i++ {
		c := cores[i]
        lines = append(lines, fmt.Sprintf("%s%-2d %s  %5.1f%%", t("label_core"), c.idx+1, progressBar(c.val), c.val))
	}

    return cardData{icon: iconCPU, title: t("title_cpu"), lines: lines}
}

func renderGPUCard(gpus []GPUStatus) cardData {
	var lines []string
	if len(gpus) == 0 {
        lines = append(lines, subtleStyle.Render(t("no_gpu")))
	} else {
		for _, g := range gpus {
			name := shorten(g.Name, 12)
			if g.Usage >= 0 {
				lines = append(lines, fmt.Sprintf("%-12s  %s  %5.1f%%", name, progressBar(g.Usage), g.Usage))
			} else {
				lines = append(lines, name)
			}
		}
	}
    return cardData{icon: iconGPU, title: t("title_gpu"), lines: lines}
}

func renderMemoryCard(mem MemoryStatus) cardData {
	var lines []string
    lines = append(lines, fmt.Sprintf("%s   %s  %5.1f%%", t("label_used"), progressBar(mem.UsedPercent), mem.UsedPercent))
    lines = append(lines, subtleStyle.Render(fmt.Sprintf("%s / %s %s", humanBytes(mem.Used), humanBytes(mem.Total), t("label_total_word"))))
	lines = append(lines, "")
	// Show available memory
	available := mem.Total - mem.Used
	freePercent := 100 - mem.UsedPercent
    lines = append(lines, fmt.Sprintf("%s   %s  %5.1f%%", t("label_free"), progressBar(freePercent), freePercent))
    lines = append(lines, subtleStyle.Render(fmt.Sprintf("%s %s", humanBytes(available), t("label_available"))))
	// Memory pressure
	if mem.Pressure != "" {
		pressureStyle := okStyle
        pressureText := t("label_status") + " " + translateStatus(mem.Pressure)
		if mem.Pressure == "warn" {
			pressureStyle = warnStyle
		} else if mem.Pressure == "critical" {
			pressureStyle = dangerStyle
		}
		lines = append(lines, pressureStyle.Render(pressureText))
	}
    return cardData{icon: iconMemory, title: t("title_memory"), lines: lines}
}

func renderDiskCard(disks []DiskStatus, io DiskIOStatus) cardData {
	var lines []string
	// Show main disk
	if len(disks) > 0 {
		d := disks[0]
		freeSpace := d.Total - d.Used
		bar := diskBar(d.UsedPercent)
        lines = append(lines, fmt.Sprintf("%s   %s  %4.0f%%  (%s %s)", t("label_used"), bar, d.UsedPercent, humanBytes(freeSpace), t("label_free")))
	}
	// IO
	readBar := ioBar(io.ReadRate)
	writeBar := ioBar(io.WriteRate)
    lines = append(lines, fmt.Sprintf("%s   %s  %.1f MB/s", t("label_read"), readBar, io.ReadRate))
    lines = append(lines, fmt.Sprintf("%s  %s  %.1f MB/s", t("label_write"), writeBar, io.WriteRate))
    return cardData{icon: iconDisk, title: t("title_disk"), lines: lines}
}

func diskBar(percent float64) string {
	total := 16
	filled := int(percent / 100 * float64(total))
	if filled > total {
		filled = total
	}
	bar := strings.Repeat("█", filled) + strings.Repeat("░", total-filled)
	return colorizePercent(percent, bar)
}

func ioBar(rate float64) string {
	// Scale: 0-50 MB/s maps to 0-5 blocks
	filled := int(rate / 10.0)
	if filled > 5 {
		filled = 5
	}
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
        lines = append(lines, subtleStyle.Render(t("no_data")))
    }
    return cardData{icon: iconProcs, title: t("title_processes"), lines: lines}
}

func miniBar(percent float64) string {
	filled := int(percent / 20) // 5 chars max for 100%
	if filled > 5 {
		filled = 5
	}
	if filled < 0 {
		filled = 0
	}
	return colorizePercent(percent, strings.Repeat("▮", filled)+strings.Repeat("▯", 5-filled))
}

func renderNetworkCard(netStats []NetworkStatus, proxy ProxyStatus) cardData {
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
        lines = []string{subtleStyle.Render(t("collecting"))}
	} else {
		rxBar := netBar(totalRx)
		txBar := netBar(totalTx)
        lines = append(lines, fmt.Sprintf("%s   %s  %s", t("down"), rxBar, formatRate(totalRx)))
        lines = append(lines, fmt.Sprintf("%s     %s  %s", t("up"), txBar, formatRate(totalTx)))
		// Proxy + IP
		info := ""
		if proxy.Enabled {
            info = okStyle.Render(t("proxy") + " " + proxy.Type)
		}
		if primaryIP != "" {
			if info != "" {
				info += " · "
			}
			info += primaryIP
		}
		if info != "" {
			lines = append(lines, subtleStyle.Render(info))
		}
	}
    return cardData{icon: iconNetwork, title: t("title_network"), lines: lines}
}

func netBar(rate float64) string {
	// Scale: 0-10 MB/s maps to 0-5 blocks
	filled := int(rate / 2.0)
	if filled > 5 {
		filled = 5
	}
	if filled < 0 {
		filled = 0
	}
	bar := strings.Repeat("▮", filled) + strings.Repeat("▯", 5-filled)
	if rate > 8 {
		return dangerStyle.Render(bar)
	}
	if rate > 3 {
		return warnStyle.Render(bar)
	}
	return okStyle.Render(bar)
}

func renderBatteryCard(batts []BatteryStatus, thermal ThermalStatus) cardData {
	var lines []string
    if len(batts) == 0 {
        lines = append(lines, subtleStyle.Render(t("no_battery")))
	} else {
		b := batts[0]
		// Line 1: label + percentage + bar
        lines = append(lines, fmt.Sprintf("%s  %3.0f%%  %s", t("label_level"), b.Percent, progressBar(b.Percent)))

		// Line 2: status
		statusIcon := ""
		statusStyle := subtleStyle
		statusLower := strings.ToLower(b.Status)
		if statusLower == "charging" || statusLower == "charged" {
			statusIcon = " ⚡"
			statusStyle = okStyle
		} else if b.Percent < 20 {
			statusStyle = dangerStyle
		}
		// Capitalize first letter
        statusText := translateStatus(b.Status)
		if len(statusText) > 0 {
			statusText = strings.ToUpper(statusText[:1]) + strings.ToLower(statusText[1:])
		}
		if b.TimeLeft != "" {
			statusText += " · " + b.TimeLeft
		}
		lines = append(lines, statusStyle.Render(statusText+statusIcon))

		// Line 3: Health + cycles
		healthParts := []string{}
        if b.Health != "" {
            healthParts = append(healthParts, translateStatus(b.Health))
        }
		if b.CycleCount > 0 {
            healthParts = append(healthParts, fmt.Sprintf("%d %s", b.CycleCount, t("label_cycles")))
		}
		if len(healthParts) > 0 {
			lines = append(lines, subtleStyle.Render(strings.Join(healthParts, " · ")))
		}

		// Line 4: Temp + Fan combined
		var thermalParts []string
		if thermal.CPUTemp > 0 {
			tempStyle := okStyle
			if thermal.CPUTemp > 80 {
				tempStyle = dangerStyle
			} else if thermal.CPUTemp > 60 {
				tempStyle = warnStyle
			}
			thermalParts = append(thermalParts, tempStyle.Render(fmt.Sprintf("%.0f°C", thermal.CPUTemp)))
		}
		if thermal.FanSpeed > 0 {
			thermalParts = append(thermalParts, fmt.Sprintf("%d RPM", thermal.FanSpeed))
		}
		if len(thermalParts) > 0 {
			lines = append(lines, strings.Join(thermalParts, " · "))
		}
	}
    return cardData{icon: iconBattery, title: t("title_power"), lines: lines}
}

func renderSensorsCard(sensors []SensorReading) cardData {
	var lines []string
	for _, s := range sensors {
		if s.Note != "" {
			continue
		}
		lines = append(lines, fmt.Sprintf("%-12s %s", shorten(s.Label, 12), colorizeTemp(s.Value)+s.Unit))
	}
    if len(lines) == 0 {
        lines = append(lines, subtleStyle.Render(t("no_sensors")))
    }
    return cardData{icon: iconSensors, title: t("title_sensors"), lines: lines}
}


func renderCard(data cardData, width int, height int) string {
	titleText := data.icon + " " + data.title
	lineLen := width - lipgloss.Width(titleText) - 1
	if lineLen < 4 {
		lineLen = 4
	}
	header := titleStyle.Render(titleText) + " " + lineStyle.Render(strings.Repeat("─", lineLen))
	content := header + "\n" + strings.Join(data.lines, "\n") + "\n"

	// Pad to target height
	lines := strings.Split(content, "\n")
	for len(lines) < height {
		lines = append(lines, "")
	}
	return strings.Join(lines, "\n")
}

func progressBar(percent float64) string {
	total := 18
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	filled := int(percent / 100 * float64(total))
	if filled > total {
		filled = total
	}

	var builder strings.Builder
	for i := 0; i < total; i++ {
		if i < filled {
			builder.WriteString("█")
		} else {
			builder.WriteString("░")
		}
	}
	return colorizePercent(percent, builder.String())
}

func colorizePercent(percent float64, s string) string {
	switch {
	case percent >= 90:
		return dangerStyle.Render(s)
	case percent >= 70:
		return warnStyle.Render(s)
	default:
		return okStyle.Render(s)
	}
}

func colorizeTemp(t float64) string {
	switch {
	case t >= 85:
		return dangerStyle.Render(fmt.Sprintf("%.1f", t))
	case t >= 70:
		return warnStyle.Render(fmt.Sprintf("%.1f", t))
	default:
		return subtleStyle.Render(fmt.Sprintf("%.1f", t))
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

func shorten(s string, max int) string {
	if len(s) <= max {
		return s
	}
	return s[:max-1] + "…"
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
		targetHeight := maxInt(lipgloss.Height(left), lipgloss.Height(right))
		left = renderCard(cards[i], cw, targetHeight)
		if right != "" {
			right = renderCard(cards[i+1], cw, targetHeight)
			rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, left, "  ", right))
		} else {
			rows = append(rows, left)
		}
	}
	return lipgloss.JoinVertical(lipgloss.Left, rows...)
}

func maxInt(a, b int) int {
	if a > b {
		return a
	}
	return b
}
