//
//  WidgetStatusItem.swift
//  Tonic
//
//  Base NSStatusItem wrapper for menu bar widgets
//  Task ID: fn-2.3
//

import AppKit
import SwiftUI
import os

// MARK: - Widget Status Item

/// Base class for managing a single widget's NSStatusItem
/// Each widget type creates its own instance to manage its menu bar presence
@MainActor
public class WidgetStatusItem: ObservableObject {

    private let logger = Logger(subsystem: "com.tonic.app", category: "WidgetStatusItem")

    // MARK: - Properties

    /// The NSStatusItem for this widget
    public private(set) var statusItem: NSStatusItem?

    /// The widget type this item represents
    public let widgetType: WidgetType

    /// Configuration for this widget
    @Published public var configuration: WidgetConfiguration

    /// Whether this widget is visible in the menu bar
    @Published public var isVisible: Bool = false

    /// Popover for showing detail view
    private var popover: NSPopover?

    /// Hosting controller for the compact view (type-erased)
    private var anyHostingController: NSHostingController<AnyView>?

    /// Timer for updating the view
    private var updateTimer: Timer?

    /// Data manager reference
    private var dataManager: WidgetDataManager {
        WidgetDataManager.shared
    }

    // MARK: - Initialization

    public init(widgetType: WidgetType, configuration: WidgetConfiguration) {
        self.widgetType = widgetType
        self.configuration = configuration

        logger.info("🔵 Initializing widget: \(widgetType.rawValue), enabled: \(configuration.isEnabled)")
        setupStatusItem()
        setupPopover()
        startUpdateTimer()
    }

    deinit {
        // Clean up status item on main thread
        MainActor.assumeIsolated {
            if let statusItem = self.statusItem {
                NSStatusBar.system.removeStatusItem(statusItem)
            }
        }
        updateTimer?.invalidate()
    }

    // MARK: - View Updates

    private func startUpdateTimer() {
        // Update the view every 1 second to reflect data changes
        self.logger.info("⏰ Starting update timer for \(self.widgetType.rawValue)")
        self.updateTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCompactView()
            }
        }
    }

    // MARK: - Setup

    private func setupStatusItem() {
        guard self.configuration.isEnabled else {
            self.logger.warning("⚠️ setupStatusItem skipped - widget disabled: \(self.widgetType.rawValue)")
            return
        }

        self.logger.info("➕ setupStatusItem for \(self.widgetType.rawValue)")
        // Create status item with variable length based on display mode
        let length = self.configuration.displayMode.estimatedWidth

        self.statusItem = NSStatusBar.system.statusItem(withLength: length)
        self.logger.info("✅ StatusItem created for \(self.widgetType.rawValue), length: \(length)")

        if let button = self.statusItem?.button {
            button.target = self
            button.action = #selector(statusBarButtonClicked)

            // Set up the compact view
            self.updateCompactView()
            self.logger.info("✅ Button configured for \(self.widgetType.rawValue)")
        } else {
            self.logger.error("❌ Failed to get button for \(self.widgetType.rawValue)")
        }

        self.isVisible = true
    }

    private func setupPopover() {
        popover = NSPopover()
        popover?.behavior = .transient
        popover?.animates = true

        // Content will be set by subclasses
    }

    // MARK: - View Updates

    private func updateCompactView() {
        guard let button = statusItem?.button else { return }

        // Create SwiftUI compact view (override in subclasses)
        let compactView = createCompactView()

        anyHostingController = NSHostingController(rootView: AnyView(compactView))

        // Embed in button
        if let hostedView = anyHostingController?.view {
            hostedView.translatesAutoresizingMaskIntoConstraints = false
            button.subviews.forEach { $0.removeFromSuperview() }
            button.addSubview(hostedView)

            NSLayoutConstraint.activate([
                hostedView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                hostedView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                hostedView.topAnchor.constraint(equalTo: button.topAnchor),
                hostedView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
            ])
        }

        // Log the update with data values
        logCurrentData()
    }

    private func logCurrentData() {
        let dataManager = WidgetDataManager.shared
        switch self.widgetType {
        case .cpu:
            self.logger.debug("🔄 \(self.widgetType.rawValue) view updated - CPU: \(Int(dataManager.cpuData.totalUsage))%")
        case .memory:
            self.logger.debug("🔄 \(self.widgetType.rawValue) view updated - Memory: \(Int(dataManager.memoryData.usagePercentage))%")
        case .disk:
            if let primary = dataManager.diskVolumes.first {
                self.logger.debug("🔄 \(self.widgetType.rawValue) view updated - Disk: \(Int(primary.usagePercentage))%")
            } else {
                self.logger.debug("🔄 \(self.widgetType.rawValue) view updated - No disk data")
            }
        case .network:
            self.logger.debug("🔄 \(self.widgetType.rawValue) view updated - Connected: \(dataManager.networkData.isConnected), Download: \(dataManager.networkData.downloadString)")
        case .gpu:
            if let usage = dataManager.gpuData.usagePercentage {
                self.logger.debug("🔄 \(self.widgetType.rawValue) view updated - GPU: \(Int(usage))%")
            } else {
                self.logger.debug("🔄 \(self.widgetType.rawValue) view updated - No GPU data")
            }
        case .battery:
            self.logger.debug("🔄 \(self.widgetType.rawValue) view updated - Battery: \(Int(dataManager.batteryData.chargePercentage))%, Present: \(dataManager.batteryData.isPresent)")
        case .weather:
            self.logger.debug("🔄 \(self.widgetType.rawValue) view updated")
        }
    }

    /// Create the compact view for this widget (override in subclasses)
    open func createCompactView() -> AnyView {
        AnyView(
            WidgetCompactView(
                widgetType: widgetType,
                configuration: configuration
            )
        )
    }

    /// Update the status item width based on display mode
    public func updateWidth() {
        let newLength = configuration.displayMode.estimatedWidth
        statusItem?.length = newLength
    }

    /// Update the configuration and refresh the view
    public func updateConfiguration(_ newConfig: WidgetConfiguration) {
        let oldColor = configuration.accentColor.rawValue
        let oldFormat = configuration.valueFormat.rawValue
        let oldMode = configuration.displayMode.rawValue

        configuration = newConfig

        logger.info("🔧 updateConfiguration for \(self.widgetType.rawValue): color \(oldColor)→\(newConfig.accentColor.rawValue), format \(oldFormat)→\(newConfig.valueFormat.rawValue), mode \(oldMode)→\(newConfig.displayMode.rawValue)")

        if newConfig.isEnabled && !isVisible {
            // Widget was re-enabled
            logger.info("🔄 Widget re-enabled, setting up status item")
            setupStatusItem()
        } else if !newConfig.isEnabled && isVisible {
            // Widget was disabled
            logger.info("🔄 Widget disabled, removing status item")
            removeStatusItem()
        } else {
            // Configuration changed - force view refresh
            objectWillChange.send()

            // Recreate the compact view with new configuration
            let compactView = createCompactView()
            anyHostingController = NSHostingController(rootView: compactView)

            // Update the button's view
            if let button = statusItem?.button, let hostedView = anyHostingController?.view {
                hostedView.translatesAutoresizingMaskIntoConstraints = false
                button.subviews.forEach { $0.removeFromSuperview() }
                button.addSubview(hostedView)

                NSLayoutConstraint.activate([
                    hostedView.leadingAnchor.constraint(equalTo: button.leadingAnchor),
                    hostedView.trailingAnchor.constraint(equalTo: button.trailingAnchor),
                    hostedView.topAnchor.constraint(equalTo: button.topAnchor),
                    hostedView.bottomAnchor.constraint(equalTo: button.bottomAnchor)
                ])

                logger.info("✅ View updated successfully for \(self.widgetType.rawValue)")
            } else {
                logger.warning("⚠️ Could not update view - button or hostedView is nil for \(self.widgetType.rawValue)")
            }

            // Update width based on display mode
            updateWidth()

            logger.info("✏️ Updated widget \(self.widgetType.rawValue): displayMode=\(newConfig.displayMode.rawValue), color=\(newConfig.accentColor.rawValue), valueFormat=\(newConfig.valueFormat.rawValue)")
        }
    }

    // MARK: - Popover Management

    private func showPopover() {
        guard let button = statusItem?.button,
              let popover = popover else { return }

        // Update popover content with latest data
        popover.contentViewController = NSHostingController(
            rootView: createDetailView()
        )

        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
    }

    private func hidePopover() {
        popover?.performClose(nil)
    }

    /// Create the detail view for this widget (to be overridden by subclasses)
    open func createDetailView() -> AnyView {
        AnyView(WidgetDetailViewPlaceholder(widgetType: widgetType))
    }

    // MARK: - Actions

    @objc private func statusBarButtonClicked() {
        if let popover = popover, popover.isShown {
            hidePopover()
        } else {
            showPopover()
        }
    }

    // MARK: - Lifecycle

    private func removeStatusItem() {
        if let statusItem = statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
        isVisible = false
    }

    /// Show this widget in the menu bar
    public func show() {
        guard !isVisible else { return }
        setupStatusItem()
    }

    /// Hide this widget from the menu bar
    public func hide() {
        guard isVisible else { return }
        removeStatusItem()
    }

    /// Refresh the widget display with latest data
    public func refresh() {
        objectWillChange.send()
        updateCompactView()
    }
}

// MARK: - Widget Compact View

/// The compact menu bar view for a widget
struct WidgetCompactView: View {
    let widgetType: WidgetType
    let configuration: WidgetConfiguration
    @State private var dataManager = WidgetDataManager.shared

    private var accentColor: Color {
        configuration.accentColor.colorValue(for: widgetType)
    }

    var body: some View {
        HStack(spacing: 4) {
            // Icon
            Image(systemName: widgetType.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(accentColor)

            // Value - always shown in both compact and detailed modes
            Text(widgetValue)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(.primary)

            // Label (if enabled)
            if configuration.showLabel {
                Text(widgetType.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            // Sparkline for detailed mode
            if configuration.displayMode == .detailed {
                miniSparkline
                    .frame(width: 36, height: 14)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }

    // MARK: - Sparkline

    private var miniSparkline: some View {
        let data = sparklineData
        return GeometryReader { geometry in
            Path { path in
                guard data.count > 1 else { return }

                let stepX = geometry.size.width / CGFloat(data.count - 1)
                let maxY = data.max() ?? 1
                let minY = data.min() ?? 0
                let range = max(maxY - minY, 0.1)

                for (index, value) in data.enumerated() {
                    let x = CGFloat(index) * stepX
                    let normalizedY = (value - minY) / range
                    let y = geometry.size.height * (1 - normalizedY)

                    if index == 0 {
                        path.move(to: CGPoint(x: x, y: y))
                    } else {
                        path.addLine(to: CGPoint(x: x, y: y))
                    }
                }
            }
            .stroke(
                LinearGradient(
                    colors: [accentColor, accentColor.opacity(0.4)],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                lineWidth: 1.5
            )
        }
    }

    private var sparklineData: [Double] {
        switch widgetType {
        case .cpu:
            let history = dataManager.cpuHistory.suffix(10)
            return history.isEmpty ? [30, 35, 32, 38, 36, 34, 37, 35, 33, 36] : Array(history)
        case .memory:
            let history = dataManager.memoryHistory.suffix(10)
            return history.isEmpty ? [60, 62, 58, 65, 63, 67, 64, 68, 66, 65] : Array(history)
        default:
            return [30, 35, 32, 38, 36, 34, 37, 35, 33, 36]
        }
    }

    private var widgetValue: String {
        let usePercent = configuration.valueFormat == .percentage

        switch widgetType {
        case .cpu:
            if usePercent {
                return "\(Int(dataManager.cpuData.totalUsage))%"
            } else {
                // Show GHz equivalent roughly
                let baseFreq = 3.0 // Base frequency assumption
                let currentFreq = baseFreq * (dataManager.cpuData.totalUsage / 100.0)
                return String(format: "%.1fGHz", currentFreq)
            }

        case .memory:
            if usePercent {
                return "\(Int(dataManager.memoryData.usagePercentage))%"
            } else {
                let usedGB = Double(dataManager.memoryData.usedBytes) / (1024 * 1024 * 1024)
                return String(format: "%.1fGB", usedGB)
            }

        case .disk:
            if let primary = dataManager.diskVolumes.first {
                if usePercent {
                    return "\(Int(primary.usagePercentage))%"
                } else {
                    let freeGB = primary.freeBytes / (1024 * 1024 * 1024)
                    return "\(freeGB)GB"
                }
            }
            return "--"

        case .network:
            return dataManager.networkData.downloadString

        case .gpu:
            if let usage = dataManager.gpuData.usagePercentage {
                if usePercent {
                    return "\(Int(usage))%"
                } else {
                    // Rough frequency estimate
                    let baseFreq = 1.0
                    let currentFreq = baseFreq + (usage / 100.0)
                    return String(format: "%.1fGHz", currentFreq)
                }
            }
            return "--"

        case .weather:
            return "--°" // Will be filled by WeatherWidgetView

        case .battery:
            if dataManager.batteryData.isPresent {
                if usePercent {
                    return "\(Int(dataManager.batteryData.chargePercentage))%"
                } else {
                    if let minutes = dataManager.batteryData.estimatedMinutesRemaining {
                        let hours = minutes / 60
                        let mins = minutes % 60
                        if hours > 0 {
                            return "\(hours)h\(mins)m"
                        } else {
                            return "\(mins)m"
                        }
                    } else {
                        return "--"
                    }
                }
            }
            return "--"
        }
    }
}

// MARK: - Placeholder Detail View

/// Placeholder detail view until specific widget detail views are implemented
struct WidgetDetailViewPlaceholder: View {
    let widgetType: WidgetType

    var body: some View {
        VStack(spacing: 16) {
            HStack {
                Image(systemName: widgetType.icon)
                    .font(.title2)
                    .foregroundColor(TonicColors.accent)

                Text("\(widgetType.displayName) Details")
                    .font(.headline)

                Spacer()
            }
            .padding()

            Text("Detailed view for \(widgetType.displayName) widget coming soon.")
                .foregroundColor(.secondary)
                .padding()

            Spacer()
        }
        .frame(width: 300, height: 200)
        .padding()
    }
}

// MARK: - Widget Coordinator

/// Coordinates multiple widget status items
@MainActor
public final class WidgetCoordinator: ObservableObject {

    public static let shared = WidgetCoordinator()

    private let logger = Logger(subsystem: "com.tonic.app", category: "WidgetCoordinator")

    /// All active widget status items
    @Published public private(set) var activeWidgets: [WidgetType: WidgetStatusItem] = [:]

    /// Whether the widget system is active
    @Published public private(set) var isActive = false

    private init() {}

    // MARK: - Widget Management

    /// Start showing enabled widgets in the menu bar
    public func start() {
        guard !isActive else {
            logger.warning("⚠️ Already active, skipping start()")
            print("⚠️ [WidgetCoordinator] Already active, skipping start()")
            return
        }
        logger.info("🚀 Starting WidgetCoordinator")
        print("🚀 [WidgetCoordinator] Starting WidgetCoordinator")
        isActive = true

        // Start data monitoring
        logger.info("📊 Calling WidgetDataManager.shared.startMonitoring()")
        print("📊 [WidgetCoordinator] Calling WidgetDataManager.shared.startMonitoring()")
        WidgetDataManager.shared.startMonitoring()

        // Create status items for enabled widgets
        logger.info("🔄 Refreshing widgets...")
        print("🔄 [WidgetCoordinator] Refreshing widgets...")
        refreshWidgets()
        logger.info("✅ WidgetCoordinator started with \(self.activeWidgets.count) active widgets")
        print("✅ [WidgetCoordinator] Started with \(self.activeWidgets.count) active widgets")
    }

    /// Stop showing widgets
    public func stop() {
        isActive = false

        // Remove all status items
        activeWidgets.values.forEach { $0.hide() }
        activeWidgets.removeAll()

        // Stop data monitoring
        WidgetDataManager.shared.stopMonitoring()
    }

    /// Refresh widgets based on current preferences
    public func refreshWidgets() {
        let enabledConfigs = WidgetPreferences.shared.enabledWidgets
        logger.info("🔄 refreshWidgets - enabled configs: \(enabledConfigs.count)")

        // Log config values to trace what's being read from preferences
        for config in enabledConfigs {
            logger.info("📋 Config for \(config.type.rawValue): color=\(config.accentColor.rawValue), format=\(config.valueFormat.rawValue), mode=\(config.displayMode.rawValue)")
        }

        // Remove widgets that are no longer enabled
        let activeTypes = Set(activeWidgets.keys)
        let enabledTypes = Set(enabledConfigs.map { $0.type })
        let toRemove = activeTypes.subtracting(enabledTypes)

        for type in toRemove {
            logger.info("🔻 Removing widget: \(type.rawValue)")
            activeWidgets[type]?.hide()
            activeWidgets.removeValue(forKey: type)
        }

        // Add or update enabled widgets
        for config in enabledConfigs {
            if let existing = activeWidgets[config.type] {
                logger.info("🔄 Updating existing widget: \(config.type.rawValue) with color=\(config.accentColor.rawValue)")
                existing.updateConfiguration(config)
            } else {
                logger.info("➕ Creating new widget: \(config.type.rawValue)")
                let widget = createWidget(for: config.type, configuration: config)
                activeWidgets[config.type] = widget
            }
        }

        let widgetTypes = self.activeWidgets.keys.map { $0.rawValue }
        logger.info("✅ After refresh - active widgets: \(self.activeWidgets.count), types: \(widgetTypes)")
    }

    /// Create the appropriate widget subclass for the given type
    private func createWidget(for type: WidgetType, configuration: WidgetConfiguration) -> WidgetStatusItem {
        switch type {
        case .cpu:
            return CPUStatusItem(widgetType: type, configuration: configuration)
        case .memory:
            return MemoryStatusItem(widgetType: type, configuration: configuration)
        case .disk:
            return DiskStatusItem(widgetType: type, configuration: configuration)
        case .network:
            return NetworkStatusItem(widgetType: type, configuration: configuration)
        case .gpu:
            return GPUStatusItem(widgetType: type, configuration: configuration)
        case .battery:
            return BatteryStatusItem(widgetType: type, configuration: configuration)
        case .weather:
            return WeatherStatusItem(widgetType: type, configuration: configuration)
        }
    }

    /// Update a specific widget's configuration
    public func updateWidget(type: WidgetType, configuration: WidgetConfiguration) {
        if let widget = activeWidgets[type] {
            widget.updateConfiguration(configuration)
        }
    }

    /// Get the status item for a specific widget type
    public func widget(for type: WidgetType) -> WidgetStatusItem? {
        activeWidgets[type]
    }
}
