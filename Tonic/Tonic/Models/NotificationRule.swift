//
//  NotificationRule.swift
//  Tonic
//
//  Notification rule data model
//  Task ID: fn-2.10
//

import Foundation
import SwiftUI

// MARK: - Notification Rule

/// A rule for triggering notifications based on system metrics
public struct NotificationRule: Identifiable, Codable, Sendable {
    public let id: UUID
    public var name: String
    public var isEnabled: Bool
    public var metric: MetricType
    public var condition: Condition
    public var threshold: Double
    public var cooldownMinutes: Int
    public var lastTriggered: Date?

    public init(
        id: UUID = UUID(),
        name: String,
        isEnabled: Bool = true,
        metric: MetricType,
        condition: Condition = .greaterThan,
        threshold: Double,
        cooldownMinutes: Int = 30,
        lastTriggered: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.metric = metric
        self.condition = condition
        self.threshold = threshold
        self.cooldownMinutes = cooldownMinutes
        self.lastTriggered = lastTriggered
    }

    /// Check if this rule is currently in cooldown
    public var isInCooldown: Bool {
        guard let lastTriggered = lastTriggered else { return false }
        return Date().timeIntervalSince(lastTriggered) < TimeInterval(cooldownMinutes * 60)
    }

    /// Default preset rules
    public static let presetRules: [NotificationRule] = [
        NotificationRule(
            name: "High CPU Usage",
            metric: .cpuUsage,
            condition: .greaterThan,
            threshold: 80,
            cooldownMinutes: 15
        ),
        NotificationRule(
            name: "Low Disk Space",
            metric: .diskSpace,
            condition: .lessThan,
            threshold: 10,
            cooldownMinutes: 60
        ),
        NotificationRule(
            name: "Critical Memory Pressure",
            metric: .memoryPressure,
            condition: .greaterThan,
            threshold: 1, // critical level
            cooldownMinutes: 15
        )
    ]
}

// MARK: - Metric Type

/// System metrics that can trigger notifications
public enum MetricType: String, CaseIterable, Codable, Sendable {
    case cpuUsage = "cpuUsage"
    case memoryPressure = "memoryPressure"
    case diskSpace = "diskSpace"
    case networkDown = "networkDown"
    case weatherTemp = "weatherTemp"

    public var displayName: String {
        switch self {
        case .cpuUsage: return "CPU Usage"
        case .memoryPressure: return "Memory Pressure"
        case .diskSpace: return "Disk Space"
        case .networkDown: return "Network Disconnect"
        case .weatherTemp: return "Weather Temperature"
        }
    }

    public var icon: String {
        switch self {
        case .cpuUsage: return "cpu"
        case .memoryPressure: return "memorychip"
        case .diskSpace: return "internaldrive"
        case .networkDown: return "wifi.slash"
        case .weatherTemp: return "thermometer"
        }
    }

    /// Unit for display
    public var unit: String {
        switch self {
        case .cpuUsage, .diskSpace: return "%"
        case .memoryPressure: return ""
        case .networkDown: return ""
        case .weatherTemp: return "°"
        }
    }

    /// Minimum threshold value
    public var minThreshold: Double {
        switch self {
        case .cpuUsage, .diskSpace: return 0
        case .memoryPressure: return 0
        case .networkDown: return 0
        case .weatherTemp: return -20
        }
    }

    /// Maximum threshold value
    public var maxThreshold: Double {
        switch self {
        case .cpuUsage, .diskSpace: return 100
        case .memoryPressure: return 2
        case .networkDown: return 1
        case .weatherTemp: return 50
        }
    }

    /// Step size for slider
    public var step: Double {
        switch self {
        case .cpuUsage, .diskSpace: return 5
        case .memoryPressure: return 1
        case .networkDown: return 1
        case .weatherTemp: return 1
        }
    }
}

// MARK: - Condition

/// Comparison condition for rule evaluation
public enum Condition: String, CaseIterable, Codable, Sendable {
    case greaterThan = "greaterThan"
    case lessThan = "lessThan"
    case equals = "equals"

    public var displayName: String {
        switch self {
        case .greaterThan: return "greater than"
        case .lessThan: return "less than"
        case .equals: return "equals"
        }
    }

    public var symbol: String {
        switch self {
        case .greaterThan: return ">"
        case .lessThan: return "<"
        case .equals: return "="
        }
    }

    /// Evaluate if the condition is met
    public func evaluate(value: Double, threshold: Double) -> Bool {
        switch self {
        case .greaterThan: return value > threshold
        case .lessThan: return value < threshold
        case .equals: return abs(value - threshold) < 0.01
        }
    }
}

// MARK: - Rule Trigger History

/// History of rule triggers for logging
public struct RuleTrigger: Identifiable, Codable, Sendable {
    public let id = UUID()
    public let ruleId: UUID
    public let ruleName: String
    public let triggeredAt: Date
    public let value: Double
    public let threshold: Double

    public init(ruleId: UUID, ruleName: String, triggeredAt: Date = Date(), value: Double, threshold: Double) {
        self.ruleId = ruleId
        self.ruleName = ruleName
        self.triggeredAt = triggeredAt
        self.value = value
        self.threshold = threshold
    }
}
