//
//  NotificationRuleEngine.swift
//  Tonic
//
//  Notification rules engine for system alerts
//  Task ID: fn-2.10
//

import Foundation
import UserNotifications
import SwiftUI

// MARK: - Notification Rule Engine

/// Engine for evaluating notification rules and triggering alerts
@MainActor
@Observable
public final class NotificationRuleEngine {

    public static let shared = NotificationRuleEngine()

    // MARK: - Properties

    /// All configured rules
    public private(set) var rules: [NotificationRule] = []

    /// Trigger history log
    public private(set) var triggerHistory: [RuleTrigger] = []

    /// Whether the engine is active
    public private(set) var isActive = false

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let rules = "tonic.notificationRules.rules"
        static let triggerHistory = "tonic.notificationRules.history"
        static let isEnabled = "tonic.notificationRules.isEnabled"
    }

    // MARK: - Timer

    /// Timer for periodic rule evaluation
    private var evaluationTimer: Timer?

    // MARK: - Initialization

    private init() {
        loadRules()

        // Clean up old trigger history (keep last 100)
        cleanupHistory()

        // Request notification permission
        requestNotificationPermission()
    }

    // MARK: - Public Methods

    /// Start the rule engine
    public func start() {
        guard !isActive else { return }
        isActive = true

        // Start monitoring WidgetDataManager
        WidgetDataManager.shared.startMonitoring()

        // Setup periodic rule evaluation
        setupObserver()
    }

    /// Stop the rule engine
    public func stop() {
        isActive = false

        // Stop the evaluation timer
        stopObserver()
    }

    /// Add a new rule
    public func addRule(_ rule: NotificationRule) {
        rules.append(rule)
        saveRules()
    }

    /// Update an existing rule
    public func updateRule(_ rule: NotificationRule) {
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index] = rule
            saveRules()
        }
    }

    /// Delete a rule
    public func deleteRule(_ rule: NotificationRule) {
        rules.removeAll { $0.id == rule.id }
        saveRules()
    }

    /// Evaluate all rules against current data
    public func evaluateRules() {
        guard isActive else { return }

        let dataManager = WidgetDataManager.shared
        let weatherService = WeatherService.shared

        for rule in rules where rule.isEnabled {
            // Check cooldown
            if rule.isInCooldown {
                continue
            }

            // Get current value for the metric
            let currentValue: Double?
            let shouldTrigger: Bool

            switch rule.metric {
            case .cpuUsage:
                currentValue = dataManager.cpuData.totalUsage
                shouldTrigger = rule.condition.evaluate(value: currentValue ?? 0, threshold: rule.threshold)

            case .memoryPressure:
                // Map pressure to numeric: normal=0, warning=1, critical=2
                let pressureValue: Double
                switch dataManager.memoryData.pressure {
                case .normal: pressureValue = 0
                case .warning: pressureValue = 1
                case .critical: pressureValue = 2
                }
                currentValue = pressureValue
                shouldTrigger = rule.condition.evaluate(value: pressureValue, threshold: rule.threshold)

            case .diskSpace:
                // Get minimum free space percentage across volumes
                let minFreeSpace = dataManager.diskVolumes.map { $0.freeBytes }.min() ?? 0
                let minTotalSpace = dataManager.diskVolumes.map { $0.totalBytes }.max() ?? 1
                let freePercentage = (Double(minFreeSpace) / Double(minTotalSpace)) * 100
                currentValue = freePercentage
                shouldTrigger = rule.condition.evaluate(value: freePercentage, threshold: rule.threshold)

            case .networkDown:
                // Network is down (0) or up (1)
                currentValue = dataManager.networkData.isConnected ? 1 : 0
                shouldTrigger = rule.condition.evaluate(value: currentValue ?? 0, threshold: rule.threshold)

            case .weatherTemp:
                currentValue = weatherService.currentWeather?.current.temperature
                shouldTrigger = currentValue.map { rule.condition.evaluate(value: $0, threshold: rule.threshold) } ?? false
            }

            // Trigger notification if condition is met
            if shouldTrigger, let value = currentValue {
                triggerNotification(rule: rule, value: value)
            }
        }
    }

    /// Test a rule by triggering a sample notification
    public func testRule(_ rule: NotificationRule) {
        triggerNotification(rule: rule, value: rule.threshold)
    }

    /// Reset all rules to presets
    public func resetToPresets() {
        rules = NotificationRule.presetRules.map { rule in
            NotificationRule(
                name: rule.name,
                isEnabled: false, // Presets are off by default
                metric: rule.metric,
                condition: rule.condition,
                threshold: rule.threshold,
                cooldownMinutes: rule.cooldownMinutes
            )
        }
        saveRules()
    }

    // MARK: - Notification Methods

    private func triggerNotification(rule: NotificationRule, value: Double) {
        // Update last triggered time
        if let index = rules.firstIndex(where: { $0.id == rule.id }) {
            rules[index].lastTriggered = Date()
            saveRules()
        }

        // Add to history
        let trigger = RuleTrigger(
            ruleId: rule.id,
            ruleName: rule.name,
            value: value,
            threshold: rule.threshold
        )
        triggerHistory.append(trigger)
        saveHistory()

        // Send notification
        sendNotification(for: rule, value: value)
    }

    private func sendNotification(for rule: NotificationRule, value: Double) {
        let content = UNMutableNotificationContent()
        content.title = rule.name
        content.body = notificationBody(for: rule, value: value)
        content.sound = .default

        // Add icon for notification
        if let iconUrl = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") {
            // On macOS, notification icons use the app icon by default
        }

        let request = UNNotificationRequest(
            identifier: rule.id.uuidString,
            content: content,
            trigger: nil
        )

        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("Notification error: \(error)")
            }
        }
    }

    private func notificationBody(for rule: NotificationRule, value: Double) -> String {
        let valueString = String(format: "%.1f", value)

        switch rule.metric {
        case .cpuUsage:
            return "CPU usage is \(valueString)%"
        case .memoryPressure:
            let pressure = ["Normal", "Warning", "Critical"][Int(value)]
            return "Memory pressure is \(pressure)"
        case .diskSpace:
            return "Free disk space is \(valueString)%"
        case .networkDown:
            return "Network connection lost"
        case .weatherTemp:
            return "Temperature is \(valueString)°"
        }
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if granted {
                print("Notification permission granted")
            } else if let error = error {
                print("Notification permission error: \(error)")
            }
        }
    }

    // MARK: - Persistence

    private func loadRules() {
        if let data = UserDefaults.standard.data(forKey: Keys.rules),
           let decoded = try? JSONDecoder().decode([NotificationRule].self, from: data) {
            rules = decoded
        } else {
            // Start with presets if nothing saved
            rules = NotificationRule.presetRules
        }

        // Load enabled state
        isActive = UserDefaults.standard.bool(forKey: Keys.isEnabled)

        // Load history
        if let data = UserDefaults.standard.data(forKey: Keys.triggerHistory),
           let decoded = try? JSONDecoder().decode([RuleTrigger].self, from: data) {
            triggerHistory = decoded
        }
    }

    private func saveRules() {
        if let encoded = try? JSONEncoder().encode(rules) {
            UserDefaults.standard.set(encoded, forKey: Keys.rules)
        }
    }

    private func saveHistory() {
        // Keep only last 100 entries
        if triggerHistory.count > 100 {
            triggerHistory = Array(triggerHistory.suffix(100))
        }

        if let encoded = try? JSONEncoder().encode(triggerHistory) {
            UserDefaults.standard.set(encoded, forKey: Keys.triggerHistory)
        }
    }

    private func cleanupHistory() {
        // Remove history entries older than 7 days
        let cutoffDate = Calendar.current.date(byAdding: .day, value: -7, to: Date()) ?? Date()
        triggerHistory.removeAll { $0.triggeredAt < cutoffDate }
        saveHistory()
    }

    // MARK: - History Methods

    /// Get trigger history for a specific rule
    public func historyForRule(_ rule: NotificationRule) -> [RuleTrigger] {
        return triggerHistory.filter { $0.ruleId == rule.id }
    }

    /// Clear all trigger history
    public func clearHistory() {
        triggerHistory = []
        saveHistory()
    }
}

// MARK: - Rule Engine Observer

/// Observer that triggers rule evaluation on data updates
extension NotificationRuleEngine {
    /// Setup observer for WidgetDataManager updates
    public func setupObserver() {
        // Stop any existing timer first
        stopObserver()

        // Create and store timer for periodic rule evaluation
        evaluationTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.evaluateRules()
            }
        }
    }

    /// Stop the observer timer

    /// Stop the observer timer
    public func stopObserver() {
        evaluationTimer?.invalidate()
        evaluationTimer = nil
    }
}
