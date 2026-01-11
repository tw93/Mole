import SwiftUI
import AppKit

class MenuBarController: NSObject {
    private var statusItem: NSStatusItem
    private var metricsManager: MetricsManager
    private var timer: Timer?
    private var updateInterval: TimeInterval = 2.0
    private var menu: NSMenu?
    private var iconView: MenuBarIconView?

    init(statusItem: NSStatusItem) {
        self.statusItem = statusItem
        self.metricsManager = MetricsManager()
        super.init()
    }

    func setup() {
        NSLog("MenuBarController: setup() called")

        // Initialize metrics collection
        metricsManager.initialize()
        NSLog("MenuBarController: metricsManager initialized")

        // Don't use custom icon view for now, just keep the text
        // This simplifies debugging
        if let button = statusItem.button {
            // Button already has "🔍 Mole" from AppDelegate
            NSLog("MenuBarController: button title is: %@", button.title)
        } else {
            NSLog("MenuBarController: ERROR - statusItem.button is nil!")
        }

        // Start updating metrics
        startUpdating()
        NSLog("MenuBarController: timer started")

        // Perform initial update
        updateMetrics()
        NSLog("MenuBarController: initial metrics update complete")
    }

    func startUpdating() {
        timer = Timer.scheduledTimer(withTimeInterval: updateInterval, repeats: true) { [weak self] _ in
            self?.updateMetrics()
        }
    }

    func updateMetrics() {
        NSLog("MenuBarController: updateMetrics() called")

        // Get metrics on background queue to avoid blocking main thread
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }

            guard let metrics = self.metricsManager.getMetrics() else {
                NSLog("MenuBarController: Failed to get metrics")
                return
            }

            NSLog("MenuBarController: Got metrics - CPU: %.1f%%, Health: %d", metrics.cpu.usage, metrics.healthScore)

            // Update button title with CPU usage on main thread
            DispatchQueue.main.async { [weak self] in
                guard let self = self else { return }
                guard let button = self.statusItem.button else { return }

                button.title = String(format: "🔍 %.0f%%", metrics.cpu.usage)
            }
        }
    }

    func toggleMenu() {
        // Ensure menu operations happen on main thread
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }

            // Get metrics (this might take a moment)
            guard let metrics = self.metricsManager.getMetrics() else {
                // Show loading menu if metrics not available
                let loadingMenu = NSMenu()
                loadingMenu.addItem(NSMenuItem(title: "Loading metrics...", action: nil, keyEquivalent: ""))
                self.statusItem.menu = loadingMenu

                if let button = self.statusItem.button {
                    button.performClick(nil)
                }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                    self?.statusItem.menu = nil
                }
                return
            }

            // Create and show menu with metrics
            self.menu = self.createMenu(with: metrics)
            self.statusItem.menu = self.menu

            // Open the menu
            if let button = self.statusItem.button {
                button.performClick(nil)
            }

            // Remove menu after it's shown so button click works next time
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.statusItem.menu = nil
            }
        }
    }

    func createMenu(with metrics: MetricsSnapshot? = nil) -> NSMenu {
        let menu = NSMenu()

        guard let m = metrics else {
            let item = NSMenuItem(title: "Loading...", action: nil, keyEquivalent: "")
            menu.addItem(item)
            return menu
        }

        // Health Score Header
        let healthItem = NSMenuItem(title: "Health Score: \(m.healthScore)/100 - \(m.healthScoreMsg)", action: nil, keyEquivalent: "")
        healthItem.isEnabled = false
        menu.addItem(healthItem)
        menu.addItem(NSMenuItem.separator())

        // CPU Section
        let cpuHeader = NSMenuItem(title: "CPU", action: nil, keyEquivalent: "")
        cpuHeader.isEnabled = false
        menu.addItem(cpuHeader)
        menu.addItem(createMenuItem(label: "Usage", value: String(format: "%.1f%%", m.cpu.usage)))
        menu.addItem(createMenuItem(label: "Load Average", value: String(format: "%.2f / %.2f / %.2f", m.cpu.load1, m.cpu.load5, m.cpu.load15)))
        menu.addItem(NSMenuItem.separator())

        // Memory Section
        let memHeader = NSMenuItem(title: "Memory", action: nil, keyEquivalent: "")
        memHeader.isEnabled = false
        menu.addItem(memHeader)
        let memUsedGB = Double(m.memory.used) / 1_073_741_824
        let memTotalGB = Double(m.memory.total) / 1_073_741_824
        menu.addItem(createMenuItem(label: "Used", value: String(format: "%.1f GB / %.1f GB (%.1f%%)", memUsedGB, memTotalGB, m.memory.usedPercent)))
        if !m.memory.pressure.isEmpty {
            menu.addItem(createMenuItem(label: "Pressure", value: m.memory.pressure))
        }
        menu.addItem(NSMenuItem.separator())

        // Disk Section
        if !m.disks.isEmpty {
            let diskHeader = NSMenuItem(title: "Disk", action: nil, keyEquivalent: "")
            diskHeader.isEnabled = false
            menu.addItem(diskHeader)
            for disk in m.disks.prefix(3) {
                let usedGB = Double(disk.used) / 1_073_741_824
                let totalGB = Double(disk.total) / 1_073_741_824
                menu.addItem(createMenuItem(label: disk.mount, value: String(format: "%.0f GB / %.0f GB (%.1f%%)", usedGB, totalGB, disk.usedPercent)))
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Network Section
        if let network = m.network, !network.isEmpty {
            let netHeader = NSMenuItem(title: "Network", action: nil, keyEquivalent: "")
            netHeader.isEnabled = false
            menu.addItem(netHeader)
            for net in network.prefix(2) {
                let down = String(format: "↓ %.2f MB/s", net.rxRateMBs)
                let up = String(format: "↑ %.2f MB/s", net.txRateMBs)
                menu.addItem(createMenuItem(label: net.name, value: "\(down) \(up)"))
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Battery Section
        if !m.batteries.isEmpty, let battery = m.batteries.first {
            let batHeader = NSMenuItem(title: "Battery", action: nil, keyEquivalent: "")
            batHeader.isEnabled = false
            menu.addItem(batHeader)
            menu.addItem(createMenuItem(label: "Level", value: String(format: "%.0f%% - %@", battery.percent, battery.status)))
            menu.addItem(createMenuItem(label: "Health", value: "\(battery.health) (\(battery.capacity)%)"))
            if battery.cycleCount > 0 {
                menu.addItem(createMenuItem(label: "Cycles", value: "\(battery.cycleCount)"))
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Thermal Section
        if m.thermal.cpuTemp > 0 {
            let thermalHeader = NSMenuItem(title: "Thermal", action: nil, keyEquivalent: "")
            thermalHeader.isEnabled = false
            menu.addItem(thermalHeader)
            menu.addItem(createMenuItem(label: "CPU Temp", value: String(format: "%.1f°C", m.thermal.cpuTemp)))
            if m.thermal.gpuTemp > 0 {
                menu.addItem(createMenuItem(label: "GPU Temp", value: String(format: "%.1f°C", m.thermal.gpuTemp)))
            }
            if m.thermal.fanSpeed > 0 {
                menu.addItem(createMenuItem(label: "Fan Speed", value: "\(m.thermal.fanSpeed) RPM"))
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Top Processes
        if !m.topProcesses.isEmpty {
            let procHeader = NSMenuItem(title: "Top Processes", action: nil, keyEquivalent: "")
            procHeader.isEnabled = false
            menu.addItem(procHeader)
            for proc in m.topProcesses.prefix(3) {
                menu.addItem(createMenuItem(label: proc.name, value: String(format: "%.1f%%", proc.cpu)))
            }
            menu.addItem(NSMenuItem.separator())
        }

        // Quick Actions
        let actionsHeader = NSMenuItem(title: "Quick Actions", action: nil, keyEquivalent: "")
        actionsHeader.isEnabled = false
        menu.addItem(actionsHeader)

        let cleanItem = NSMenuItem(title: "Run Cleanup...", action: #selector(runClean), keyEquivalent: "")
        cleanItem.target = self
        menu.addItem(cleanItem)

        let optimizeItem = NSMenuItem(title: "Optimize System...", action: #selector(runOptimize), keyEquivalent: "")
        optimizeItem.target = self
        menu.addItem(optimizeItem)

        let analyzeItem = NSMenuItem(title: "Analyze Disk...", action: #selector(runAnalyze), keyEquivalent: "")
        analyzeItem.target = self
        menu.addItem(analyzeItem)

        menu.addItem(NSMenuItem.separator())

        // Preferences and Quit
        let prefsItem = NSMenuItem(title: "Preferences...", action: #selector(openPreferences), keyEquivalent: ",")
        prefsItem.target = self
        menu.addItem(prefsItem)

        let quitItem = NSMenuItem(title: "Quit Mole Menu Bar", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        return menu
    }

    private func createMenuItem(label: String, value: String) -> NSMenuItem {
        let item = NSMenuItem(title: "\(label): \(value)", action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    @objc func runClean() {
        QuickActionsRunner.shared.runCommand("mo clean")
    }

    @objc func runOptimize() {
        QuickActionsRunner.shared.runCommand("mo optimize")
    }

    @objc func runAnalyze() {
        QuickActionsRunner.shared.runCommand("mo analyze")
    }

    @objc func openPreferences() {
        let prefsWindow = PreferencesWindow()
        prefsWindow.show()
    }

    @objc func quit() {
        NSApp.terminate(nil)
    }

    func cleanup() {
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.timer?.invalidate()
            self.timer = nil
            self.metricsManager.cleanup()
        }
    }
}
