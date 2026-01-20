//
//  LicenseManager.swift
//  Tonic
//
//  Licensing and freemium logic
//  Task ID: fn-1.30
//

import Foundation
import StoreKit

/// License tier
public enum LicenseTier: String, CaseIterable, Identifiable {
    case free = "Free"
    case pro = "Pro"
    case lifetime = "Lifetime"

    public var id: String { rawValue }

    var name: String { rawValue }

    var features: [String] {
        switch self {
        case .free:
            return [
                "Basic disk scanning",
                "System dashboard",
                "App inventory",
                "Up to 500MB cleaning per month",
                "Basic optimization tools"
            ]
        case .pro:
            return [
                "All Free features",
                "Unlimited cleaning",
                "Deep clean all categories",
                "Smart scan recommendations",
                "App uninstaller",
                "System optimization",
                "Docker & VM cleanup",
                "Priority support"
            ]
        case .lifetime:
            return [
                "All Pro features",
                "Lifetime updates",
                "Early access to new features",
                "Priority support"
            ]
        }
    }

    var monthlyCleaningLimit: Int64? {
        switch self {
        case .free: return 500 * 1024 * 1024 // 500MB
        case .pro, .lifetime: return nil
        }
    }
}

/// Feature lock status
public struct FeatureLock: Sendable {
    let isLocked: Bool
    let tierRequired: LicenseTier
    let message: String

    static let unlocked = FeatureLock(isLocked: false, tierRequired: .free, message: "")
}

/// Product configuration for StoreKit
private struct ProductConfig {
    let id: String
    let tier: LicenseTier
}

/// License and subscription manager
@Observable
public final class LicenseManager: NSObject, @unchecked Sendable {

    public static let shared = LicenseManager()

    // MARK: - Published State

    public private(set) var currentTier: LicenseTier = .free
    public private(set) var isSubscribed = false
    public private(set) var subscriptionExpiry: Date?
    public private(set) var monthlyCleanedBytes: Int64 = 0
    public private(set) var monthlyResetDate: Date

    // MARK: - Store Configuration

    private let productConfigs: [ProductConfig] = [
        ProductConfig(id: "com.tonicapp.pro.monthly", tier: .pro),
        ProductConfig(id: "com.tonicapp.pro.yearly", tier: .pro),
        ProductConfig(id: "com.tonicapp.lifetime", tier: .lifetime)
    ]

    private var products: [String: Product] = [:]
    private var updateListenerTask: Task<Void, Error>?

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let tier = "tonic.license.tier"
        static let subscribed = "tonic.license.subscribed"
        static let expiry = "tonic.license.expiry"
        static let monthlyBytes = "tonic.license.monthlyBytes"
        static let resetDate = "tonic.license.resetDate"
    }

    // MARK: - Initialization

    private override init() {
        // Initialize properties with default values
        let savedTier = UserDefaults.standard.string(forKey: Keys.tier)
        let savedExpiry = UserDefaults.standard.object(forKey: Keys.expiry) as? Date
        let savedResetDate = UserDefaults.standard.object(forKey: Keys.resetDate) as? Date

        self.currentTier = LicenseTier(rawValue: savedTier ?? "") ?? .free
        self.isSubscribed = UserDefaults.standard.bool(forKey: Keys.subscribed)
        self.subscriptionExpiry = savedExpiry
        self.monthlyCleanedBytes = Int64(UserDefaults.standard.integer(forKey: Keys.monthlyBytes))
        self.monthlyResetDate = savedResetDate ?? Date().addingTimeInterval(30 * 24 * 60 * 60)

        super.init()

        checkSubscriptionStatus()

        // Start StoreKit listener
        updateListenerTask = listenForTransactions()
    }

    // MARK: - Store Setup

    public func loadProducts() async throws {
        // In a real app, these would be actual StoreKit product IDs
        // For now, we'll use mock configuration
        guard !products.isEmpty else { return }

        // This is a placeholder - in production, use:
        // let storeProducts = try await Product.products(for: productConfigs.map { $0.id })
        // for product in storeProducts { ... }
    }

    private func listenForTransactions() -> Task<Void, Error> {
        return Task.detached { [weak self] in
            // This would be the actual StoreKit transaction listener
            // For now, just keep the task alive
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_000_000_000)
            }
        }
    }

    // MARK: - Purchase Methods

    public func purchase(_ tier: LicenseTier) async throws {
        // In production, this would:
        // 1. Get the Product from StoreKit
        // 2. Call product.purchase()
        // 3. Verify the transaction
        // 4. Update local state

        // For demo purposes, we'll just update the tier
        currentTier = tier
        isSubscribed = true
        subscriptionExpiry = tier == .lifetime ? nil : Date().addingTimeInterval(30 * 24 * 60 * 60) // 30 days

        saveState()
    }

    public func restorePurchases() async throws {
        // In production, this would:
        // 1. Call AppStore.sync()
        // 2. Verify all past transactions
        // 3. Update local state based on valid purchases
    }

    public func checkSubscriptionStatus() {
        guard let expiry = subscriptionExpiry else { return }

        if expiry < Date() && currentTier != .lifetime {
            currentTier = .free
            isSubscribed = false
            subscriptionExpiry = nil
            saveState()
        }
    }

    // MARK: - Feature Locking

    public func canUseFeature(_ feature: Feature) -> FeatureLock {
        switch feature {
        case .basicScan, .systemDashboard, .appInventory:
            return .unlocked

        case .unlimitedCleaning:
            if currentTier == .free {
                return FeatureLock(
                    isLocked: true,
                    tierRequired: .pro,
                    message: "Upgrade to Pro for unlimited cleaning"
                )
            }
            return .unlocked

        case .deepClean:
            if currentTier == .free {
                return FeatureLock(
                    isLocked: true,
                    tierRequired: .pro,
                    message: "Deep clean requires Pro"
                )
            }
            return .unlocked

        case .smartScan:
            if currentTier == .free {
                return FeatureLock(
                    isLocked: true,
                    tierRequired: .pro,
                    message: "Smart scan recommendations require Pro"
                )
            }
            return .unlocked

        case .appUninstaller:
            if currentTier == .free {
                return FeatureLock(
                    isLocked: true,
                    tierRequired: .pro,
                    message: "App uninstaller requires Pro"
                )
            }
            return .unlocked

        case .systemOptimization:
            if currentTier == .free {
                return FeatureLock(
                    isLocked: true,
                    tierRequired: .pro,
                    message: "System optimization requires Pro"
                )
            }
            return .unlocked

        case .dockerCleanup:
            if currentTier == .free {
                return FeatureLock(
                    isLocked: true,
                    tierRequired: .pro,
                    message: "Docker & VM cleanup requires Pro"
                )
            }
            return .unlocked

        case .prioritySupport:
            if currentTier == .lifetime {
                return .unlocked
            }
            return FeatureLock(
                isLocked: true,
                tierRequired: .lifetime,
                message: "Priority support requires Lifetime"
            )
        }
    }

    // MARK: - Usage Tracking

    public func trackCleanedBytes(_ bytes: Int64) -> Bool {
        guard currentTier == .free else { return true }

        let remaining = (LicenseTier.free.monthlyCleaningLimit ?? 0) - monthlyCleanedBytes

        if bytes <= remaining {
            monthlyCleanedBytes += bytes
            saveState()
            return true
        }

        return false
    }

    public func remainingBytesThisMonth() -> Int64 {
        guard currentTier == .free else { return Int64.max }

        let limit = LicenseTier.free.monthlyCleaningLimit ?? 0
        return max(0, limit - monthlyCleanedBytes)
    }

    public func bytesUsedThisMonth() -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB]
        formatter.countStyle = .file

        if currentTier == .free {
            return formatter.string(fromByteCount: monthlyCleanedBytes)
        }
        return "Unlimited"
    }

    private func checkMonthlyReset() {
        let now = Date()

        if now > monthlyResetDate {
            monthlyCleanedBytes = 0
            monthlyResetDate = nextMonthReset()
            saveState()
        }
    }

    private func nextMonthReset() -> Date {
        let calendar = Calendar.current
        let now = Date()

        if let nextMonth = calendar.date(byAdding: .month, value: 1, to: now),
           let resetDate = calendar.date(bySettingHour: 0, minute: 0, second: 0, of: nextMonth) {
            return resetDate
        }

        return now.addingTimeInterval(30 * 24 * 60 * 60)
    }

    // MARK: - Persistence

    private func saveState() {
        UserDefaults.standard.set(currentTier.rawValue, forKey: Keys.tier)
        UserDefaults.standard.set(isSubscribed, forKey: Keys.subscribed)
        UserDefaults.standard.set(subscriptionExpiry, forKey: Keys.expiry)
        UserDefaults.standard.set(Int(monthlyCleanedBytes), forKey: Keys.monthlyBytes)
        UserDefaults.standard.set(monthlyResetDate, forKey: Keys.resetDate)
    }
}

/// Feature enumeration for locking
public enum Feature {
    case basicScan
    case systemDashboard
    case appInventory
    case unlimitedCleaning
    case deepClean
    case smartScan
    case appUninstaller
    case systemOptimization
    case dockerCleanup
    case prioritySupport
}
