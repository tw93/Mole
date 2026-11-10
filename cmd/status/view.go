package main

import (
	"fmt"
	"slices"
	"sort"
	"strings"
	"time"

	"github.com/charmbracelet/lipgloss"
	"github.com/charmbracelet/x/ansi"

	"github.com/tw93/mole/internal/units"
)

// renderTerminalTooSmall is shown when the dashboard cannot fit the window.
// It stays within both dimensions so the renderer cannot clip away its
// explanation; a later resize recomputes the dashboard from the model.
func renderTerminalTooSmall(width, height int) string {
	return lipgloss.NewStyle().
		Width(width).
		MaxWidth(width).
		MaxHeight(height).
		Render("Terminal too small. Enlarge the window to view status.")
}

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

	// Stands in for a value that has not been measured yet, so a card keeps its
	// shape from the first frame instead of growing when the data lands.
	placeholderValue = "--"
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
	optionalInfoParts := []string{}
	if !compactHeader && m.Hardware.OSVersion != "" {
		optionalInfoParts = append(optionalInfoParts, m.Hardware.OSVersion)
	}
	if !compactHeader && m.Uptime != "" {
		uptimeText := "up " + m.Uptime
		if m.RestartReason != "" {
			// A pending kernel update, not uptime, is what asks for a restart.
			uptimeText = dangerStyle.Render(uptimeText + " ↻")
		} else {
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
			joinInfoParts(identityParts, specParts, optionalInfoParts),
			joinInfoParts(identityParts, specParts),
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
			fitParts := joinInfoParts(identityParts, specParts)
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

func renderProcessAlertBar(alerts []ProcessAlert, processStale *bool, processCollectedAt *time.Time, width int) string {
	active := activeAlerts(alerts)
	if len(active) == 0 {
		return ""
	}

	focus := active[0]
	prefix := "ALERT"
	historical := !processSnapshotFresh(processStale)
	if historical {
		prefix = "LAST ALERT"
		available := max(width-2, 0)
		if width > 0 && lipgloss.Width(prefix) > available {
			prefix = "OLD"
		}
	}

	detail := fmt.Sprintf(
		"%s at %.1f%% for %s (threshold %.1f%%)",
		formatProcessLabel(ProcessInfo{PID: focus.PID, Name: focus.Name}),
		focus.CPU,
		focus.Window,
		focus.Threshold,
	)
	text := prefix + " " + detail
	if len(active) > 1 {
		text += fmt.Sprintf(" · +%d more", len(active)-1)
	}
	if historical {
		freshnessWidth := -1
		if width > 0 {
			freshnessWidth = max(width-2-lipgloss.Width(prefix+" · "), 0)
		}
		if freshness := processFreshnessLabel(processStale, processCollectedAt, freshnessWidth); freshness != "" {
			text = prefix + " · " + freshness + " · " + strings.TrimPrefix(text, prefix+" ")
		}
	}

	return renderBanner(alertBarStyle, text, width)
}

func processSnapshotStale(stale *bool) bool {
	return stale != nil && *stale
}

func processSnapshotFresh(stale *bool) bool {
	return stale != nil && !*stale
}

func processFreshnessLabel(stale *bool, collectedAt *time.Time, maxWidth int) string {
	if processSnapshotFresh(stale) {
		return ""
	}
	base := "STALE"
	if stale == nil {
		base = "UNKNOWN"
	}
	if maxWidth >= 0 && lipgloss.Width(base) > maxWidth {
		return ""
	}
	if base == "UNKNOWN" || collectedAt == nil || collectedAt.IsZero() {
		return base
	}
	label := base + " " + collectedAt.Format(time.RFC3339)
	if maxWidth >= 0 && lipgloss.Width(label) > maxWidth {
		return base
	}
	return label
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

	if cpu.FreqAvgMHz > 0 {
		lines = append(lines, fmt.Sprintf("Freq   %s avg · %s max", formatMHz(cpu.FreqAvgMHz), formatMHz(cpu.FreqMaxMHz)))
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

		if z := mem.Zram; z != nil && z.MemUsed > 0 {
			lines = append(lines, fmt.Sprintf("Zram   %s in %s · %.1fx",
				humanBytesCompact(z.Original), humanBytesCompact(z.MemUsed), z.Ratio))
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
		for _, d := range disks {
			if line := formatBtrfsLine(d); line != "" {
				lines = append(lines, line)
			}
		}
		if smartLine := formatDiskSMARTLine(disks); smartLine != "" {
			lines = append(lines, smartLine)
		}
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

// formatDiskSMARTLine returns "" unless a disk is actually failing.
//
// SMART has one actionable state. "Verified" asks nothing of the user, and
// external enclosures usually do not pass SMART through at all, so a Mac with
// two USB disks rendered "SMART  INTR OK · EXTR1 N/A · EXTR2 N/A": a row whose
// length grew with disk count, carrying no information, and the only row in the
// card wide enough to break the alignment of the ones above it. A failing disk
// still gets a full-width red line, and the health score already counts SMART
// failures either way.
func formatDiskSMARTLine(disks []DiskStatus) string {
	failingLabels := make([]string, 0, len(disks))
	internal, external := splitDisks(disks)
	collectFailing := func(prefix string, list []DiskStatus) {
		for index, disk := range list {
			if disk.SmartStatus != smartStatusFailing {
				continue
			}
			if len(disks) == 1 {
				failingLabels = append(failingLabels, dangerStyle.Render("Failing"))
				continue
			}
			failingLabels = append(failingLabels,
				diskLabel(prefix, index, len(list))+" "+dangerStyle.Render("FAIL"))
		}
	}
	collectFailing("INTR", internal)
	collectFailing("EXTR", external)
	if len(failingLabels) == 0 {
		return ""
	}

	failingLabels = append(failingLabels, dangerStyle.Render("Back up now"))
	return fmt.Sprintf("%-*s %s", metricLabelWidth, "SMART", strings.Join(failingLabels, " · "))
}

// formatBtrfsLine shows chunk allocation for a btrfs disk, which the used/free
// line above cannot: "BTRFS  data 412G/480G · meta 1.2G/2.0G". Allocation is
// the claimed chunk space, so data 412G/480G means 480G is handed to data and
// files fill 412G of it. When metadata is tight (see btrfsMetadataTight) the
// line turns into the warning, since that state ends in ENOSPC with free space
// still reported above.
func formatBtrfsLine(d DiskStatus) string {
	b := d.Btrfs
	if b == nil {
		return ""
	}
	if b.MetadataTight {
		pct := float64(b.MetadataUsed) / float64(b.MetadataTotal) * 100
		return fmt.Sprintf("%-*s %s", metricLabelWidth, "BTRFS",
			dangerStyle.Render(fmt.Sprintf("meta %.0f%% full · %s unallocated", pct, humanBytesShort(b.Unallocated))))
	}
	return fmt.Sprintf("%-*s data %s/%s · meta %s/%s", metricLabelWidth, "BTRFS",
		humanBytesShort(b.DataUsed), humanBytesShort(b.DataTotal),
		humanBytesShort(b.MetadataUsed), humanBytesShort(b.MetadataTotal))
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
		gpu := ""
		if p.GPUMemoryBytes > 0 {
			gpu = " " + subtleStyle.Render("GPU "+humanBytesCompact(p.GPUMemoryBytes))
		}
		// The name keeps priority: GPU memory appears only if 10 columns of name remain.
		if nameWidth := remainingLineWidth(cardWidth, line) - lipgloss.Width(gpu); nameWidth >= 10 {
			line += " " + shorten(p.Name, nameWidth) + gpu
		} else if nameWidth := remainingLineWidth(cardWidth, line); nameWidth > 0 {
			line += " " + shorten(p.Name, nameWidth)
		}
		lines = append(lines, strings.TrimRight(line, " "))
	}
	if len(lines) == 0 {
		lines = append(lines, subtleStyle.Render("Collecting..."))
	}
	return cardData{icon: iconProcs, title: "Processes", lines: lines}
}

// processRows is what the Processes card lists: one row per desktop app, with
// its processes summed ("Firefox ×14"), and one row per process that belongs to
// no app cgroup. The Mac app lists one row per app the same way. Snapshots from
// before grouping (a retained process sample, watch streams) fall back to the
// plain process list; --json keeps both top_apps and top_processes.
func processRows(m MetricsSnapshot) []ProcessInfo {
	if len(m.TopApps) == 0 {
		return m.TopProcesses
	}
	rows := make([]ProcessInfo, 0, len(m.TopApps))
	for _, a := range m.TopApps {
		name := a.Name
		if a.Kind == appKindApp && a.Processes > 1 {
			name = fmt.Sprintf("%s ×%d", name, a.Processes)
		}
		rows = append(rows, ProcessInfo{
			PID: a.PID, Name: name, CPU: a.CPU, Memory: a.Memory,
			MemoryBytes: a.MemoryBytes, GPUMemoryBytes: a.GPUMemoryBytes,
		})
	}
	return rows
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

// buildCards renders every card. batteryProbed says whether a full collection
// has completed at least once; until it has, an empty battery list means "not
// measured yet", not "this Mac has no battery".
func buildCards(m MetricsSnapshot, width int, cpuCores int, batteryProbed bool) []cardData {
	// Zombie counts stay in `status --json` for automation and out of the
	// card: a reaped-child backlog is kernel vocabulary a reader cannot act
	// on, the Mac app's own Status surface never showed it, and the row was
	// spending one of three process slots to say it.
	rows := processRows(m)
	processCard := renderProcessCard(rows, width)
	hasRenderedProcessData := len(rows) > 0
	hasActiveProcessAlert := len(activeAlerts(m.ProcessAlerts)) > 0
	switch {
	case processSnapshotFresh(m.ProcessStale):
		if !hasRenderedProcessData {
			message := "No process activity"
			if hasActiveProcessAlert {
				message = "No process rows · active alert above"
			}
			processCard.lines = []string{subtleStyle.Render(message)}
		}
	case processSnapshotStale(m.ProcessStale):
		freshnessWidth := width
		if freshnessWidth <= 0 {
			freshnessWidth = colWidth
		}
		freshness := processFreshnessLabel(m.ProcessStale, m.ProcessCollectedAt, freshnessWidth)
		if hasRenderedProcessData {
			processCard.lines = append([]string{warnStyle.Render(freshness)}, processCard.lines...)
		} else {
			processCard.lines = []string{warnStyle.Render(freshness + " · no retained process activity")}
		}
	default:
		if hasRenderedProcessData {
			processCard.lines = append([]string{warnStyle.Render("UNKNOWN")}, processCard.lines...)
		} else if hasActiveProcessAlert || m.ProcessCollectedAt != nil || m.ZombieCount != nil {
			processCard.lines = []string{warnStyle.Render("UNKNOWN · process sample unavailable")}
		}
	}
	cards := []cardData{
		renderCPUCard(m.CPU, m.Thermal, cpuCores),
		renderMemoryCard(m.Memory, width),
		renderDiskCard(m.Disks, m.DiskIO, m.TrashSize, m.TrashApprox),
	}
	// A desktop or VM has no battery: hide the Power card instead of printing
	// "No battery". Until a full collection has run, an empty list only means
	// "not measured yet", so the placeholder card keeps the layout still.
	switch {
	case len(m.Batteries) > 0 || !batteryProbed:
		power := renderBatteryCard(m.Batteries, m.Thermal, batteryProbed)
		power.lines = append(power.lines, peripheralLines(m.Peripherals)...)
		cards = append(cards, power)
	case len(m.Peripherals) > 0:
		// A desktop with a wireless mouse or keyboard: the card lists only
		// their batteries.
		cards = append(cards, cardData{icon: iconBattery, title: "Power", lines: peripheralLines(m.Peripherals)})
	}
	cards = append(cards,
		processCard,
		renderNetworkCard(m.Network, m.NetworkHistory, m.Proxy, width),
	)
	// Sensors card disabled - redundant with CPU temp; the readings are in
	// the JSON output.
	return cards
}

func miniBar(percent float64) string {
	filled := max(min(int(percent/20), 5), 0)
	return colorizePercent(percent, strings.Repeat("▮", filled)+strings.Repeat("▯", 5-filled))
}

func renderNetworkCard(netStats []NetworkStatus, history NetworkHistory, proxy ProxyStatus, cardWidth int) cardData {
	var lines []string
	totalRx, totalTx := networkTotals(netStats)
	var primaryIP string

	// The routed physical interface owns the IP line, so Ethernet and USB
	// adapters show theirs. A routed tunnel's address is not the Mac's LAN IP,
	// and an unknown route keeps the en0 fallback.
	for _, n := range netStats {
		if n.IP != "" && n.defaultRoute && !n.defaultTunnel {
			primaryIP = n.IP
			break
		}
	}
	for _, n := range netStats {
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
			if proxy.IsTunnel {
				infoParts = append(infoParts, "Tunnel")
			} else {
				infoParts = append(infoParts, "Proxy "+proxy.Type)
			}
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

func renderBatteryCard(batts []BatteryStatus, thermal ThermalStatus, probed bool) cardData {
	var lines []string
	if len(batts) == 0 && !probed {
		// The first collection is the fast one, and it does not read batteries.
		// Saying "No battery" here told every laptop it had none for the couple
		// of seconds before the first full collection landed. Hold the card's
		// shape with placeholders instead, so the real values replace them
		// without the layout jumping.
		lines = append(lines,
			fmt.Sprintf("Level  %s  %6s", batteryProgressBar(0), placeholderValue),
			fmt.Sprintf("Health %s  %6s", batteryProgressBar(0), placeholderValue),
			subtleStyle.Render(placeholderValue),
		)
	} else if len(batts) == 0 {
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
			case "ok":
				healthParts = append(healthParts, okStyle.Render(label))
			}
		}
		if len(healthParts) == 0 && b.Health != "" {
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

// formatMHz prints a clock as GHz from 1000 MHz up, as the Mac's CPU model
// strings do.
func formatMHz(mhz float64) string {
	if mhz >= 1000 {
		return fmt.Sprintf("%.1f GHz", mhz/1000)
	}
	return fmt.Sprintf("%.0f MHz", mhz)
}

// maxPeripheralLines keeps the Power card short when many devices report.
const maxPeripheralLines = 3

// peripheralLines renders one line per peripheral battery, lowest first, so a
// mouse about to die is the one that shows.
func peripheralLines(peripherals []PeripheralBattery) []string {
	sorted := slices.Clone(peripherals)
	sort.SliceStable(sorted, func(i, j int) bool { return sorted[i].Percent < sorted[j].Percent })
	var lines []string
	for i, p := range sorted {
		if i == maxPeripheralLines {
			break
		}
		value := p.Level
		if p.Percent >= 0 {
			value = fmt.Sprintf("%.0f%%", p.Percent)
			if p.Percent < 20 && p.Status != "charging" {
				value = dangerStyle.Render(value)
			}
		}
		if p.Status == "charging" {
			value += " · Charging"
		}
		lines = append(lines, fmt.Sprintf("%s  %s", shorten(p.Name, 22), value))
	}
	return lines
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

func renderCard(data cardData, width int) string {
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

// shorten fits s into maxLen terminal cells, ending a cut with "…". It counts
// display width rather than runes, so a wide (CJK) name is not drawn at twice
// its budget, and a cut never splits a character such as the "×" in
// "Firefox ×14".
func shorten(s string, maxLen int) string {
	if ansi.StringWidth(s) <= maxLen {
		return s
	}
	return ansi.Truncate(s, maxLen, "…")
}

func remainingLineWidth(width int, prefix string) int {
	if width <= 0 {
		width = colWidth
	}
	return max(width-lipgloss.Width(prefix)-1, 0)
}

// columnRow is one row of the two-column layout: a left cell and a right cell,
// each a vertical stack of one or more cards.
type columnRow struct {
	left  []cardData
	right []cardData
}

// layoutColumnRows groups cards into rows so section titles stay aligned across
// the two columns. Each row seeds its left cell with one card, then stacks cards
// into the right cell until it is at least as tall as the left, so a tall card
// (e.g. CPU listing many cores) is matched by several short cards (GPU, Memory,
// ...) beside it instead of leaving a gap. The shorter cell is padded to the row
// height at render time, which keeps the next row's titles aligned. Heights are
// measured at column width cw, so the grouping adapts live as cards grow/shrink.
func layoutColumnRows(cards []cardData, cw int) []columnRow {
	stackHeight := func(cs []cardData) int {
		h := 0
		for i, c := range cs {
			if i > 0 {
				h++ // blank separator between stacked cards
			}
			h += lipgloss.Height(renderCard(c, cw))
		}
		return h
	}

	var rows []columnRow
	i := 0
	for i < len(cards) {
		row := columnRow{left: []cardData{cards[i]}}
		i++
		leftH := stackHeight(row.left)
		for i < len(cards) && stackHeight(row.right) < leftH {
			row.right = append(row.right, cards[i])
			i++
		}
		rows = append(rows, row)
	}
	return rows
}

func renderTwoColumns(cards []cardData, width int) string {
	if len(cards) == 0 {
		return ""
	}
	cw := colWidth
	if width > 0 && width/2-2 > cw {
		cw = width/2 - 2
	}

	renderCell := func(cs []cardData) string {
		var parts []string
		for i, c := range cs {
			if i > 0 {
				parts = append(parts, "")
			}
			parts = append(parts, renderCard(c, cw))
		}
		return lipgloss.JoinVertical(lipgloss.Left, parts...)
	}

	renderRows := func(layout []columnRow) string {
		var rows []string
		for _, row := range layout {
			left := renderCell(row.left)
			if len(row.right) == 0 {
				rows = append(rows, left)
				continue
			}
			right := renderCell(row.right)
			// JoinHorizontal (Top) pads the shorter cell to the taller, so the next
			// row's titles line up in both columns.
			rows = append(rows, lipgloss.JoinHorizontal(lipgloss.Top, left, "  ", right))
		}

		var spaced []string
		for i, row := range rows {
			if i > 0 {
				spaced = append(spaced, "")
			}
			spaced = append(spaced, row)
		}
		return lipgloss.JoinVertical(lipgloss.Left, spaced...)
	}

	var fixedLayout []columnRow
	for i := 0; i < len(cards); i += 2 {
		row := columnRow{left: []cardData{cards[i]}}
		if i+1 < len(cards) {
			row.right = []cardData{cards[i+1]}
		}
		fixedLayout = append(fixedLayout, row)
	}

	fixed := renderRows(fixedLayout)
	stacked := renderRows(layoutColumnRows(cards, cw))
	// Dynamic stacking is useful for a tall CPU card, but a greedy stack can
	// overshoot a shorter row and grow the whole dashboard. Keep the stable
	// pair layout unless stacking saves vertical space.
	if lipgloss.Height(stacked) < lipgloss.Height(fixed) {
		return stacked
	}
	return fixed
}
