//
//  MenuBarController.swift
//  Tonic
//
//  Menu bar controller with live system widgets
// Shows CPU, memory, storage, and network activity in menu bar
//

import SwiftUI
import AppKit
import IOKit.ps

// MARK: - Menu Bar Widget Configuration

struct MenuBarWidgetConfiguration: Sendable {
    var showCPU: Bool = true
    var showMemory: Bool = true
    var showStorage: Bool = true
    var showNetwork: Bool = true
    var compactMode: Bool = false
    var updateInterval: TimeInterval = 2.0
    var clickToExpand: Bool = true
}

// MARK: - Menu Bar Widget Data

struct MenuBarWidgetData: Sendable, Equatable {
    let cpuUsage: Double
    let cpuHistory: [Double]
    let memoryUsage: Double
    let memoryPressure: MemoryPressure
    let storageUsed: Double
    let storageTotal: Double
    let networkActivity: NetworkActivity
    let timestamp: Date

    var storagePercentage: Double {
        guard storageTotal > 0 else { return 0 }
        return storageUsed / storageTotal * 100
    }

    static func == (lhs: MenuBarWidgetData, rhs: MenuBarWidgetData) -> Bool {
        lhs.timestamp == rhs.timestamp
    }
}

struct NetworkActivity: Sendable, Equatable {
    let bytesIn: UInt64
    let bytesOut: UInt64
    let isActive: Bool

    var formattedBytesIn: String {
        formatBytes(bytesIn)
    }

    var formattedBytesOut: String {
        formatBytes(bytesOut)
    }

    private func formatBytes(_ bytes: UInt64) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.1f KB", kb)
        }
        let mb = kb / 1024
        if mb < 1024 {
            return String(format: "%.1f MB", mb)
        }
        let gb = mb / 1024
        return String(format: "%.2f GB", gb)
    }
}

// MARK: - Widget Color Helper

enum WidgetColor {
    static func colorFor(value: Double, threshold: (low: Double, medium: Double, high: Double)) -> Color {
        if value < threshold.low {
            return DesignTokens.Colors.progressLow
        } else if value < threshold.medium {
            return DesignTokens.Colors.progressMedium
        } else {
            return DesignTokens.Colors.progressHigh
        }
    }
}

// MARK: - Menu Bar Manager

@MainActor
class MenuBarController: ObservableObject {
    private var statusItem: NSStatusItem?
    private var statusBarMenu: NSMenu?

    // System stats for menu bar display
    @Published var cpuUsage: Double = 0
    @Published var memoryUsage: Double = 0
    @Published var diskUsage: Double = 0

    // Widget data
    @Published var widgetData: MenuBarWidgetData?
    @Published var configuration: MenuBarWidgetConfiguration = MenuBarWidgetConfiguration()
    @Published var isExpanded = false

    private var systemMonitor: SystemMonitor?
    private var updateTimer: Timer?

    // CPU history (last 30 data points for mini-graph)
    private var cpuHistory: [Double] = []

    // Window management
    weak var mainWindow: NSWindow?

    init() {
        setupStatusBar()
        setupSystemMonitoring()
    }

    deinit {
        statusItem = nil
        updateTimer?.invalidate()
    }

    // MARK: - Setup

    private func setupStatusBar() {
        // Create status item in menu bar
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            // Create a custom view for the status bar
            let imageView = NSImageView(frame: NSRect(x: 0, y: 0, width: 20, height: 20))
            imageView.image = createMenuBarIcon()
            button.image = createMenuBarIcon()
            button.image?.isTemplate = true
            button.action = #selector(statusBarButtonClicked)
            button.target = self
        }

        setupMenu()
    }

    private func setupMenu() {
        let menu = NSMenu()

        // App header
        let headerItem = NSMenuItem()
        headerItem.view = createMenuHeaderView()
        menu.addItem(headerItem)
        menu.addItem(NSMenuItem.separator())

        // Mini dashboard stats
        menu.addItem(createStatMenuItem(title: "CPU Usage", value: "\(Int(cpuUsage))%", icon: "cpu"))
        menu.addItem(createStatMenuItem(title: "Memory", value: "\(Int(memoryUsage))%", icon: "memorychip"))
        menu.addItem(createStatMenuItem(title: "Storage", value: "\(Int(diskUsage))%", icon: "internaldrive"))
        menu.addItem(NSMenuItem.separator())

        // Quick actions
        let quickScanItem = NSMenuItem(
            title: "Quick Scan",
            action: #selector(quickScanClicked),
            keyEquivalent: "s"
        )
        quickScanItem.target = self
        quickScanItem.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        menu.addItem(quickScanItem)

        let quickCleanItem = NSMenuItem(
            title: "Quick Clean",
            action: #selector(quickCleanClicked),
            keyEquivalent: "k"
        )
        quickCleanItem.target = self
        quickCleanItem.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)
        menu.addItem(quickCleanItem)

        menu.addItem(NSMenuItem.separator())

        // Window toggle
        let showWindowItem = NSMenuItem(
            title: "Show Tonic",
            action: #selector(toggleMainWindow),
            keyEquivalent: "t"
        )
        showWindowItem.target = self
        showWindowItem.image = NSImage(systemSymbolName: "macwindow", accessibilityDescription: nil)
        menu.addItem(showWindowItem)

        menu.addItem(NSMenuItem.separator())

        // Settings
        let settingsItem = NSMenuItem(
            title: "Settings...",
            action: #selector(showSettings),
            keyEquivalent: ","
        )
        settingsItem.target = self
        settingsItem.image = NSImage(systemSymbolName: "gear", accessibilityDescription: nil)
        menu.addItem(settingsItem)

        menu.addItem(NSMenuItem.separator())

        // Quit
        let quitItem = NSMenuItem(
            title: "Quit Tonic",
            action: #selector(quitTonic),
            keyEquivalent: "q"
        )
        quitItem.target = self
        quitItem.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        menu.addItem(quitItem)

        statusBarMenu = menu
        statusItem?.menu = menu
    }

    private func createMenuHeaderView() -> NSView {
        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))

        let titleLabel = NSTextField(labelWithString: "Tonic")
        titleLabel.font = NSFont.systemFont(ofSize: 14, weight: .bold)
        titleLabel.frame = NSRect(x: 50, y: 20, width: 100, height: 20)
        titleLabel.textColor = NSColor.labelColor

        let iconView = NSImageView(frame: NSRect(x: 15, y: 10, width: 24, height: 24))
        iconView.image = createMenuBarIcon()
        iconView.image?.isTemplate = false

        containerView.addSubview(iconView)
        containerView.addSubview(titleLabel)

        return containerView
    }

    private func createStatMenuItem(title: String, value: String, icon: String) -> NSMenuItem {
        let item = NSMenuItem()

        let containerView = NSView(frame: NSRect(x: 0, y: 0, width: 180, height: 28))

        let iconView = NSImageView(frame: NSRect(x: 15, y: 4, width: 16, height: 16))
        if let iconImage = NSImage(systemSymbolName: icon, accessibilityDescription: nil) {
            iconView.image = iconImage
            iconView.image?.isTemplate = true
        }

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = NSFont.systemFont(ofSize: 12)
        titleLabel.frame = NSRect(x: 40, y: 8, width: 70, height: 16)
        titleLabel.textColor = NSColor.secondaryLabelColor

        let valueLabel = NSTextField(labelWithString: value)
        valueLabel.font = NSFont.systemFont(ofSize: 12, weight: .semibold)
        valueLabel.frame = NSRect(x: 130, y: 8, width: 40, height: 16)
        valueLabel.alignment = .right
        valueLabel.textColor = NSColor.labelColor

        containerView.addSubview(iconView)
        containerView.addSubview(titleLabel)
        containerView.addSubview(valueLabel)

        // Store references to update later
        item.view = containerView
        item.representedObject = ["title": title, "valueLabel": valueLabel]

        return item
    }

    private func createMenuBarIcon() -> NSImage {
        let config = NSImage.SymbolConfiguration(pointSize: 16, weight: .medium)
        let image = NSImage(systemSymbolName: "drop.fill", accessibilityDescription: "Tonic")
        image?.isTemplate = true
        return image ?? NSImage()
    }

    private func setupSystemMonitoring() {
        systemMonitor = SystemMonitor()
        systemMonitor?.startMonitoring()

        // Update menu stats periodically
        updateTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateMenuStats()
            }
        }

        updateMenuStats()
    }

    private func updateMenuStats() {
        guard let status = systemMonitor?.currentStatus else { return }

        cpuUsage = status.cpuUsage
        memoryUsage = status.memoryUsagePercentage

        // Update CPU history
        cpuHistory.append(status.cpuUsage)
        if cpuHistory.count > 30 {
            cpuHistory.removeFirst()
        }

        if let bootVolume = status.diskUsage.first(where: { $0.isBootVolume }) {
            diskUsage = bootVolume.usagePercentage
        }

        // Calculate network activity
        var isActive = false
        if status.networkBytesIn > 0 || status.networkBytesOut > 0 {
            isActive = true
        }

        // Update widget data
        widgetData = MenuBarWidgetData(
            cpuUsage: status.cpuUsage,
            cpuHistory: cpuHistory,
            memoryUsage: status.memoryUsagePercentage,
            memoryPressure: status.memoryPressure,
            storageUsed: Double(status.diskUsage.first?.usedBytes ?? 0),
            storageTotal: Double(status.diskUsage.first?.totalBytes ?? 1),
            networkActivity: NetworkActivity(
                bytesIn: status.networkBytesIn,
                bytesOut: status.networkBytesOut,
                isActive: isActive
            ),
            timestamp: Date()
        )

        // Update status item button based on configuration
        updateStatusBarButton()

        // Update menu items
        updateMenuStatValues()
    }

    private func updateStatusBarButton() {
        guard let button = statusItem?.button else { return }

        if configuration.compactMode {
            // Compact mode - show icons only
            button.image = createCompactMenuBarIcon()
            button.attributedTitle = NSAttributedString()
        } else {
            // Full mode - show text
            var parts: [String] = []

            if configuration.showCPU {
                parts.append("CPU \(Int(cpuUsage))%")
            }
            if configuration.showMemory {
                parts.append("M \(Int(memoryUsage))%")
            }
            if configuration.showStorage {
                parts.append("D \(Int(diskUsage))%")
            }
            if configuration.showNetwork, let data = widgetData, data.networkActivity.isActive {
                parts.append("NET")
            }

            let string = parts.joined(separator: " | ")
            let attributedTitle = NSAttributedString(
                string: string,
                attributes: [
                    .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.labelColor
                ]
            )
            button.attributedTitle = attributedTitle
            button.image = nil
        }
    }

    private func createCompactMenuBarIcon() -> NSImage {
        let size = NSSize(width: 40, height: 22)
        let image = NSImage(size: size)

        image.lockFocus()

        let ctx = NSGraphicsContext.current?.cgContext
        ctx?.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx?.fill(CGRect(origin: .zero, size: size))

        // Draw simple indicators
        if let data = widgetData {
            // CPU color
            let cpuColor = NSColor(
                WidgetColor.colorFor(value: data.cpuUsage, threshold: (50, 80, 100))
            )
            ctx?.setFillColor(cpuColor.cgColor)
            ctx?.fillEllipse(in: CGRect(x: 4, y: 8, width: 6, height: 6))

            // Memory color
            let memColor = NSColor(
                WidgetColor.colorFor(value: data.memoryUsage, threshold: (50, 75, 90))
            )
            ctx?.setFillColor(memColor.cgColor)
            ctx?.fillEllipse(in: CGRect(x: 14, y: 8, width: 6, height: 6))

            // Network indicator
            if data.networkActivity.isActive {
                ctx?.setFillColor(NSColor.systemGreen.cgColor)
                ctx?.fillEllipse(in: CGRect(x: 24, y: 8, width: 6, height: 6))
            }
        }

        image.unlockFocus()
        return image
    }

    // MARK: - Status Bar Button Action

    @objc private func statusBarButtonClicked() {
        guard configuration.clickToExpand else { return }

        isExpanded.toggle()

        if isExpanded {
            showExpandedMenu()
        }
    }

    private func showExpandedMenu() {
        guard let button = statusItem?.button else { return }

        let menu = NSMenu()

        // Add widget detail items
        if let data = widgetData {
            menu.addItem(cpuMenuItem(data: data))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(memoryMenuItem(data: data))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(storageMenuItem(data: data))
            menu.addItem(NSMenuItem.separator())
            menu.addItem(networkMenuItem(data: data))
        }

        menu.addItem(NSMenuItem.separator())

        // Add app actions
        let showApp = NSMenuItem(
            title: "Open Tonic",
            action: #selector(toggleMainWindow),
            keyEquivalent: "o"
        )
        showApp.target = self
        menu.addItem(showApp)

        let quitItem = NSMenuItem(
            title: "Quit Tonic",
            action: #selector(quitTonic),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem?.menu = menu
        statusItem?.button?.performClick(nil)
        statusItem?.menu = nil
    }

    // MARK: - Widget Menu Item Builders

    private func cpuMenuItem(data: MenuBarWidgetData) -> NSMenuItem {
        let item = NSMenuItem()

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 60))

        let percentageText = NSTextField(labelWithString: "\(Int(data.cpuUsage))%")
        percentageText.frame = NSRect(x: 10, y: 35, width: 50, height: 20)
        percentageText.font = NSFont.systemFont(ofSize: 18, weight: .bold)
        view.addSubview(percentageText)

        let label = NSTextField(labelWithString: "CPU Usage")
        label.frame = NSRect(x: 65, y: 40, width: 80, height: 14)
        label.font = NSFont.systemFont(ofSize: 11)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)

        // Mini graph
        let graphView = CPUMiniGraphView(frame: NSRect(x: 10, y: 5, width: 180, height: 25))
        graphView.dataPoints = data.cpuHistory
        view.addSubview(graphView)

        item.view = view
        return item
    }

    private func memoryMenuItem(data: MenuBarWidgetData) -> NSMenuItem {
        let item = NSMenuItem()

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))

        let percentageText = NSTextField(labelWithString: "\(Int(data.memoryUsage))%")
        percentageText.frame = NSRect(x: 10, y: 25, width: 50, height: 20)
        percentageText.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        view.addSubview(percentageText)

        let gauge = MemoryGaugeView(frame: NSRect(x: 65, y: 15, width: 125, height: 20))
        gauge.usage = data.memoryUsage
        gauge.pressure = data.memoryPressure
        view.addSubview(gauge)

        let label = NSTextField(labelWithString: "Memory")
        label.frame = NSRect(x: 10, y: 5, width: 180, height: 14)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)

        item.view = view
        return item
    }

    private func storageMenuItem(data: MenuBarWidgetData) -> NSMenuItem {
        let item = NSMenuItem()

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))

        let percentageText = NSTextField(labelWithString: "\(Int(data.storagePercentage))%")
        percentageText.frame = NSRect(x: 10, y: 25, width: 50, height: 20)
        percentageText.font = NSFont.systemFont(ofSize: 16, weight: .semibold)
        view.addSubview(percentageText)

        let bar = StorageProgressBarView(frame: NSRect(x: 65, y: 20, width: 125, height: 16))
        bar.percentage = data.storagePercentage
        view.addSubview(bar)

        let label = NSTextField(labelWithString: "Storage")
        label.frame = NSRect(x: 10, y: 5, width: 180, height: 14)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)

        item.view = view
        return item
    }

    private func networkMenuItem(data: MenuBarWidgetData) -> NSMenuItem {
        let item = NSMenuItem()

        let view = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 40))

        let indicator = NetworkActivityIndicator(frame: NSRect(x: 10, y: 10, width: 20, height: 20))
        indicator.isActive = data.networkActivity.isActive
        view.addSubview(indicator)

        let downText = NSTextField(labelWithString: "↓ \(data.networkActivity.formattedBytesIn)")
        downText.frame = NSRect(x: 40, y: 20, width: 75, height: 16)
        downText.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(downText)

        let upText = NSTextField(labelWithString: "↑ \(data.networkActivity.formattedBytesOut)")
        upText.frame = NSRect(x: 120, y: 20, width: 75, height: 16)
        upText.font = NSFont.systemFont(ofSize: 11)
        view.addSubview(upText)

        let label = NSTextField(labelWithString: "Network")
        label.frame = NSRect(x: 40, y: 2, width: 80, height: 14)
        label.font = NSFont.systemFont(ofSize: 10)
        label.textColor = .secondaryLabelColor
        view.addSubview(label)

        item.view = view
        return item
    }

    // MARK: - Configuration

    func setConfiguration(_ config: MenuBarWidgetConfiguration) {
        configuration = config
        updateStatusBarButton()
    }

    private func updateMenuStatValues() {
        guard let menu = statusBarMenu else { return }

        for item in menu.items {
            if let representedObject = item.representedObject as? [String: Any],
               let title = representedObject["title"] as? String,
               let valueLabel = representedObject["valueLabel"] as? NSTextField,
               let containerView = item.view {

                // Find and update the value label
                containerView.subviews.forEach { subview in
                    if let textField = subview as? NSTextField,
                       textField.alignment == .right,
                       textField.frame.origin.x > 100 {
                        switch title {
                        case "CPU Usage":
                            textField.stringValue = "\(Int(cpuUsage))%"
                        case "Memory":
                            textField.stringValue = "\(Int(memoryUsage))%"
                        case "Storage":
                            textField.stringValue = "\(Int(diskUsage))%"
                        default:
                            break
                        }
                    }
                }
            }
        }
    }

    // MARK: - Actions

    @objc private func quickScanClicked() {
        // Trigger quick scan
        NotificationCenter.default.post(name: .quickScanRequested, object: nil)

        // Show window
        showMainWindow()
    }

    @objc private func quickCleanClicked() {
        // Trigger quick clean
        NotificationCenter.default.post(name: .quickCleanRequested, object: nil)

        // Show notification
        showNotification(title: "Quick Clean", message: "Cleaned temporary files and cache")
    }

    @objc private func toggleMainWindow() {
        if let window = mainWindow {
            if window.isVisible {
                window.orderOut(nil)
            } else {
                showMainWindow()
            }
        } else {
            showMainWindow()
        }
    }

    @objc private func showMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        if let window = mainWindow {
            window.makeKeyAndOrderFront(nil)
        } else if let window = NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            mainWindow = window
        }
    }

    @objc private func showSettings() {
        NotificationCenter.default.post(name: .showSettingsRequested, object: nil)
        showMainWindow()
    }

    @objc private func quitTonic() {
        NSApplication.shared.terminate(nil)
    }

    private func showNotification(title: String, message: String) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = message
        notification.soundName = NSUserNotificationDefaultSoundName
        NSUserNotificationCenter.default.deliver(notification)
    }

    // MARK: - Public Methods

    func setMainWindow(_ window: NSWindow) {
        self.mainWindow = window
    }

    func show() {
        statusItem?.isVisible = true
    }

    func hide() {
        statusItem?.isVisible = false
    }
}

// MARK: - Notification Names

extension Notification.Name {
    static let quickScanRequested = Notification.Name("quickScanRequested")
    static let quickCleanRequested = Notification.Name("quickCleanRequested")
    static let showSettingsRequested = Notification.Name("showSettingsRequested")
}

// MARK: - Menu Bar Popup View (SwiftUI)

struct MenuBarPopupView: View {
    @StateObject private var menuBarManager = MenuBarController()
    @StateObject private var systemMonitor = SystemMonitor()

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Image(systemName: "drop.fill")
                    .foregroundColor(DesignTokens.Colors.accent)
                    .font(.title2)

                Text("Tonic")
                    .font(DesignTokens.Typography.headlineMedium)
                    .foregroundColor(DesignTokens.Colors.text)

                Spacer()
            }
            .padding(DesignTokens.Spacing.md)
            .background(DesignTokens.Colors.surfaceElevated)

            Divider()

            // Mini Dashboard Stats
            VStack(spacing: DesignTokens.Spacing.sm) {
                if let status = systemMonitor.currentStatus {
                    MiniStatRow(
                        icon: "cpu.fill",
                        title: "CPU Usage",
                        value: "\(Int(status.cpuUsage))%",
                        color: cpuColor(status.cpuUsage)
                    )

                    MiniStatRow(
                        icon: "memorychip.fill",
                        title: "Memory",
                        value: "\(Int(status.memoryUsagePercentage))%",
                        color: status.memoryPressure.color
                    )

                    if let bootVolume = status.diskUsage.first(where: { $0.isBootVolume }) {
                        MiniStatRow(
                            icon: "internaldrive.fill",
                            title: "Storage",
                            value: "\(Int(bootVolume.usagePercentage))%",
                            color: storageColor(bootVolume.usagePercentage)
                        )
                    }
                }
            }
            .padding(DesignTokens.Spacing.md)

            Divider()

            // Quick Actions
            VStack(spacing: 0) {
                MenuBarButton(
                    title: "Quick Scan",
                    icon: "magnifyingglass",
                    action: {
                        NotificationCenter.default.post(name: .quickScanRequested, object: nil)
                    }
                )

                MenuBarButton(
                    title: "Quick Clean",
                    icon: "sparkles",
                    action: {
                        NotificationCenter.default.post(name: .quickCleanRequested, object: nil)
                    }
                )

                Divider()

                MenuBarButton(
                    title: "Open Tonic",
                    icon: "macwindow",
                    action: {
                        NSApp.activate(ignoringOtherApps: true)
                    }
                )

                MenuBarButton(
                    title: "Settings...",
                    icon: "gear",
                    action: {
                        NotificationCenter.default.post(name: .showSettingsRequested, object: nil)
                    }
                )

                Divider()

                MenuBarButton(
                    title: "Quit Tonic",
                    icon: "power",
                    action: {
                        NSApplication.shared.terminate(nil)
                    }
                )
            }
        }
        .frame(width: 220)
        .background(DesignTokens.Colors.surface)
    }

    private func cpuColor(_ usage: Double) -> Color {
        switch usage {
        case 0..<50: return DesignTokens.Colors.success
        case 50..<80: return DesignTokens.Colors.warning
        default: return DesignTokens.Colors.error
        }
    }

    private func storageColor(_ usage: Double) -> Color {
        switch usage {
        case 0..<70: return DesignTokens.Colors.success
        case 70..<90: return DesignTokens.Colors.warning
        default: return DesignTokens.Colors.error
        }
    }
}

// MARK: - Menu Bar Button Component

struct MenuBarButton: View {
    let title: String
    let icon: String
    let action: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.Spacing.sm) {
                Image(systemName: icon)
                    .foregroundColor(DesignTokens.Colors.textSecondary)
                    .frame(width: 20)

                Text(title)
                    .font(DesignTokens.Typography.bodyMedium)
                    .foregroundColor(DesignTokens.Colors.text)

                Spacer()
            }
            .padding(.horizontal, DesignTokens.Spacing.md)
            .padding(.vertical, DesignTokens.Spacing.sm)
            .background(isHovered ? DesignTokens.Colors.surfaceHovered : Color.clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(DesignTokens.Animation.fast) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Mini Stat Row Component

struct MiniStatRow: View {
    let icon: String
    let title: String
    let value: String
    let color: Color

    var body: some View {
        HStack {
            Image(systemName: icon)
                .foregroundColor(color)
                .frame(width: 20)

            Text(title)
                .font(DesignTokens.Typography.bodySmall)
                .foregroundColor(DesignTokens.Colors.textSecondary)

            Spacer()

            Text(value)
                .font(DesignTokens.Typography.bodySmall)
                .fontWeight(.semibold)
                .foregroundColor(DesignTokens.Colors.text)
        }
    }
}

// MARK: - Menu Bar Popover Controller

class MenuBarPopoverController: NSViewController {
    private var popover: NSPopover?
    private var statusItem: NSStatusItem?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 300))
    }

    func setupPopover() {
        // Create status item
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)

        if let button = statusItem?.button {
            button.action = #selector(togglePopover)
            button.target = self
        }

        // Create popover
        popover = NSPopover()
        popover?.contentSize = NSSize(width: 220, height: 350)
        popover?.behavior = .transient
        popover?.contentViewController = NSHostingController(rootView: MenuBarPopupView())
    }

    @objc private func togglePopover() {
        guard let button = statusItem?.button else { return }

        if let popover = popover {
            if popover.isShown {
                popover.performClose(nil)
            } else {
                popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            }
        }
    }

    deinit {
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
        }
    }
}

// MARK: - Preview

#Preview {
    MenuBarPopupView()
        .frame(width: 220, height: 400)
}

// MARK: - Widget View Classes

// CPU Mini Graph View
class CPUMiniGraphView: NSView {
    var dataPoints: [Double] = [] {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext,
              !dataPoints.isEmpty else { return }

        let bounds = self.bounds
        let width = bounds.width
        let height = bounds.height

        ctx.clear(bounds)

        ctx.setStrokeColor(NSColor.systemGreen.cgColor)
        ctx.setLineWidth(1.5)

        let step = width / CGFloat(max(dataPoints.count - 1, 1))

        ctx.move(to: CGPoint(x: 0, y: height))

        for (index, point) in dataPoints.enumerated() {
            let x = CGFloat(index) * step
            let y = height - (CGFloat(point) / 100.0) * height
            ctx.addLine(to: CGPoint(x: x, y: y))
        }

        ctx.strokePath()

        if let firstPoint = dataPoints.first {
            ctx.move(to: CGPoint(x: 0, y: height))
            ctx.addLine(to: CGPoint(x: 0, y: height - (CGFloat(firstPoint) / 100.0) * height))

            for (index, point) in dataPoints.enumerated() {
                let x = CGFloat(index) * step
                let y = height - (CGFloat(point) / 100.0) * height
                ctx.addLine(to: CGPoint(x: x, y: y))
            }

            if let lastPoint = dataPoints.last {
                let lastX = CGFloat(dataPoints.count - 1) * step
                ctx.addLine(to: CGPoint(x: lastX, y: height))
            }

            ctx.closePath()

            ctx.saveGState()
            ctx.clip()

            let gradient = NSGradient(colors: [
                NSColor.systemGreen.withAlphaComponent(0.3),
                NSColor.systemGreen.withAlphaComponent(0.05)
            ])
            gradient?.draw(in: bounds, angle: 90)

            ctx.restoreGState()
        }
    }
}

// Memory Gauge View
class MemoryGaugeView: NSView {
    var usage: Double = 0
    var pressure: MemoryPressure = .normal {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let width = bounds.width
        let height = bounds.height

        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        let fillWidth = width * (usage / 100.0)
        let fillColor = NSColor(pressure.color)

        ctx.setFillColor(fillColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: fillWidth, height: height))

        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(bounds)
    }
}

// Storage Progress Bar View
class StorageProgressBarView: NSView {
    var percentage: Double = 0 {
        didSet { needsDisplay = true }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let width = bounds.width
        let height = bounds.height

        ctx.setFillColor(NSColor.controlBackgroundColor.cgColor)
        ctx.fill(bounds)

        let fillColor: NSColor
        switch percentage {
        case 0..<70:
            fillColor = NSColor.systemGreen
        case 70..<85:
            fillColor = NSColor.systemOrange
        default:
            fillColor = NSColor.systemRed
        }

        let fillWidth = width * (percentage / 100.0)
        ctx.setFillColor(fillColor.cgColor)
        ctx.fill(CGRect(x: 0, y: 0, width: fillWidth, height: height))

        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(0.5)
        ctx.stroke(bounds)
    }
}

// Network Activity Indicator
class NetworkActivityIndicator: NSView {
    var isActive: Bool = false {
        didSet { needsDisplay = true }
    }

    private var animationPhase = 0
    private var animationTimer: Timer?

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        guard let ctx = NSGraphicsContext.current?.cgContext else { return }

        let bounds = self.bounds
        let center = CGPoint(x: bounds.midX, y: bounds.midY)
        let radius = min(bounds.width, bounds.height) / 2 - 2

        ctx.setStrokeColor(NSColor.separatorColor.cgColor)
        ctx.setLineWidth(1.5)
        ctx.addEllipse(in: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
        ctx.strokePath()

        if isActive {
            ctx.setStrokeColor(NSColor.systemBlue.cgColor)
            ctx.setLineWidth(2)

            let startAngle = Double(animationPhase) * .pi / 180
            let endAngle = startAngle + .pi * 1.5

            ctx.addArc(center: center, radius: radius, startAngle: startAngle, endAngle: endAngle, clockwise: false)
            ctx.strokePath()

            startAnimation()
        } else {
            ctx.setFillColor(NSColor.systemGray.cgColor)
            ctx.addEllipse(in: CGRect(
                x: center.x - 3,
                y: center.y - 3,
                width: 6,
                height: 6
            ))
            ctx.fillPath()

            stopAnimation()
        }
    }

    private func startAnimation() {
        guard animationTimer == nil else { return }

        animationTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            self?.animationPhase = (self?.animationPhase ?? 0 + 15) % 360
            self?.needsDisplay = true
        }
    }

    private func stopAnimation() {
        animationTimer?.invalidate()
        animationTimer = nil
    }

    deinit {
        stopAnimation()
    }
}

// MARK: - SwiftUI Widget Views

struct MenuBarWidgetsView: View {
    @State private var controller = MenuBarController()

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.md) {
            HStack {
                Text("Menu Bar Widgets")
                    .font(DesignTokens.Typography.headlineMedium)

                Spacer()

                HStack(spacing: DesignTokens.Spacing.md) {
                    Toggle("CPU", isOn: Binding(
                        get: { controller.configuration.showCPU },
                        set: { _ in updateConfiguration() }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Memory", isOn: Binding(
                        get: { controller.configuration.showMemory },
                        set: { _ in updateConfiguration() }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Storage", isOn: Binding(
                        get: { controller.configuration.showStorage },
                        set: { _ in updateConfiguration() }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Network", isOn: Binding(
                        get: { controller.configuration.showNetwork },
                        set: { _ in updateConfiguration() }
                    ))
                    .toggleStyle(.switch)

                    Toggle("Compact", isOn: Binding(
                        get: { controller.configuration.compactMode },
                        set: { _ in updateConfiguration() }
                    ))
                    .toggleStyle(.switch)
                }
                .font(DesignTokens.Typography.captionMedium)
            }

            if let data = controller.widgetData {
                HStack(spacing: DesignTokens.Spacing.lg) {
                    CPUWidgetPreview(data: data)
                    MemoryWidgetPreview(data: data)
                    StorageWidgetPreview(data: data)
                    NetworkWidgetPreview(data: data)
                }
            } else {
                Text("Loading widget data...")
                    .foregroundColor(DesignTokens.Colors.textSecondary)
            }
        }
        .padding()
    }

    private func updateConfiguration() {
        controller.setConfiguration(controller.configuration)
    }
}

struct CPUWidgetPreview: View {
    let data: MenuBarWidgetData

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text("\(Int(data.cpuUsage))%")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(colorForUsage(data.cpuUsage))

            Text("CPU")
                .font(DesignTokens.Typography.captionMedium)
                .foregroundColor(DesignTokens.Colors.textSecondary)

            GeometryReader { geometry in
                ZStack {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(DesignTokens.Colors.surface)
                        .frame(height: 30)

                    let points = data.cpuHistory
                    if !points.isEmpty {
                        Path { path in
                            let width = geometry.size.width
                            let height: CGFloat = 30
                            let step = width / CGFloat(max(points.count - 1, 1))

                            for (index, point) in points.enumerated() {
                                let x = CGFloat(index) * step
                                let y = height - (CGFloat(point) / 100.0) * height

                                if index == 0 {
                                    path.move(to: CGPoint(x: x, y: y))
                                } else {
                                    path.addLine(to: CGPoint(x: x, y: y))
                                }
                            }
                        }
                        .stroke(colorForUsage(data.cpuUsage), lineWidth: 2)
                    }
                }
            }
            .frame(height: 30)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }

    private func colorForUsage(_ usage: Double) -> Color {
        WidgetColor.colorFor(value: usage, threshold: (50, 80, 100))
    }
}

struct MemoryWidgetPreview: View {
    let data: MenuBarWidgetData

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text("\(Int(data.memoryUsage))%")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(data.memoryPressure.color)

            Text("Memory")
                .font(DesignTokens.Typography.captionMedium)
                .foregroundColor(DesignTokens.Colors.textSecondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DesignTokens.Colors.surface)
                        .frame(height: 8)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(data.memoryPressure.color)
                        .frame(width: max(0, geometry.size.width * (data.memoryUsage / 100)), height: 8)
                }
            }
            .frame(height: 8)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }
}

struct StorageWidgetPreview: View {
    let data: MenuBarWidgetData

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            Text("\(Int(data.storagePercentage))%")
                .font(.system(size: 24, weight: .bold, design: .monospaced))
                .foregroundColor(colorForStorage(data.storagePercentage))

            Text("Storage")
                .font(DesignTokens.Typography.captionMedium)
                .foregroundColor(DesignTokens.Colors.textSecondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 4)
                        .fill(DesignTokens.Colors.surface)
                        .frame(height: 12)

                    RoundedRectangle(cornerRadius: 4)
                        .fill(colorForStorage(data.storagePercentage))
                        .frame(width: max(0, geometry.size.width * (data.storagePercentage / 100)), height: 12)
                }
            }
            .frame(height: 12)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }

    private func colorForStorage(_ percentage: Double) -> Color {
        switch percentage {
        case 0..<70: return DesignTokens.Colors.progressLow
        case 70..<85: return DesignTokens.Colors.progressMedium
        default: return DesignTokens.Colors.progressHigh
        }
    }
}

struct NetworkWidgetPreview: View {
    let data: MenuBarWidgetData

    var body: some View {
        VStack(spacing: DesignTokens.Spacing.xs) {
            ZStack {
                Circle()
                    .stroke(DesignTokens.Colors.border, lineWidth: 2)
                    .frame(width: 40, height: 40)

                if data.networkActivity.isActive {
                    Circle()
                        .fill(DesignTokens.Colors.accent)
                        .frame(width: 16, height: 16)
                        .blur(radius: 4)
                } else {
                    Circle()
                        .fill(DesignTokens.Colors.textSecondary)
                        .frame(width: 8, height: 8)
                }
            }

            Text("Network")
                .font(DesignTokens.Typography.captionMedium)
                .foregroundColor(DesignTokens.Colors.textSecondary)

            HStack(spacing: DesignTokens.Spacing.sm) {
                Label(data.networkActivity.formattedBytesIn, systemImage: "arrow.down")
                Label(data.networkActivity.formattedBytesOut, systemImage: "arrow.up")
            }
            .font(DesignTokens.Typography.captionSmall)
            .foregroundColor(DesignTokens.Colors.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding()
        .background(DesignTokens.Colors.surface)
        .cornerRadius(DesignTokens.CornerRadius.large)
    }
}

#Preview("Widgets") {
    MenuBarWidgetsView()
        .frame(width: 600, height: 300)
}
