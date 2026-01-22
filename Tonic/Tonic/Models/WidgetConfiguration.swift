//
//  WidgetConfiguration.swift
//  Tonic
//
//  Menu bar widget configuration data models
//  Task ID: fn-2.1
//

import SwiftUI

// MARK: - Widget Type

/// Widget types available in the menu bar monitoring system
public enum WidgetType: String, CaseIterable, Identifiable, Codable {
    case cpu = "cpu"
    case gpu = "gpu"
    case memory = "memory"
    case disk = "disk"
    case network = "network"
    case weather = "weather"
    case battery = "battery"

    public var id: String { rawValue }

    /// Display name for the widget
    public var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .memory: return "Memory"
        case .disk: return "Disk"
        case .network: return "Network"
        case .weather: return "Weather"
        case .battery: return "Battery"
        }
    }

    /// SF Symbol icon for the widget
    public var icon: String {
        switch self {
        case .cpu: return "cpu"
        case .gpu: return "cpu.fill" // Will use GPU-specific icon in view
        case .memory: return "memorychip"
        case .disk: return "internaldrive"
        case .network: return "wifi"
        case .weather: return "cloud.sun"
        case .battery: return "battery.100"
        }
    }

    /// Whether this widget is platform-specific (auto-hide on certain Macs)
    public var isPlatformSpecific: Bool {
        switch self {
        case .gpu: return true // Apple Silicon only
        case .battery: return true // Portable Macs only
        default: return false
        }
    }
}

// MARK: - Widget Display Mode

/// Display mode options for each widget
public enum WidgetDisplayMode: String, CaseIterable, Identifiable, Codable {
    case iconOnly = "iconOnly"
    case iconWithValue = "iconWithValue"
    case iconWithValueAndSparkline = "iconWithValueAndSparkline"

    public var id: String { rawValue }

    /// Display name for the mode
    public var displayName: String {
        switch self {
        case .iconOnly: return "Icon only"
        case .iconWithValue: return "Icon + Value"
        case .iconWithValueAndSparkline: return "Icon + Value + Graph"
        }
    }

    /// Approximate width in points for this mode
    public var estimatedWidth: CGFloat {
        switch self {
        case .iconOnly: return 20
        case .iconWithValue: return 50
        case .iconWithValueAndSparkline: return 90
        }
    }
}

// MARK: - Widget Configuration

/// Configuration for a single menu bar widget
public struct WidgetConfiguration: Codable, Identifiable, Sendable {
    public let id: UUID
    public var type: WidgetType
    public var isEnabled: Bool
    public var position: Int
    public var displayMode: WidgetDisplayMode
    public var showLabel: Bool

    public init(
        id: UUID = UUID(),
        type: WidgetType,
        isEnabled: Bool = true,
        position: Int,
        displayMode: WidgetDisplayMode = .iconWithValue,
        showLabel: Bool = false
    ) {
        self.id = id
        self.type = type
        self.isEnabled = isEnabled
        self.position = position
        self.displayMode = displayMode
        self.showLabel = showLabel
    }

    /// Default configuration for a given widget type
    public static func `default`(for type: WidgetType, at position: Int) -> WidgetConfiguration {
        WidgetConfiguration(
            type: type,
            isEnabled: type.isDefaultEnabled,
            position: position,
            displayMode: .iconWithValue,
            showLabel: false
        )
    }
}

extension WidgetType {
    /// Whether this widget should be enabled by default
    var isDefaultEnabled: Bool {
        switch self {
        case .cpu, .memory, .disk: return true
        case .gpu, .network, .weather, .battery: return false
        }
    }
}

// MARK: - Widget Update Interval

/// Update interval presets based on power mode
public enum WidgetUpdateInterval: String, CaseIterable, Identifiable, Codable {
    case power = "power"       // 5 seconds - power saving
    case balanced = "balanced" // 2 seconds - default
    case performance = "performance" // 1 second - high refresh

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .power: return "Power Saving (5s)"
        case .balanced: return "Balanced (2s)"
        case .performance: return "Performance (1s)"
        }
    }

    /// The time interval in seconds
    public var timeInterval: TimeInterval {
        switch self {
        case .power: return 5.0
        case .balanced: return 2.0
        case .performance: return 1.0
        }
    }
}

// MARK: - Widget Preferences

/// Global preferences for menu bar widgets
@MainActor
@Observable
public final class WidgetPreferences: Sendable {
    public static let shared = WidgetPreferences()

    // MARK: - Properties

    /// Configuration for all available widgets
    public var widgetConfigs: [WidgetConfiguration]

    /// Global update interval preset
    public var updateInterval: WidgetUpdateInterval

    /// Whether widget system has been onboarded
    public var hasCompletedOnboarding: Bool

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let widgetConfigs = "tonic.widget.configs"
        static let updateInterval = "tonic.widget.updateInterval"
        static let hasCompletedOnboarding = "tonic.widget.hasCompletedOnboarding"
    }

    // MARK: - Initialization

    private init() {
        self.updateInterval = .balanced
        self.hasCompletedOnboarding = false
        self.widgetConfigs = Self.loadConfigsFromUserDefaults() ?? Self.defaultConfigs()

        // Load other preferences
        loadFromUserDefaults()
    }

    // MARK: - Default Configuration

    /// Create default widget configurations
    private static func defaultConfigs() -> [WidgetConfiguration] {
        let allTypes: [WidgetType] = [
            .cpu, .gpu, .memory, .disk, .network, .weather, .battery
        ]

        return allTypes.enumerated().map { index, type in
            WidgetConfiguration.default(for: type, at: index)
        }
    }

    /// Get enabled widgets sorted by position
    public var enabledWidgets: [WidgetConfiguration] {
        widgetConfigs
            .filter { $0.isEnabled }
            .sorted { $0.position < $1.position }
    }

    /// Get configuration for a specific widget type
    public func config(for type: WidgetType) -> WidgetConfiguration? {
        widgetConfigs.first { $0.type == type }
    }

    /// Update configuration for a specific widget type
    public func updateConfig(for type: WidgetType, _ update: (inout WidgetConfiguration) -> Void) {
        if let index = widgetConfigs.firstIndex(where: { $0.type == type }) {
            update(&widgetConfigs[index])
            saveConfigs()
        }
    }

    /// Reorder widgets to new positions
    public func reorderWidgets(_ configs: [WidgetConfiguration]) {
        // Update positions based on new order
        for (index, var config) in configs.enumerated() {
            config.position = index
            widgetConfigs[index] = config
        }
        saveConfigs()
    }

    /// Reset all configurations to defaults
    public func resetToDefaults() {
        widgetConfigs = Self.defaultConfigs()
        updateInterval = .balanced
        saveConfigs()
        saveInterval()
        saveOnboarding()
    }

    // MARK: - Persistence

    private func loadFromUserDefaults() {
        // Load update interval
        if let intervalString = UserDefaults.standard.string(forKey: Keys.updateInterval),
           let interval = WidgetUpdateInterval(rawValue: intervalString) {
            updateInterval = interval
        }

        // Load onboarding status
        hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Keys.hasCompletedOnboarding)
    }

    internal func saveConfigs() {
        if let encoded = try? JSONEncoder().encode(widgetConfigs) {
            UserDefaults.standard.set(encoded, forKey: Keys.widgetConfigs)
        }
    }

    private static func loadConfigsFromUserDefaults() -> [WidgetConfiguration]? {
        guard let data = UserDefaults.standard.data(forKey: Keys.widgetConfigs),
              let configs = try? JSONDecoder().decode([WidgetConfiguration].self, from: data) else {
            return nil
        }
        return configs
    }

    private func saveInterval() {
        UserDefaults.standard.set(updateInterval.rawValue, forKey: Keys.updateInterval)
    }

    private func saveOnboarding() {
        UserDefaults.standard.set(hasCompletedOnboarding, forKey: Keys.hasCompletedOnboarding)
    }

    // MARK: - Public Setters

    public func setUpdateInterval(_ interval: WidgetUpdateInterval) {
        updateInterval = interval
        saveInterval()
    }

    public func setHasCompletedOnboarding(_ completed: Bool) {
        hasCompletedOnboarding = completed
        saveOnboarding()
    }

    public func toggleWidget(type: WidgetType) {
        updateConfig(for: type) { config in
            config.isEnabled.toggle()
        }
    }

    public func setWidgetEnabled(type: WidgetType, enabled: Bool) {
        updateConfig(for: type) { config in
            config.isEnabled = enabled
        }
    }

    public func setWidgetDisplayMode(type: WidgetType, mode: WidgetDisplayMode) {
        updateConfig(for: type) { config in
            config.displayMode = mode
        }
    }

    public func setWidgetShowLabel(type: WidgetType, show: Bool) {
        updateConfig(for: type) { config in
            config.showLabel = show
        }
    }
}
