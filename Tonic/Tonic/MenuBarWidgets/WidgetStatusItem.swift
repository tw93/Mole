//
//  WidgetStatusItem.swift
//  Tonic
//
//  Base NSStatusItem wrapper for menu bar widgets
//  Task ID: fn-2.3
//

import AppKit
import SwiftUI

// MARK: - Widget Status Item

/// Base class for managing a single widget's NSStatusItem
/// Each widget type creates its own instance to manage its menu bar presence
@MainActor
public class WidgetStatusItem: ObservableObject {

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

    /// Hosting controller for the compact view
    private var hostingController: NSHostingController<WidgetCompactView>?

    // MARK: - Initialization

    public init(widgetType: WidgetType, configuration: WidgetConfiguration) {
        self.widgetType = widgetType
        self.configuration = configuration

        setupStatusItem()
        setupPopover()
    }

    deinit {
        removeStatusItem()
    }

    // MARK: - Setup

    private func setupStatusItem() {
        guard configuration.isEnabled else { return }

        // Create status item with variable length based on display mode
        let length = configuration.displayMode.estimatedWidth

        statusItem = NSStatusBar.system.statusItem(withLength: length)

        if let button = statusItem?.button {
            button.target = self
            button.action = #selector(statusBarButtonClicked)

            // Set up the compact view
            updateCompactView()
        }

        isVisible = true
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

        // Create SwiftUI compact view
        let compactView = WidgetCompactView(
            widgetType: widgetType,
            configuration: configuration,
            dataManager: WidgetDataManager.shared
        )

        hostingController = NSHostingController(rootView: compactView)

        // Embed in button
        if let hostedView = hostingController?.view {
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
    }

    /// Update the status item width based on display mode
    public func updateWidth() {
        let newLength = configuration.displayMode.estimatedWidth
        statusItem?.length = newLength
    }

    /// Update the configuration and refresh the view
    public func updateConfiguration(_ newConfig: WidgetConfiguration) {
        configuration = newConfig

        if newConfig.isEnabled && !isVisible {
            // Widget was re-enabled
            setupStatusItem()
        } else if !newConfig.isEnabled && isVisible {
            // Widget was disabled
            removeStatusItem()
        } else {
            // Just update the view
            updateCompactView()
            updateWidth()
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
    public func createDetailView() -> some View {
        WidgetDetailViewPlaceholder(widgetType: widgetType)
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
    @ObservedController var dataManager: WidgetDataManager

    var body: some View {
        HStack(spacing: 4) {
            // Icon
            Image(systemName: widgetType.icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundColor(TonicColors.accent)

            // Value (if enabled)
            if configuration.displayMode != .iconOnly {
                Text(widgetValue)
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundColor(.primary)
            }

            // Label (if enabled)
            if configuration.showLabel {
                Text(widgetType.displayName)
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 22)
    }

    private var widgetValue: String {
        switch widgetType {
        case .cpu:
            return "\(Int(dataManager.cpuData.totalUsage))%"
        case .memory:
            return "\(Int(dataManager.memoryData.usagePercentage))%"
        case .disk:
            if let primary = dataManager.diskVolumes.first {
                return "\(Int(primary.usagePercentage))%"
            }
            return "--"
        case .network:
            if dataManager.networkData.isConnected {
                return dataManager.networkData.downloadString
            }
            return "--"
        case .gpu:
            if let usage = dataManager.gpuData.usagePercentage {
                return "\(Int(usage))%"
            }
            return "--"
        case .weather:
            return "--°" // Will be filled by WeatherWidgetView
        case .battery:
            if dataManager.batteryData.isPresent {
                return "\(Int(dataManager.batteryData.chargePercentage))%"
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

// MARK: - ObservedController Property Wrapper

/// Property wrapper for observing non-SwiftUI observable objects
@propertyWrapper
struct ObservedController<ObservedObject: Observable>: DynamicProperty {
    @ObservedObject private var value: ObservedObject

    var wrappedValue: ObservedObject {
        get { value }
    }

    init(initialValue: ObservedObject) {
        self._value = ObservedObject(wrappedValue: initialValue)
    }
}

// Make WidgetDataManager conform to ObservableObject for SwiftUI
extension WidgetDataManager: ObservableObject {}

// MARK: - Widget Coordinator

/// Coordinates multiple widget status items
@MainActor
public final class WidgetCoordinator: ObservableObject {

    public static let shared = WidgetCoordinator()

    /// All active widget status items
    @Published public private(set) var activeWidgets: [WidgetType: WidgetStatusItem] = [:]

    /// Whether the widget system is active
    @Published public private(set) var isActive = false

    private init() {}

    // MARK: - Widget Management

    /// Start showing enabled widgets in the menu bar
    public func start() {
        guard !isActive else { return }
        isActive = true

        // Start data monitoring
        WidgetDataManager.shared.startMonitoring()

        // Create status items for enabled widgets
        refreshWidgets()
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

        // Remove widgets that are no longer enabled
        let activeTypes = Set(activeWidgets.keys)
        let enabledTypes = Set(enabledConfigs.map { $0.type })
        let toRemove = activeTypes.subtracting(enabledTypes)

        for type in toRemove {
            activeWidgets[type]?.hide()
            activeWidgets.removeValue(forKey: type)
        }

        // Add or update enabled widgets
        for config in enabledConfigs {
            if let existing = activeWidgets[config.type] {
                existing.updateConfiguration(config)
            } else {
                let widget = WidgetStatusItem(widgetType: config.type, configuration: config)
                activeWidgets[config.type] = widget
            }
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
