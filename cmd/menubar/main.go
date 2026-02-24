//go:build darwin

// Package main provides the mo menubar command — a persistent macOS menu bar system monitor.
package main

import (
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"

	"fyne.io/systray"
	"github.com/tw93/mole/internal/metrics"
)

const collectInterval = 3 * time.Second

var collector *metrics.Collector

func main() {
	systray.Run(onReady, onExit)
}

func onReady() {
	systray.SetTemplateIcon(iconData, iconData)
	systray.SetTitle("CPU --% | RAM --%")
	systray.SetTooltip("Mole System Monitor")

	collector = metrics.NewCollector()
	menu := newMenu()

	// Handle signals for clean shutdown.
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGINT, syscall.SIGTERM)
	go func() {
		<-sigCh
		systray.Quit()
	}()

	// Background goroutine: collect metrics and update menu.
	go func() {
		// Initial collection.
		snap, err := collector.Collect()
		if err == nil {
			updateTitle(snap)
			menu.refresh(snap)
		}

		ticker := time.NewTicker(collectInterval)
		defer ticker.Stop()
		for {
			select {
			case <-ticker.C:
				snap, err := collector.Collect()
				if err != nil {
					continue
				}
				updateTitle(snap)
				menu.refresh(snap)
			case <-menu.openTerminal.ClickedCh:
				openTerminalStatus()
			case <-menu.quit.ClickedCh:
				systray.Quit()
				return
			}
		}
	}()
}

func onExit() {
	// systray handles teardown; no additional cleanup required.
}

func updateTitle(snap metrics.MetricsSnapshot) {
	cpuText := fmt.Sprintf("CPU %.0f%%", snap.CPU.Usage)
	memText := fmt.Sprintf("RAM %.0f%%", snap.Memory.UsedPercent)
	systray.SetTitle(cpuText + " | " + memText)
}

func openTerminalStatus() {
	// Use osascript to open a new Terminal window running mo status.
	cmd := fmt.Sprintf(`tell application "Terminal"
	activate
	do script "mo status"
end tell`)
	go func() {
		runOsascript(cmd)
	}()
}

func runOsascript(script string) {
	_ = exec.Command("osascript", "-e", script).Run()
}
