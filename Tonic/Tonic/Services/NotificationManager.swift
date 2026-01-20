//
//  NotificationManager.swift
//  Tonic
//
//  Smart notifications system
//  Task ID: fn-1.27
//

import Foundation
import UserNotifications

/// Notification categories
public enum NotificationCategory: String, CaseIterable, Identifiable {
    case scanComplete = "Scan Complete"
    case cleanComplete = "Clean Complete"
    case lowDiskSpace = "Low Disk Space"
    case highResourceUsage = "High Resource Usage"
    case updateAvailable = "Update Available"
    case weeklySummary = "Weekly Summary"
    case tip = "Tip"

    public var id: String { rawValue }

    var identifier: String {
        "com.tonicapp.\(rawValue.replacingOccurrences(of: " ", with: "").lowercased())"
    }
}

/// Notification priority
public enum NotificationPriority: String {
    case low = "low"
    case normal = "normal"
    case high = "high"
}

/// Smart notification configuration
public struct NotificationConfig: Sendable {
    let category: NotificationCategory
    let title: String
    let body: String
    let priority: NotificationPriority
    let actionable: Bool
    let scheduleDate: Date?

    init(category: NotificationCategory, title: String, body: String, priority: NotificationPriority = .normal, actionable: Bool = false, scheduleDate: Date? = nil) {
        self.category = category
        self.title = title
        self.body = body
        self.priority = priority
        self.actionable = actionable
        self.scheduleDate = scheduleDate
    }
}

/// Notification preferences
public struct NotificationPreferences: Codable, Sendable {
    var scanComplete: Bool = true
    var cleanComplete: Bool = true
    var lowDiskSpace: Bool = true
    var diskThreshold: Int = 10 // Percentage
    var highResourceUsage: Bool = false
    var updateAvailable: Bool = true
    var weeklySummary: Bool = true
    var tips: Bool = true
    var quietHoursEnabled: Bool = false
    var quietHoursStart: Date = Calendar.current.date(bySettingHour: 22, minute: 0, second: 0, of: Date()) ?? Date()
    var quietHoursEnd: Date = Calendar.current.date(bySettingHour: 8, minute: 0, second: 0, of: Date()) ?? Date()

    static let shared = NotificationPreferences()
}

/// Smart notifications manager
@Observable
public final class NotificationManager: NSObject, @unchecked Sendable {

    public static let shared = NotificationManager()

    private let center = UNUserNotificationCenter.current()
    public var preferences = NotificationPreferences.shared

    private var isQuietHours: Bool {
        guard preferences.quietHoursEnabled else { return false }

        let calendar = Calendar.current
        let now = Date()
        let currentHour = calendar.component(.hour, from: now)

        let startHour = calendar.component(.hour, from: preferences.quietHoursStart)
        let endHour = calendar.component(.hour, from: preferences.quietHoursEnd)

        if startHour < endHour {
            return currentHour >= startHour && currentHour < endHour
        } else {
            // Overnight quiet period (e.g., 10 PM to 8 AM)
            return currentHour >= startHour || currentHour < endHour
        }
    }

    private override init() {
        super.init()
        setupCategories()
    }

    // MARK: - Setup

    public func requestAuthorization() async -> Bool {
        do {
            let granted = try await center.requestAuthorization(options: [.alert, .sound, .badge])
            if granted {
                setupCategories()
            }
            return granted
        } catch {
            return false
        }
    }

    private func setupCategories() {
        let scanComplete = UNNotificationCategory(
            identifier: NotificationCategory.scanComplete.identifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        let cleanComplete = UNNotificationCategory(
            identifier: NotificationCategory.cleanComplete.identifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        let lowDiskSpace = UNNotificationCategory(
            identifier: NotificationCategory.lowDiskSpace.identifier,
            actions: [],
            intentIdentifiers: [],
            options: .customDismissAction
        )

        let updateAvailable = UNNotificationCategory(
            identifier: NotificationCategory.updateAvailable.identifier,
            actions: [],
            intentIdentifiers: [],
            options: []
        )

        center.setNotificationCategories([scanComplete, cleanComplete, lowDiskSpace, updateAvailable])
    }

    // MARK: - Sending Notifications

    public func send(_ config: NotificationConfig) async {
        // Check if notifications are enabled for this category
        guard isEnabled(for: config.category) else { return }

        // Check quiet hours
        guard !isQuietHours || config.priority == .high else { return }

        let content = UNMutableNotificationContent()
        content.title = config.title
        content.body = config.body
        content.sound = config.priority == .high ? .default : .none
        content.categoryIdentifier = config.category.identifier

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: config.scheduleDate.map { date in
                UNTimeIntervalNotificationTrigger(timeInterval: date.timeIntervalSinceNow, repeats: false)
            } ?? nil
        )

        do {
            try await center.add(request)
        } catch {
            // Silently fail
        }
    }

    // MARK: - Category-Specific Notifications

    public func notifyScanComplete(itemsFound: Int, spaceToReclaim: Int64) async {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file

        let config = NotificationConfig(
            category: .scanComplete,
            title: "Scan Complete",
            body: "Found \(itemsFound) items taking up \(formatter.string(fromByteCount: spaceToReclaim)). Ready to clean!",
            priority: .normal
        )

        await send(config)
    }

    public func notifyCleanComplete(spaceFreed: Int64) async {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file

        let config = NotificationConfig(
            category: .cleanComplete,
            title: "Clean Complete",
            body: "Freed up \(formatter.string(fromByteCount: spaceFreed)) of disk space.",
            priority: .normal
        )

        await send(config)
    }

    public func notifyLowDiskSpace(percentageUsed: Int) async {
        guard percentageUsed >= (100 - preferences.diskThreshold) else { return }

        let config = NotificationConfig(
            category: .lowDiskSpace,
            title: "Low Disk Space",
            body: "Your disk is \(percentageUsed)% full. Consider cleaning up unnecessary files.",
            priority: .high
        )

        await send(config)
    }

    public func notifyHighResourceUsage(cpu: Int?, memory: Int?) async {
        guard preferences.highResourceUsage else { return }

        var messages: [String] = []
        if let cpu, cpu > 80 {
            messages.append("CPU usage is at \(cpu)%")
        }
        if let memory, memory > 90 {
            messages.append("Memory usage is at \(memory)%")
        }

        guard !messages.isEmpty else { return }

        let config = NotificationConfig(
            category: .highResourceUsage,
            title: "High Resource Usage",
            body: messages.joined(separator: ". "),
            priority: .normal
        )

        await send(config)
    }

    public func notifyUpdateAvailable(version: String) async {
        let config = NotificationConfig(
            category: .updateAvailable,
            title: "Update Available",
            body: "Tonic \(version) is ready to install.",
            priority: .normal
        )

        await send(config)
    }

    public func notifyWeeklySummary(itemsCleaned: Int, spaceFreed: Int64) async {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file

        let config = NotificationConfig(
            category: .weeklySummary,
            title: "Weekly Summary",
            body: "This week: Cleaned \(itemsCleaned) items and freed \(formatter.string(fromByteCount: spaceFreed)).",
            priority: .low
        )

        await send(config)
    }

    // MARK: - Tips

    private let tips = [
        "Tip: Empty your trash regularly to free up disk space.",
        "Tip: Remove old iOS backups you no longer need.",
        "Tip: Clear browser cache to free up space and improve privacy.",
        "Tip: Uninstall apps you haven't used in the last 6 months.",
        "Tip: Remove old downloads from your Downloads folder.",
        "Tip: Clean Xcode derived data if you're a developer.",
        "Tip: Remove Docker images and containers you no longer use.",
        "Tip: Empty mail downloads and attachments.",
        "Tip: Remove duplicate files using Tonic's duplicate finder.",
        "Tip: Check for large files in your hidden space folder."
    ]

    public func sendRandomTip() async {
        guard preferences.tips else { return }

        let randomTip = tips.randomElement() ?? tips[0]

        let config = NotificationConfig(
            category: .tip,
            title: "Tonic Tip",
            body: randomTip,
            priority: .low
        )

        await send(config)
    }

    // MARK: - Helpers

    private func isEnabled(for category: NotificationCategory) -> Bool {
        switch category {
        case .scanComplete: return preferences.scanComplete
        case .cleanComplete: return preferences.cleanComplete
        case .lowDiskSpace: return preferences.lowDiskSpace
        case .highResourceUsage: return preferences.highResourceUsage
        case .updateAvailable: return preferences.updateAvailable
        case .weeklySummary: return preferences.weeklySummary
        case .tip: return preferences.tips
        }
    }

    public func checkAuthorizationStatus() async -> UNAuthorizationStatus {
        let settings = await center.notificationSettings()
        return settings.authorizationStatus
    }

    public func removeAllDeliveredNotifications() {
        center.removeAllDeliveredNotifications()
    }

    public func getDeliveredNotificationCount() async -> Int {
        let notifications = await center.deliveredNotifications()
        return notifications.count
    }
}
