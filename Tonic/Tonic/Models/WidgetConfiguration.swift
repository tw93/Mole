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
    case compact = "compact"
    case detailed = "detailed"

    public var id: String { rawValue }

    /// Display name for the mode
    public var displayName: String {
        switch self {
        case .compact: return "Compact"
        case .detailed: return "Detailed"
        }
    }

    /// Short label for tags
    public var shortLabel: String {
        switch self {
        case .compact: return "Compact"
        case .detailed: return "Detailed"
        }
    }

    /// Approximate width in points for this mode
    public var estimatedWidth: CGFloat {
        switch self {
        case .compact: return 70
        case .detailed: return 130
        }
    }
}

// MARK: - Widget Value Format

/// How to display the value (percentage vs absolute with unit)
public enum WidgetValueFormat: String, CaseIterable, Identifiable, Codable {
    case percentage = "percentage"
    case valueWithUnit = "valueWithUnit"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .percentage: return "Percentage (%)"
        case .valueWithUnit: return "Value with Unit"
        }
    }

    public var shortLabel: String {
        switch self {
        case .percentage: return "%"
        case .valueWithUnit: return "Value"
        }
    }
}

// MARK: - Widget Accent Color

/// Color options for widgets
public enum WidgetAccentColor: String, CaseIterable, Identifiable, Codable, Sendable {
    case system = "system"
    case blue = "blue"
    case green = "green"
    case orange = "orange"
    case purple = "purple"
    case yellow = "yellow"

    public var id: String { rawValue }

    /// Display name for the color
    public var displayName: String {
        switch self {
        case .system: return "Auto"
        case .blue: return "Blue"
        case .green: return "Green"
        case .orange: return "Orange"
        case .purple: return "Purple"
        case .yellow: return "Yellow"
        }
    }

    /// The actual Color value
    public func colorValue(for widgetType: WidgetType) -> Color {
        switch self {
        case .system:
            // Return default color for each widget type when in Auto mode
            return defaultColor(for: widgetType)
        case .blue: return Color(red: 0.37, green: 0.62, blue: 1.0)
        case .green: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .orange: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .purple: return Color(red: 0.75, green: 0.35, blue: 0.95)
        case .yellow: return Color(red: 1.0, green: 0.84, blue: 0.04)
        }
    }

    /// Default color for each widget type when in Auto mode
    private func defaultColor(for widgetType: WidgetType) -> Color {
        switch widgetType {
        case .cpu: return Color(red: 0.37, green: 0.62, blue: 1.0)
        case .memory: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .disk: return Color(red: 1.0, green: 0.62, blue: 0.04)
        case .network: return Color(red: 0.39, green: 0.82, blue: 1.0)
        case .gpu: return Color(red: 0.75, green: 0.35, blue: 0.95)
        case .battery: return Color(red: 0.19, green: 0.82, blue: 0.35)
        case .weather: return Color(red: 1.0, green: 0.84, blue: 0.04)
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
    public var valueFormat: WidgetValueFormat
    public var refreshInterval: WidgetUpdateInterval
    public var accentColor: WidgetAccentColor

    public init(
        id: UUID = UUID(),
        type: WidgetType,
        isEnabled: Bool = true,
        position: Int,
        displayMode: WidgetDisplayMode,
        showLabel: Bool = false,
        valueFormat: WidgetValueFormat = .percentage,
        refreshInterval: WidgetUpdateInterval = .balanced,
        accentColor: WidgetAccentColor = .system
    ) {
        self.id = id
        self.type = type
        self.isEnabled = isEnabled
        self.position = position
        self.displayMode = displayMode
        self.showLabel = showLabel
        self.valueFormat = valueFormat
        self.refreshInterval = refreshInterval
        self.accentColor = accentColor
    }

    /// Default configuration for a given widget type
    public static func `default`(for type: WidgetType, at position: Int) -> WidgetConfiguration {
        WidgetConfiguration(
            type: type,
            isEnabled: type.isDefaultEnabled,
            position: position,
            displayMode: .compact,
            showLabel: false,
            valueFormat: type.defaultValueFormat,
            refreshInterval: .balanced,
            accentColor: .system
        )
    }
}

extension WidgetType {
    /// Default value format for this widget type
    var defaultValueFormat: WidgetValueFormat {
        switch self {
        case .cpu, .memory, .gpu, .battery:
            return .percentage
        case .disk, .network:
            return .valueWithUnit
        case .weather:
            return .valueWithUnit
        }
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
        guard let data = UserDefaults.standard.data(forKey: Keys.widgetConfigs) else {
            return nil
        }

        // First, try to decode with the current struct
        if let configs = try? JSONDecoder().decode([WidgetConfiguration].self, from: data) {
            return configs
        }

        // If that fails, try to decode with legacy format and migrate
        struct LegacyWidgetConfiguration: Codable {
            let id: UUID
            var type: WidgetType
            var isEnabled: Bool
            var position: Int
            var displayMode: LegacyDisplayMode
            var showLabel: Bool
            var valueFormat: WidgetValueFormat
            var refreshInterval: WidgetUpdateInterval
        }

        enum LegacyDisplayMode: String, Codable {
            case iconOnly = "iconOnly"
            case iconWithValue = "iconWithValue"
            case iconWithValueAndSparkline = "iconWithValueAndSparkline"

            func migrate() -> WidgetDisplayMode {
                switch self {
                case .iconOnly, .iconWithValue: return .compact
                case .iconWithValueAndSparkline: return .detailed
                }
            }
        }

        if let legacyConfigs = try? JSONDecoder().decode([LegacyWidgetConfiguration].self, from: data) {
            // Migrate to new format
            return legacyConfigs.map { legacy in
                WidgetConfiguration(
                    id: legacy.id,
                    type: legacy.type,
                    isEnabled: legacy.isEnabled,
                    position: legacy.position,
                    displayMode: legacy.displayMode.migrate(),
                    showLabel: legacy.showLabel,
                    valueFormat: legacy.valueFormat,
                    refreshInterval: legacy.refreshInterval,
                    accentColor: .system
                )
            }
        }

        return nil
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

    public func setWidgetValueFormat(type: WidgetType, format: WidgetValueFormat) {
        updateConfig(for: type) { config in
            config.valueFormat = format
        }
    }

    public func setWidgetRefreshInterval(type: WidgetType, interval: WidgetUpdateInterval) {
        updateConfig(for: type) { config in
            config.refreshInterval = interval
        }
    }

    public func setWidgetColor(type: WidgetType, color: WidgetAccentColor) {
        updateConfig(for: type) { config in
            config.accentColor = color
        }
    }
}
