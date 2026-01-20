//
//  SparkleUpdater.swift
//  Tonic
//
//  Sparkle auto-update integration
//

import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

/// Sparkle updater manager
@Observable
public final class SparkleUpdater: @unchecked Sendable {

    public static let shared = SparkleUpdater()

    #if canImport(Sparkle)
    private let updaterController: SPUStandardUpdaterController
    #endif

    public private(set) var canCheckForUpdates = false
    public private(set) var updateInProgress = false

    private init() {
        #if canImport(Sparkle)
        // Initialize Sparkle updater controller
        updaterController = SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
        canCheckForUpdates = true
        #else
        canCheckForUpdates = false
        #endif
    }

    // MARK: - Public API

    /// Check for updates manually
    public func checkForUpdates() {
        #if canImport(Sparkle)
        updaterController.updater.checkForUpdates()
        #endif
    }

    /// Check for updates in background
    public func checkForUpdatesInBackground() {
        #if canImport(Sparkle)
        updaterController.updater.checkForUpdatesInBackground()
        #endif
    }
}
