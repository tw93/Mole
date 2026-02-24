//go:build darwin

package main

import (
	"fmt"
	"sort"
	"strings"

	"fyne.io/systray"
	"github.com/tw93/mole/internal/metrics"
)

const sparklineWidth = 16

type menuItems struct {
	// Header
	healthItem   *systray.MenuItem
	hardwareItem *systray.MenuItem

	// CPU
	cpuHeader *systray.MenuItem
	cpuTotal  *systray.MenuItem
	cpuCores  [3]*systray.MenuItem
	cpuLoad   *systray.MenuItem

	// Memory
	memHeader   *systray.MenuItem
	memUsed     *systray.MenuItem
	memFree     *systray.MenuItem
	memSwap     *systray.MenuItem
	memTotal    *systray.MenuItem
	memAvail    *systray.MenuItem
	memPressure *systray.MenuItem

	// Disk
	diskHeader *systray.MenuItem
	diskItems  [4]*systray.MenuItem
	diskRead   *systray.MenuItem
	diskWrite  *systray.MenuItem

	// Power
	battHeader *systray.MenuItem
	battLevel  *systray.MenuItem
	battCap    *systray.MenuItem
	battStatus *systray.MenuItem
	battInfo   *systray.MenuItem

	// Processes
	procsHeader *systray.MenuItem
	procItems   [3]*systray.MenuItem

	// Network
	netHeader *systray.MenuItem
	netDown   *systray.MenuItem
	netUp     *systray.MenuItem
	netInfo   *systray.MenuItem

	// Actions
	openTerminal *systray.MenuItem
	quit         *systray.MenuItem
}

func addDisabled(title, tooltip string) *systray.MenuItem {
	item := systray.AddMenuItem(title, tooltip)
	item.Disable()
	return item
}

func addHidden(title, tooltip string) *systray.MenuItem {
	item := addDisabled(title, tooltip)
	item.Hide()
	return item
}

func newMenu() *menuItems {
	m := &menuItems{}

	// Header
	m.healthItem = addDisabled("Health ● --", "System health")
	m.hardwareItem = addHidden("--", "Hardware info")

	systray.AddSeparator()

	// CPU
	m.cpuHeader = addDisabled("◉ CPU", "")
	m.cpuTotal = addDisabled("Total  --", "")
	for i := range m.cpuCores {
		m.cpuCores[i] = addHidden("--", "")
	}
	m.cpuLoad = addDisabled("Load   --", "")

	systray.AddSeparator()

	// Memory
	m.memHeader = addDisabled("◫ Memory", "")
	m.memUsed = addDisabled("Used   --", "")
	m.memFree = addDisabled("Free   --", "")
	m.memSwap = addHidden("Swap   --", "")
	m.memTotal = addDisabled("Total  --", "")
	m.memAvail = addDisabled("Avail  --", "")
	m.memPressure = addHidden("--", "")

	systray.AddSeparator()

	// Disk
	m.diskHeader = addDisabled("▥ Disk", "")
	for i := range m.diskItems {
		m.diskItems[i] = addHidden("--", "")
	}
	m.diskRead = addDisabled("Read   --", "")
	m.diskWrite = addDisabled("Write  --", "")

	systray.AddSeparator()

	// Power
	m.battHeader = addDisabled("◪ Power", "")
	m.battLevel = addDisabled("Level  --", "")
	m.battCap = addHidden("Health --", "")
	m.battStatus = addHidden("--", "")
	m.battInfo = addHidden("--", "")

	systray.AddSeparator()

	// Processes
	m.procsHeader = addDisabled("❊ Processes", "")
	for i := range m.procItems {
		m.procItems[i] = addHidden("--", "")
	}

	systray.AddSeparator()

	// Network
	m.netHeader = addDisabled("⇅ Network", "")
	m.netDown = addDisabled("Down   --", "")
	m.netUp = addDisabled("Up     --", "")
	m.netInfo = addHidden("--", "")

	systray.AddSeparator()

	// Actions
	m.openTerminal = systray.AddMenuItem("Open Terminal Status", "Open mo status in Terminal")
	m.quit = systray.AddMenuItem("Quit", "Quit Mole Menu Bar")

	return m
}

// refresh updates every menu item to match the mo status view exactly.
func (m *menuItems) refresh(snap metrics.MetricsSnapshot) {
	// ── Header ──────────────────────────────────────────────
	// Extract label from HealthScoreMsg (format: "Good" or "Fair: High CPU, High Memory").
	scoreLabel := snap.HealthScoreMsg
	if i := strings.Index(scoreLabel, ":"); i > 0 {
		scoreLabel = scoreLabel[:i]
	}
	m.healthItem.SetTitle(fmt.Sprintf("%s Health ● %d — %s",
		healthEmoji(snap.HealthScore), snap.HealthScore, scoreLabel))

	// Hardware info line (same as renderHeader in view.go)
	infoParts := []string{}
	if snap.Hardware.Model != "" {
		infoParts = append(infoParts, snap.Hardware.Model)
	}
	if snap.Hardware.CPUModel != "" {
		cpuInfo := snap.Hardware.CPUModel
		if len(snap.GPU) > 0 && snap.GPU[0].CoreCount > 0 {
			cpuInfo += fmt.Sprintf(", %dGPU", snap.GPU[0].CoreCount)
		}
		infoParts = append(infoParts, cpuInfo)
	}
	var specs []string
	if snap.Hardware.TotalRAM != "" {
		specs = append(specs, snap.Hardware.TotalRAM)
	}
	if snap.Hardware.DiskSize != "" {
		specs = append(specs, snap.Hardware.DiskSize)
	}
	if len(specs) > 0 {
		infoParts = append(infoParts, strings.Join(specs, "/"))
	}
	if snap.Hardware.RefreshRate != "" {
		infoParts = append(infoParts, snap.Hardware.RefreshRate)
	}
	if snap.Hardware.OSVersion != "" {
		infoParts = append(infoParts, snap.Hardware.OSVersion)
	}
	if snap.Uptime != "" {
		infoParts = append(infoParts, "up "+snap.Uptime)
	}
	if len(infoParts) > 0 {
		m.hardwareItem.SetTitle(strings.Join(infoParts, " · "))
		m.hardwareItem.Show()
	} else {
		m.hardwareItem.Hide()
	}

	// ── CPU (matches renderCPUCard) ─────────────────────────
	m.cpuHeader.SetTitle(fmt.Sprintf("%s ◉ CPU", percentEmoji(snap.CPU.Usage)))

	headerText := fmt.Sprintf("%5.1f%%", snap.CPU.Usage)
	if snap.Thermal.CPUTemp > 0 {
		headerText += fmt.Sprintf(" @ %.1f°C", snap.Thermal.CPUTemp)
	}
	m.cpuTotal.SetTitle(fmt.Sprintf("Total  %s  %s",
		plainProgressBar(snap.CPU.Usage), headerText))

	if len(snap.CPU.PerCore) > 0 && !snap.CPU.PerCoreEstimated {
		type cu struct {
			idx int
			val float64
		}
		var cores []cu
		for i, v := range snap.CPU.PerCore {
			cores = append(cores, cu{i, v})
		}
		sort.Slice(cores, func(i, j int) bool { return cores[i].val > cores[j].val })
		maxC := min(len(cores), 3)
		for i := 0; i < maxC; i++ {
			c := cores[i]
			m.cpuCores[i].SetTitle(fmt.Sprintf("Core%-2d %s  %5.1f%%",
				c.idx+1, plainProgressBar(c.val), c.val))
			m.cpuCores[i].Show()
		}
		for i := maxC; i < len(m.cpuCores); i++ {
			m.cpuCores[i].Hide()
		}
	} else {
		for i := range m.cpuCores {
			m.cpuCores[i].Hide()
		}
	}

	if snap.CPU.PCoreCount > 0 && snap.CPU.ECoreCount > 0 {
		m.cpuLoad.SetTitle(fmt.Sprintf("Load   %.2f / %.2f / %.2f, %dP+%dE",
			snap.CPU.Load1, snap.CPU.Load5, snap.CPU.Load15,
			snap.CPU.PCoreCount, snap.CPU.ECoreCount))
	} else {
		m.cpuLoad.SetTitle(fmt.Sprintf("Load   %.2f / %.2f / %.2f, %d cores",
			snap.CPU.Load1, snap.CPU.Load5, snap.CPU.Load15, snap.CPU.LogicalCPU))
	}

	// ── Memory (matches renderMemoryCard) ───────────────────
	mem := snap.Memory
	m.memHeader.SetTitle(fmt.Sprintf("%s ◫ Memory", percentEmoji(mem.UsedPercent)))

	m.memUsed.SetTitle(fmt.Sprintf("Used   %s  %5.1f%%",
		plainProgressBar(mem.UsedPercent), mem.UsedPercent))

	freePercent := 100 - mem.UsedPercent
	m.memFree.SetTitle(fmt.Sprintf("Free   %s  %5.1f%%",
		plainProgressBar(freePercent), freePercent))

	hasSwap := mem.SwapTotal > 0 || mem.SwapUsed > 0
	if hasSwap {
		var swapPercent float64
		if mem.SwapTotal > 0 {
			swapPercent = (float64(mem.SwapUsed) / float64(mem.SwapTotal)) * 100.0
		}
		swapText := fmt.Sprintf("%s/%s",
			metrics.HumanBytesCompact(mem.SwapUsed),
			metrics.HumanBytesCompact(mem.SwapTotal))
		m.memSwap.SetTitle(fmt.Sprintf("Swap   %s  %5.1f%% %s",
			plainProgressBar(swapPercent), swapPercent, swapText))
		m.memSwap.Show()
		m.memTotal.SetTitle(fmt.Sprintf("Total  %s / %s",
			metrics.HumanBytes(mem.Used), metrics.HumanBytes(mem.Total)))
		m.memAvail.SetTitle(fmt.Sprintf("Avail  %s",
			metrics.HumanBytes(mem.Total-mem.Used)))
	} else {
		m.memSwap.Hide()
		m.memTotal.SetTitle(fmt.Sprintf("Total  %s / %s",
			metrics.HumanBytes(mem.Used), metrics.HumanBytes(mem.Total)))
		if mem.Cached > 0 {
			m.memAvail.SetTitle(fmt.Sprintf("Cached %s", metrics.HumanBytes(mem.Cached)))
		} else {
			m.memAvail.SetTitle(fmt.Sprintf("Avail  %s",
				metrics.HumanBytes(mem.Total-mem.Used)))
		}
	}

	if mem.Pressure != "" {
		m.memPressure.SetTitle(fmt.Sprintf("%s Status %s",
			pressureEmoji(mem.Pressure), mem.Pressure))
		m.memPressure.Show()
	} else {
		m.memPressure.Hide()
	}

	// ── Disk (matches renderDiskCard) ───────────────────────
	if len(snap.Disks) > 0 {
		internal, external := menuSplitDisks(snap.Disks)
		itemIdx := 0
		addGroup := func(prefix string, list []metrics.DiskStatus) {
			for i, d := range list {
				if itemIdx >= len(m.diskItems) {
					break
				}
				label := menuDiskLabel(prefix, i, len(list))
				m.diskItems[itemIdx].SetTitle(plainFormatDiskLine(label, d))
				m.diskItems[itemIdx].Show()
				itemIdx++
			}
		}
		addGroup("INTR", internal)
		addGroup("EXTR", external)
		for i := itemIdx; i < len(m.diskItems); i++ {
			m.diskItems[i].Hide()
		}
		// Color the header based on the primary disk usage
		all := append(internal, external...)
		m.diskHeader.SetTitle(fmt.Sprintf("%s ▥ Disk", percentEmoji(all[0].UsedPercent)))
	} else {
		m.diskHeader.SetTitle("▥ Disk")
		for i := range m.diskItems {
			m.diskItems[i].Hide()
		}
	}

	m.diskRead.SetTitle(fmt.Sprintf("Read   %s  %.1f MB/s",
		plainIoBar(snap.DiskIO.ReadRate), snap.DiskIO.ReadRate))
	m.diskWrite.SetTitle(fmt.Sprintf("Write  %s  %.1f MB/s",
		plainIoBar(snap.DiskIO.WriteRate), snap.DiskIO.WriteRate))

	// ── Power (matches renderBatteryCard) ───────────────────
	if len(snap.Batteries) > 0 {
		b := snap.Batteries[0]

		m.battHeader.SetTitle(fmt.Sprintf("%s ◪ Power", batteryEmoji(b.Percent)))

		m.battLevel.SetTitle(fmt.Sprintf("Level  %s  %5.1f%%",
			plainProgressBar(b.Percent), b.Percent))
		m.battLevel.Show()

		if b.Capacity > 0 {
			m.battCap.SetTitle(fmt.Sprintf("Health %s  %5d%%",
				plainProgressBar(float64(b.Capacity)), b.Capacity))
			m.battCap.Show()
		} else {
			m.battCap.Hide()
		}

		// Status line
		statusText := b.Status
		if len(statusText) > 0 {
			statusText = strings.ToUpper(statusText[:1]) + strings.ToLower(statusText[1:])
		}
		if b.TimeLeft != "" {
			statusText += " · " + b.TimeLeft
		}
		statusLower := strings.ToLower(b.Status)
		if statusLower == "charging" || statusLower == "charged" {
			if snap.Thermal.SystemPower > 0 {
				statusText += fmt.Sprintf(" · %.0fW", snap.Thermal.SystemPower)
			} else if snap.Thermal.AdapterPower > 0 {
				statusText += fmt.Sprintf(" · %.0fW Adapter", snap.Thermal.AdapterPower)
			}
			statusText += " ⚡"
		} else if snap.Thermal.BatteryPower > 0 {
			statusText += fmt.Sprintf(" · %.0fW", snap.Thermal.BatteryPower)
		}
		m.battStatus.SetTitle(statusText)
		m.battStatus.Show()

		// Health detail line
		healthParts := []string{}
		if b.Health != "" {
			healthParts = append(healthParts, b.Health)
		}
		if b.CycleCount > 0 {
			healthParts = append(healthParts, fmt.Sprintf("%d cycles", b.CycleCount))
		}
		if snap.Thermal.CPUTemp > 0 {
			healthParts = append(healthParts, fmt.Sprintf("%.1f°C", snap.Thermal.CPUTemp))
		}
		if snap.Thermal.FanSpeed > 0 {
			healthParts = append(healthParts, fmt.Sprintf("%d RPM", snap.Thermal.FanSpeed))
		}
		if len(healthParts) > 0 {
			m.battInfo.SetTitle(strings.Join(healthParts, " · "))
			m.battInfo.Show()
		} else {
			m.battInfo.Hide()
		}
	} else {
		m.battHeader.SetTitle("◪ Power")
		m.battLevel.SetTitle("No battery")
		m.battCap.Hide()
		m.battStatus.Hide()
		m.battInfo.Hide()
	}

	// ── Processes (matches renderProcessCard) ───────────────
	maxProcs := min(3, len(snap.TopProcesses))
	for i := 0; i < maxProcs; i++ {
		p := snap.TopProcesses[i]
		name := shortenName(p.Name, 12)
		m.procItems[i].SetTitle(fmt.Sprintf("%-12s  %s  %5.1f%%",
			name, plainMiniBar(p.CPU), p.CPU))
		m.procItems[i].Show()
	}
	for i := maxProcs; i < len(m.procItems); i++ {
		m.procItems[i].Hide()
	}

	// ── Network (matches renderNetworkCard) ─────────────────
	var totalRx, totalTx float64
	var primaryIP string
	for _, n := range snap.Network {
		totalRx += n.RxRateMBs
		totalTx += n.TxRateMBs
		if primaryIP == "" && n.IP != "" && n.Name == "en0" {
			primaryIP = n.IP
		}
	}

	rxSparkline := plainSparkline(snap.NetworkHistory.RxHistory, sparklineWidth)
	txSparkline := plainSparkline(snap.NetworkHistory.TxHistory, sparklineWidth)
	m.netDown.SetTitle(fmt.Sprintf("Down   %s  %s", rxSparkline, metrics.FormatRate(totalRx)))
	m.netUp.SetTitle(fmt.Sprintf("Up     %s  %s", txSparkline, metrics.FormatRate(totalTx)))

	var netInfoParts []string
	if snap.Proxy.Enabled {
		netInfoParts = append(netInfoParts, "Proxy "+snap.Proxy.Type)
	}
	if primaryIP != "" {
		netInfoParts = append(netInfoParts, primaryIP)
	}
	if len(netInfoParts) > 0 {
		m.netInfo.SetTitle(strings.Join(netInfoParts, " · "))
		m.netInfo.Show()
	} else {
		m.netInfo.Hide()
	}
}

// ── Emoji status indicators (match view.go color thresholds) ─

func healthEmoji(score int) string {
	switch {
	case score >= 75:
		return "🟢"
	case score >= 60:
		return "🟡"
	default:
		return "🔴"
	}
}

func percentEmoji(p float64) string {
	switch {
	case p >= 85:
		return "🔴"
	case p >= 60:
		return "🟡"
	default:
		return "🟢"
	}
}

func batteryEmoji(p float64) string {
	switch {
	case p < 20:
		return "🔴"
	case p < 50:
		return "🟡"
	default:
		return "🟢"
	}
}

func pressureEmoji(p string) string {
	switch p {
	case "critical":
		return "🔴"
	case "warn":
		return "🟡"
	default:
		return "🟢"
	}
}

// ── Plain-text bars (same shape as view.go, without terminal colors) ─

func plainProgressBar(percent float64) string {
	total := 16
	if percent < 0 {
		percent = 0
	}
	if percent > 100 {
		percent = 100
	}
	filled := int(percent / 100 * float64(total))
	var b strings.Builder
	for i := range total {
		if i < filled {
			b.WriteString("█")
		} else {
			b.WriteString("░")
		}
	}
	return b.String()
}

func plainIoBar(rate float64) string {
	filled := min(int(rate/10.0), 5)
	if filled < 0 {
		filled = 0
	}
	return strings.Repeat("▮", filled) + strings.Repeat("▯", 5-filled)
}

func plainMiniBar(percent float64) string {
	filled := min(int(percent/20), 5)
	if filled < 0 {
		filled = 0
	}
	return strings.Repeat("▮", filled) + strings.Repeat("▯", 5-filled)
}

func plainSparkline(history []float64, width int) string {
	blocks := []rune{'▁', '▂', '▃', '▄', '▅', '▆', '▇', '█'}
	data := make([]float64, 0, width)
	if len(history) > 0 {
		start := 0
		if len(history) > width {
			start = len(history) - width
		}
		data = append(data, history[start:]...)
	}
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
	var b strings.Builder
	for _, v := range data {
		level := int((v / maxVal) * float64(len(blocks)-1))
		if level < 0 {
			level = 0
		}
		if level >= len(blocks) {
			level = len(blocks) - 1
		}
		b.WriteRune(blocks[level])
	}
	return b.String()
}

// ── Disk helpers (mirrors view.go) ──────────────────────────

func menuSplitDisks(disks []metrics.DiskStatus) (internal, external []metrics.DiskStatus) {
	for _, d := range disks {
		if d.External {
			external = append(external, d)
		} else {
			internal = append(internal, d)
		}
	}
	return internal, external
}

func menuDiskLabel(prefix string, index int, total int) string {
	if total <= 1 {
		return prefix
	}
	return fmt.Sprintf("%s%d", prefix, index+1)
}

func plainFormatDiskLine(label string, d metrics.DiskStatus) string {
	if label == "" {
		label = "DISK"
	}
	bar := plainProgressBar(d.UsedPercent)
	used := metrics.HumanBytesShort(d.Used)
	total := metrics.HumanBytesShort(d.Total)
	return fmt.Sprintf("%-6s %s  %5.1f%%, %s/%s", label, bar, d.UsedPercent, used, total)
}

func shortenName(s string, maxLen int) string {
	if len(s) <= maxLen {
		return s
	}
	return s[:maxLen-1] + "…"
}
