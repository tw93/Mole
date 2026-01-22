//
//  WidgetHistoryStore.swift
//  Tonic
//
//  Widget graph history persistence
//  Task ID: fn-2.13
//

import Foundation
import AppKit

/// Stores graph history data for widgets with 1-week persistence
@MainActor
@Observable
public final class WidgetHistoryStore {

    public static let shared = WidgetHistoryStore()

    // MARK: - Constants

    private let maxHistoryPoints = 60
    private let persistenceDuration: TimeInterval = 7 * 24 * 60 * 60 // 1 week

    // MARK: - History Storage

    /// CPU history (60 points of usage percentages)
    public private(set) var cpuHistory: [Double] = []

    /// Memory history (60 points of usage percentages)
    public private(set) var memoryHistory: [Double] = []

    /// Network upload history (60 points of KB/s)
    public private(set) var networkUploadHistory: [Double] = []

    /// Network download history (60 points of KB/s)
    public private(set) var networkDownloadHistory: [Double] = []

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let cpuHistory = "tonic.history.cpu"
        static let memoryHistory = "tonic.history.memory"
        static let networkUploadHistory = "tonic.history.networkUpload"
        static let networkDownloadHistory = "tonic.history.networkDownload"
        static let lastSaveTime = "tonic.history.lastSave"
    }

    // MARK: - Auto-Save

    /// Timer for periodic history saving (every 5 minutes)
    nonisolated(unsafe) private var autoSaveTimer: Timer?

    /// Interval for auto-save (5 minutes)
    private let autoSaveInterval: TimeInterval = 5 * 60

    // MARK: - Initialization

    private init() {
        loadHistory()
        cleanupOldHistory()
        setupAutoSave()
        setupAppLifecycleObservers()
    }

    // MARK: - Auto-Save Setup

    private func setupAutoSave() {
        // Schedule periodic auto-save every 5 minutes
        autoSaveTimer = Timer.scheduledTimer(withTimeInterval: autoSaveInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.saveHistory()
            }
        }
    }

    private func setupAppLifecycleObservers() {
        // Listen for app termination to save history
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillTerminate),
            name: NSApplication.willTerminateNotification,
            object: nil
        )

        // Also save when app goes to background (for sleep/lock)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationWillResignActive),
            name: NSApplication.willResignActiveNotification,
            object: nil
        )
    }

    @objc private func applicationWillTerminate() {
        saveHistory()
        autoSaveTimer?.invalidate()
    }

    @objc private func applicationWillResignActive() {
        saveHistory()
    }

    deinit {
        // Timer needs to be invalidated outside of MainActor context
        autoSaveTimer?.invalidate()
        NotificationCenter.default.removeObserver(self)
    }

    // MARK: - Public Methods

    /// Add a value to CPU history
    public func addCPUValue(_ value: Double) {
        addToHistory(&cpuHistory, value: value)
    }

    /// Add a value to memory history
    public func addMemoryValue(_ value: Double) {
        addToHistory(&memoryHistory, value: value)
    }

    /// Add network upload value (in bytes/sec)
    public func addNetworkUploadValue(_ bytesPerSecond: Double) {
        let kbPerSecond = bytesPerSecond / 1024
        addToHistory(&networkUploadHistory, value: kbPerSecond)
    }

    /// Add network download value (in bytes/sec)
    public func addNetworkDownloadValue(_ bytesPerSecond: Double) {
        let kbPerSecond = bytesPerSecond / 1024
        addToHistory(&networkDownloadHistory, value: kbPerSecond)
    }

    /// Save all history to disk
    public func saveHistory() {
        UserDefaults.standard.set(cpuHistory, forKey: Keys.cpuHistory)
        UserDefaults.standard.set(memoryHistory, forKey: Keys.memoryHistory)
        UserDefaults.standard.set(networkUploadHistory, forKey: Keys.networkUploadHistory)
        UserDefaults.standard.set(networkDownloadHistory, forKey: Keys.networkDownloadHistory)
        UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: Keys.lastSaveTime)
    }

    /// Clear all history
    public func clearHistory() {
        cpuHistory = []
        memoryHistory = []
        networkUploadHistory = []
        networkDownloadHistory = []
        saveHistory()
    }

    // MARK: - Private Methods

    private func addToHistory(_ array: inout [Double], value: Double) {
        array.append(value)
        if array.count > maxHistoryPoints {
            array.removeFirst()
        }
    }

    private func loadHistory() {
        cpuHistory = UserDefaults.standard.array(forKey: Keys.cpuHistory) as? [Double] ?? []
        memoryHistory = UserDefaults.standard.array(forKey: Keys.memoryHistory) as? [Double] ?? []
        networkUploadHistory = UserDefaults.standard.array(forKey: Keys.networkUploadHistory) as? [Double] ?? []
        networkDownloadHistory = UserDefaults.standard.array(forKey: Keys.networkDownloadHistory) as? [Double] ?? []
    }

    /// Remove history older than 1 week
    private func cleanupOldHistory() {
        guard let lastSaveTimestamp = UserDefaults.standard.object(forKey: Keys.lastSaveTime) as? TimeInterval else {
            return
        }

        let lastSaveDate = Date(timeIntervalSince1970: lastSaveTimestamp)
        let elapsed = Date().timeIntervalSince(lastSaveDate)

        if elapsed > persistenceDuration {
            clearHistory()
        }
    }
}
