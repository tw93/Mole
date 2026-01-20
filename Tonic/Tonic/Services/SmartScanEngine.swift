//
//  SmartScanEngine.swift
//  Tonic
//
//  Core scanning engine for Smart Scan feature
//  Task ID: fn-1.17
//

import Foundation
import OSLog

// MARK: - Smart Scan Engine

@Observable
final class SmartScanEngine: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.tonic.app", category: "SmartScan")
    private let diskScanner = DiskScanner()
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private var _currentStage: ScanStage = .preparing
    private var _scanData: ScanData = .init()

    var currentStage: ScanStage {
        get { lock.locked { _currentStage } }
        set { lock.locked { _currentStage = newValue } }
    }

    private struct ScanData {
        var diskUsage: DiskUsageSummary?
        var recommendations: [ScanRecommendation] = []
        var stageProgress: Double = 0
    }

    // MARK: - Stage Execution

    func runStage(_ stage: ScanStage) async -> Double {
        currentStage = stage

        var accumulatedProgress = 0.0

        switch stage {
        case .preparing:
            accumulatedProgress = await runPreparationStage()

        case .scanningDisk:
            accumulatedProgress = await runDiskScanStage()

        case .checkingApps:
            accumulatedProgress = await runAppCheckStage()

        case .analyzingSystem:
            accumulatedProgress = await runSystemAnalysisStage()

        case .complete:
            break
        }

        return min(accumulatedProgress, 0.95)
    }

    // MARK: - Preparation Stage

    private func runPreparationStage() async -> Double {
        logger.info("Running preparation stage")

        // Initialize scan data
        lock.locked { _scanData = ScanData() }

        // Get total disk space
        if let totalSpace = getTotalDiskSpace() {
            _scanData.diskUsage = DiskUsageSummary(
                totalSpace: totalSpace.total,
                usedSpace: totalSpace.used,
                freeSpace: totalSpace.free,
                homeDirectorySize: 0,
                cacheSize: 0,
                logSize: 0,
                tempSize: 0
            )
        }

        return ScanStage.preparing.progressWeight
    }

    // MARK: - Disk Scan Stage

    private func runDiskScanStage() async -> Double {
        logger.info("Running disk scan stage")

        let homePath = fileManager.homeDirectoryForCurrentUser.path
        var cacheSize: Int64 = 0
        var logSize: Int64 = 0
        var tempSize: Int64 = 0

        // Scan cache directories
        let cachePaths = getCacheDirectories()
        for path in cachePaths {
            let size = await measureDirectorySize(path)
            cacheSize += size
        }

        // Scan log directories
        let logPaths = getLogDirectories()
        for path in logPaths {
            let size = await measureDirectorySize(path)
            logSize += size
        }

        // Scan temp directories
        let tempPaths = getTempDirectories()
        for path in tempPaths {
            let size = await measureDirectorySize(path)
            tempSize += size
        }

        // Scan home directory
        let homeSize = await measureDirectorySize(homePath)

        // Update disk usage
        if var existing = _scanData.diskUsage {
            _scanData.diskUsage = DiskUsageSummary(
                totalSpace: existing.totalSpace,
                usedSpace: existing.usedSpace,
                freeSpace: existing.freeSpace,
                homeDirectorySize: homeSize,
                cacheSize: cacheSize,
                logSize: logSize,
                tempSize: tempSize
            )
        }

        // Add recommendations
        addRecommendationsForCache(cacheSize)
        addRecommendationsForLogs(logSize)
        addRecommendationsForTemp(tempSize)

        let baseProgress = ScanStage.preparing.progressWeight
        return baseProgress + ScanStage.scanningDisk.progressWeight
    }

    // MARK: - App Check Stage

    private func runAppCheckStage() async -> Double {
        logger.info("Running app check stage")

        // Check for unused apps
        await checkUnusedApps()

        // Check for old app versions
        await checkOldAppVersions()

        // Check for app support debris
        await checkAppSupportDebris()

        let baseProgress = ScanStage.preparing.progressWeight + ScanStage.scanningDisk.progressWeight
        return baseProgress + ScanStage.checkingApps.progressWeight
    }

    // MARK: - System Analysis Stage

    private func runSystemAnalysisStage() async -> Double {
        logger.info("Running system analysis stage")

        // Check for hidden space (symlinked directories, etc.)
        await checkHiddenSpace()

        // Check for large files
        await checkLargeFiles()

        // Check for development artifacts
        await checkDevelopmentArtifacts()

        // Analyze overall system health
        calculateSystemHealthScore()

        let baseProgress = ScanStage.preparing.progressWeight +
                          ScanStage.scanningDisk.progressWeight +
                          ScanStage.checkingApps.progressWeight
        return baseProgress + ScanStage.analyzingSystem.progressWeight
    }

    // MARK: - Finalize Scan

    func finalizeScan() async -> SmartScanResult {
        let startTime = Date()

        let recommendations = lock.locked { _scanData.recommendations }
        let diskUsage = lock.locked { _scanData.diskUsage }

        let totalSpace = recommendations.reduce(0) { $0 + $1.spaceToReclaim }
        let healthScore = calculateHealthScore(diskUsage: diskUsage, recommendations: recommendations)

        let duration = Date().timeIntervalSince(startTime)

        logger.info("Scan completed in \(duration)s with \(recommendations.count) recommendations")

        return SmartScanResult(
            timestamp: Date(),
            scanDuration: duration,
            diskUsage: diskUsage ?? createDefaultDiskUsage(),
            recommendations: recommendations,
            totalSpaceToReclaim: totalSpace,
            systemHealthScore: healthScore
        )
    }

    // MARK: - Fix Actions

    func fixRecommendations(_ recommendations: [ScanRecommendation]) async -> FixResult {
        logger.info("Fixing \(recommendations.count) recommendations")

        var itemsFixed = 0
        var spaceFreed: Int64 = 0
        var errors = 0
        let fileOps = FileOperations.shared

        for recommendation in recommendations where recommendation.safeToFix {
            for path in recommendation.affectedPaths {
                do {
                    // Get size before deletion
                    let attrs = try? fileManager.attributesOfItem(atPath: path)
                    let size = (attrs?[.size] as? Int64) ?? 0

                    // Delete using FileOperations
                    let result = await fileOps.deleteFiles(atPaths: [path])

                    if result.success {
                        itemsFixed += result.filesProcessed
                        spaceFreed += size
                    } else {
                        errors += result.errors.count
                    }
                } catch {
                    errors += 1
                    logger.error("Error deleting \(path): \(error.localizedDescription)")
                }
            }
        }

        return FixResult(itemsFixed: itemsFixed, spaceFreed: spaceFreed, errors: errors)
    }

    // MARK: - Helper Methods

    private func getTotalDiskSpace() -> (total: Int64, used: Int64, free: Int64)? {
        guard let attrs = try? fileManager.attributesOfFileSystem(forPath: "/") else {
            return nil
        }

        let total = (attrs[.systemSize] as? UInt64) ?? 0
        let free = (attrs[.systemFreeSize] as? UInt64) ?? 0

        return (Int64(total), Int64(total - free), Int64(free))
    }

    private func getCacheDirectories() -> [String] {
        var paths: [String] = []

        let home = fileManager.homeDirectoryForCurrentUser.path

        // User cache
        paths.append(home + "/Library/Caches")

        // Browser caches
        paths.append(home + "/Library/Caches/com.apple.Safari")
        paths.append(home + "/Library/Caches/Google/Chrome")
        paths.append(home + "/Library/Caches/Mozilla/Firefox")

        // Xcode cache
        paths.append(home + "/Library/Developer/Xcode/DerivedData")

        // CocoaPods cache
        paths.append(home + "/Library/Caches/CocoaPods")

        return paths.filter { fileManager.fileExists(atPath: $0) }
    }

    private func getLogDirectories() -> [String] {
        var paths: [String] = []

        let home = fileManager.homeDirectoryForCurrentUser.path

        // User logs
        paths.append(home + "/Library/Logs")

        // System logs (may not have access)
        paths.append("/Library/Logs")

        // Console logs
        paths.append(home + "/Library/Logs/DiagnosticReports")

        return paths.filter { fileManager.fileExists(atPath: $0) }
    }

    private func getTempDirectories() -> [String] {
        var paths: [String] = []

        // System temp
        if let tempDir = (NSTemporaryDirectory() as NSString).deletingLastPathComponent as String? {
            paths.append(tempDir)
        }

        // User temp
        let home = fileManager.homeDirectoryForCurrentUser.path
        paths.append(home + "/Library/Caches/temp")

        return paths.filter { fileManager.fileExists(atPath: $0) }
    }

    private func measureDirectorySize(_ path: String) async -> Int64 {
        var totalSize: Int64 = 0

        guard let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        for case let url as URL in enumerator {
            if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]) {
                totalSize += Int64(resourceValues.fileSize ?? 0)
            }
        }

        return totalSize
    }

    // MARK: - Recommendation Builders

    private func addRecommendationsForCache(_ size: Int64) {
        guard size > 50 * 1024 * 1024 else { return } // Only if > 50MB

        let home = fileManager.homeDirectoryForCurrentUser.path
        let paths = getCacheDirectories()

        let recommendation = ScanRecommendation(
            type: .cache,
            title: "Application Cache",
            description: "Cached data from applications. Safe to clear but may cause apps to rebuild cache.",
            actionable: true,
            safeToFix: true,
            spaceToReclaim: size,
            affectedPaths: paths
        )

        lock.locked { _scanData.recommendations.append(recommendation) }
    }

    private func addRecommendationsForLogs(_ size: Int64) {
        guard size > 10 * 1024 * 1024 else { return } // Only if > 10MB

        let paths = getLogDirectories()

        let recommendation = ScanRecommendation(
            type: .logs,
            title: "System & App Logs",
            description: "Log files from applications and the system. Old logs can be safely removed.",
            actionable: true,
            safeToFix: true,
            spaceToReclaim: size,
            affectedPaths: paths
        )

        lock.locked { _scanData.recommendations.append(recommendation) }
    }

    private func addRecommendationsForTemp(_ size: Int64) {
        guard size > 10 * 1024 * 1024 else { return } // Only if > 10MB

        let paths = getTempDirectories()

        let recommendation = ScanRecommendation(
            type: .tempFiles,
            title: "Temporary Files",
            description: "Temporary files created during app usage. Safe to delete.",
            actionable: true,
            safeToFix: true,
            spaceToReclaim: size,
            affectedPaths: paths
        )

        lock.locked { _scanData.recommendations.append(recommendation) }
    }

    // MARK: - App Checks

    private func checkUnusedApps() async {
        // This would integrate with AppInventoryView data
        // For now, we'll add a placeholder
    }

    private func checkOldAppVersions() async {
        // Check for duplicate app versions
        let appPaths = [
            "/Applications",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Applications"
        ]

        var foundApps: [String: [URL]] = [:]

        for appPath in appPaths {
            guard let apps = try? fileManager.contentsOfDirectory(
                at: URL(fileURLWithPath: appPath),
                includingPropertiesForKeys: nil
            ) else { continue }

            for app in apps where app.pathExtension == "app" {
                let appName = app.deletingPathExtension().lastPathComponent
                foundApps[appName, default: []].append(app)
            }
        }

        // Find duplicates
        for (appName, paths) in foundApps where paths.count > 1 {
            let totalSize = await paths.asyncReduce(0) { total, url in
                return total + (getFileSize(url.path) ?? 0)
            }

            let recommendation = ScanRecommendation(
                type: .oldApps,
                title: "Duplicate App: \(appName)",
                description: "Found \(paths.count) copies of this app. Consider removing old versions.",
                actionable: true,
                safeToFix: false, // Let user decide
                spaceToReclaim: totalSize,
                affectedPaths: paths.map { $0.path }
            )

            lock.locked { _scanData.recommendations.append(recommendation) }
        }
    }

    private func checkAppSupportDebris() async {
        let home = fileManager.homeDirectoryForCurrentUser.path
        let appSupportPath = home + "/Library/Application Support"

        guard let contents = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: appSupportPath),
            includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }

        var debrisPaths: [String] = []
        var debrisSize: Int64 = 0

        for item in contents {
            let path = item.path
            let appName = (path as NSString).lastPathComponent

            // Check if corresponding app exists
            let appExists = isAppInstalled(appName)

            if !appExists {
                if let size = await measureDirectorySize(path) as Int64?, size > 5 * 1024 * 1024 {
                    debrisPaths.append(path)
                    debrisSize += size
                }
            }
        }

        if !debrisPaths.isEmpty {
            let recommendation = ScanRecommendation(
                type: .oldApps,
                title: "Orphaned App Support Files",
                description: "Found \(debrisPaths.count) app support directories for uninstalled apps.",
                actionable: true,
                safeToFix: true,
                spaceToReclaim: debrisSize,
                affectedPaths: debrisPaths
            )

            lock.locked { _scanData.recommendations.append(recommendation) }
        }
    }

    // MARK: - System Analysis

    private func checkHiddenSpace() async {
        // Check for common hidden space hogs
        let home = fileManager.homeDirectoryForCurrentUser.path
        var hiddenItems: [(path: String, size: Int64)] = []

        let hiddenPathsToCheck = [
            home + "/.Trash",
            home + "/npm",
            home + "/.npm",
            home + "/.gradle",
            home + "/.cargo",
            home + "/.rustup",
            home + "/.docker"
        ]

        for path in hiddenPathsToCheck where fileManager.fileExists(atPath: path) {
            let size = await measureDirectorySize(path)
            if size > 10 * 1024 * 1024 { // > 10MB
                hiddenItems.append((path, size))
            }
        }

        if !hiddenItems.isEmpty {
            let totalSize = hiddenItems.reduce(0) { $0 + $1.size }
            let paths = hiddenItems.map { $0.path }

            let recommendation = ScanRecommendation(
                type: .hiddenSpace,
                title: "Hidden Development Caches",
                description: "Found \(hiddenItems.count) hidden directories taking up space.",
                actionable: true,
                safeToFix: false, // Require user review
                spaceToReclaim: totalSize,
                affectedPaths: paths
            )

            lock.locked { _scanData.recommendations.append(recommendation) }
        }
    }

    private func checkLargeFiles() async {
        // This uses the disk scanner's large file detection
        // Results would be incorporated into recommendations
    }

    private func checkDevelopmentArtifacts() async {
        let home = fileManager.homeDirectoryForCurrentUser.path
        var artifactPaths: [String] = []
        var artifactSize: Int64 = 0

        // Check for common build directories
        let buildPatterns = [
            "build",
            "dist",
            ".build",
            "target",
            "node_modules",
            ".venv",
            "venv"
        ]

        // Search in home directory
        if let enumerator = fileManager.enumerator(
            at: URL(fileURLWithPath: home),
            includingPropertiesForKeys: [.isDirectoryKey, .nameKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let url as URL in enumerator {
                let name = url.lastPathComponent

                if buildPatterns.contains(name) {
                    let size = await measureDirectorySize(url.path)
                    if size > 50 * 1024 * 1024 { // > 50MB
                        artifactPaths.append(url.path)
                        artifactSize += size
                        enumerator.skipDescendants()
                    }
                }
            }
        }

        if !artifactPaths.isEmpty {
            let recommendation = ScanRecommendation(
                type: .hiddenSpace,
                title: "Build Artifacts",
                description: "Found \(artifactPaths.count) build directories that can be cleaned.",
                actionable: true,
                safeToFix: false,
                spaceToReclaim: artifactSize,
                affectedPaths: artifactPaths
            )

            lock.locked { _scanData.recommendations.append(recommendation) }
        }
    }

    // MARK: - Health Score

    private func calculateSystemHealthScore() {
        // Score is calculated in finalizeScan
    }

    private func calculateHealthScore(diskUsage: DiskUsageSummary?, recommendations: [ScanRecommendation]) -> Int {
        var score = 100

        // Deduct for disk usage
        if let usage = diskUsage {
            let usedPercent = usage.usedPercentage

            if usedPercent > 95 {
                score -= 30
            } else if usedPercent > 90 {
                score -= 20
            } else if usedPercent > 80 {
                score -= 10
            }
        }

        // Deduct for cache size
        let cacheRecommendations = recommendations.filter { $0.type == .cache }
        let totalCache = cacheRecommendations.reduce(0) { $0 + $1.spaceToReclaim }
        if totalCache > 5 * 1024 * 1024 * 1024 { // > 5GB
            score -= 15
        } else if totalCache > 1 * 1024 * 1024 * 1024 { // > 1GB
            score -= 5
        }

        // Deduct for orphaned files
        let orphanedCount = recommendations.filter {
            $0.type == .oldApps || $0.type == .tempFiles
        }.count

        score -= min(orphanedCount * 2, 10)

        return max(score, 0)
    }

    private func createDefaultDiskUsage() -> DiskUsageSummary {
        return DiskUsageSummary(
            totalSpace: 512 * 1024 * 1024 * 1024,
            usedSpace: 256 * 1024 * 1024 * 1024,
            freeSpace: 256 * 1024 * 1024 * 1024,
            homeDirectorySize: 100 * 1024 * 1024 * 1024,
            cacheSize: 0,
            logSize: 0,
            tempSize: 0
        )
    }

    // MARK: - Utilities

    private func isAppInstalled(_ appName: String) -> Bool {
        let appPaths = [
            "/Applications/\(appName).app",
            FileManager.default.homeDirectoryForCurrentUser.path + "/Applications/\(appName).app"
        ]
        return appPaths.contains { fileManager.fileExists(atPath: $0) }
    }

    private func getFileSize(_ path: String) -> Int64? {
        return (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? nil
    }
}

// MARK: - Async Reduce Extension

extension Sequence {
    func asyncReduce<Result>(
        _ initialResult: Result,
        _ updateAccumulatingResult: (Result, Element) async -> Result
    ) async -> Result {
        var result = initialResult
        for element in self {
            result = await updateAccumulatingResult(result, element)
        }
        return result
    }
}
