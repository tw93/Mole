//
//  AppUpdater.swift
//  Tonic
//
//  Service for checking and managing app updates
//

import Foundation
import SwiftData

// MARK: - App Update Models

/// Represents an available update for an installed app
struct AppUpdate: Identifiable, Sendable, Codable {
    let id: UUID
    let bundleIdentifier: String
    let appName: String
    let currentVersion: String?
    let latestVersion: String
    let appPath: URL
    let updateAvailable: Bool
    let updateURL: URL?
    let releaseNotes: String?
    let lastChecked: Date

    public init(
        bundleIdentifier: String,
        appName: String,
        currentVersion: String?,
        latestVersion: String,
        appPath: URL,
        updateAvailable: Bool,
        updateURL: URL? = nil,
        releaseNotes: String? = nil,
        lastChecked: Date = Date()
    ) {
        self.id = UUID()
        self.bundleIdentifier = bundleIdentifier
        self.appName = appName
        self.currentVersion = currentVersion
        self.latestVersion = latestVersion
        self.appPath = appPath
        self.updateAvailable = updateAvailable
        self.updateURL = updateURL
        self.releaseNotes = releaseNotes
        self.lastChecked = lastChecked
    }

    /// Version comparison result
    public enum VersionComparison {
        case upToDate      // Current == Latest
        case updateAvailable // Current < Latest
        case beta          // Current > Latest (might be beta)
        case unknown       // Cannot compare
    }

    /// Compare two version strings
    static func compareVersions(_ current: String?, _ latest: String) -> VersionComparison {
        guard let current = current else {
            return .unknown
        }

        let currentComponents = parseVersion(current)
        let latestComponents = parseVersion(latest)

        // Pad the shorter array with zeros
        let maxLength = max(currentComponents.count, latestComponents.count)
        var paddedCurrent = currentComponents + [Int](repeating: 0, count: maxLength - currentComponents.count)
        var paddedLatest = latestComponents + [Int](repeating: 0, count: maxLength - latestComponents.count)

        for i in 0..<maxLength {
            if paddedCurrent[i] < paddedLatest[i] {
                return .updateAvailable
            } else if paddedCurrent[i] > paddedLatest[i] {
                return .beta
            }
        }

        return .upToDate
    }

    /// Parse semantic version string into components
    private static func parseVersion(_ version: String) -> [Int] {
        // Remove "v" prefix if present
        let cleaned = version.hasPrefix("v") ? String(version.dropFirst()) : version

        // Split by non-digit characters (., -, _, etc.)
        let components = cleaned.components(separatedBy: CharacterSet(charactersIn: "0123456789").inverted)

        return components.compactMap { Int($0) }
    }
}

/// Result of an update check operation
struct UpdateCheckResult: Sendable {
    let appsChecked: Int
    let updatesAvailable: Int
    let updates: [AppUpdate]
    let duration: TimeInterval
    let errors: [UpdateCheckError]

    var formattedDuration: String {
        String(format: "%.2fs", duration)
    }
}

/// Error during update checking
struct UpdateCheckError: Sendable, Error, LocalizedError {
    let bundleIdentifier: String
    let errorType: ErrorType
    let underlyingError: String?

    public enum ErrorType: String, Sendable {
        case noBundleFound = "App Not Found"
        case noVersionInfo = "No Version Info"
        case networkError = "Network Error"
        case parseError = "Parse Error"
        case unknown = "Unknown Error"
    }

    var errorDescription: String? {
        var description = "\(errorType.rawValue): \(bundleIdentifier)"
        if let underlying = underlyingError {
            description += " - \(underlying)"
        }
        return description
    }
}

// MARK: - App Update Checker Service

/// Service for checking app updates
@MainActor
@Observable
final class AppUpdater: @unchecked Sendable {

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let lock = NSLock()

    private var _updates: [AppUpdate] = []
    private var _isChecking = false
    private var _lastCheckDate: Date?

    var updates: [AppUpdate] {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _updates
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _updates = newValue
        }
    }

    var isChecking: Bool {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _isChecking
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _isChecking = newValue
        }
    }

    var lastCheckDate: Date? {
        get {
            lock.lock()
            defer { lock.unlock() }
            return _lastCheckDate
        }
        set {
            lock.lock()
            defer { lock.unlock() }
            _lastCheckDate = newValue
        }
    }

    /// Apps that have updates available
    var availableUpdates: [AppUpdate] {
        updates.filter { $0.updateAvailable }
    }

    /// Count of available updates
    var updateCount: Int {
        availableUpdates.count
    }

    // MARK: - Singleton

    static let shared = AppUpdater()

    private init() {}

    // MARK: - Update Checking

    /// Check for updates for a specific app
    /// - Parameters:
    ///   - bundleIdentifier: The app's bundle identifier
    ///   - currentVersion: The current installed version
    ///   - appPath: Path to the app bundle
    /// - Returns: AppUpdate if information is available
    func checkUpdate(for bundleIdentifier: String, currentVersion: String?, appPath: URL) async -> AppUpdate? {
        // Try multiple methods to get update information
        if let update = await checkViaSparkleFramework(appPath: appPath, bundleIdentifier: bundleIdentifier, currentVersion: currentVersion) {
            return update
        }

        if let update = await checkViaAppStore(bundleIdentifier: bundleIdentifier, currentVersion: currentVersion, appPath: appPath) {
            return update
        }

        // Fallback: create update record with current version
        return AppUpdate(
            bundleIdentifier: bundleIdentifier,
            appName: appPath.deletingPathExtension().lastPathComponent,
            currentVersion: currentVersion,
            latestVersion: currentVersion ?? "Unknown",
            appPath: appPath,
            updateAvailable: false
        )
    }

    /// Check for updates for multiple apps
    /// - Parameter apps: Array of app metadata to check
    /// - Returns: UpdateCheckResult with all updates found
    func checkUpdates(for apps: [AppMetadata]) async -> UpdateCheckResult {
        let startTime = Date()
        isChecking = true
        var allUpdates: [AppUpdate] = []
        var errors: [UpdateCheckError] = []

        // Check updates in batches to limit concurrent operations
        let batchSize = 5
        var index = 0

        while index < apps.count {
            let batch = Array(apps[index..<min(index + batchSize, apps.count)])
            index += batchSize

            await withTaskGroup(of: (AppUpdate?, UpdateCheckError?).self) { group in
                for app in batch {
                    group.addTask {
                        do {
                            if let update = await self.checkUpdate(
                                for: app.bundleIdentifier,
                                currentVersion: app.version,
                                appPath: app.path
                            ) {
                                return (update, nil)
                            }
                            return (nil, UpdateCheckError(
                                bundleIdentifier: app.bundleIdentifier,
                                errorType: .noVersionInfo,
                                underlyingError: nil
                            ))
                        } catch {
                            return (nil, UpdateCheckError(
                                bundleIdentifier: app.bundleIdentifier,
                                errorType: .unknown,
                                underlyingError: error.localizedDescription
                            ))
                        }
                    }

                    for await (update, error) in group {
                        if let update = update {
                            allUpdates.append(update)
                        }
                        if let error = error {
                            errors.append(error)
                        }
                    }
                }
            }
        }

        // Sort updates by app name
        allUpdates.sort { $0.appName.localizedCompare($1.appName) == .orderedAscending }

        updates = allUpdates
        lastCheckDate = Date()
        isChecking = false

        let availableCount = allUpdates.filter { $0.updateAvailable }.count

        return UpdateCheckResult(
            appsChecked: apps.count,
            updatesAvailable: availableCount,
            updates: allUpdates,
            duration: Date().timeIntervalSince(startTime),
            errors: errors
        )
    }

    // MARK: - Update Detection Methods

    /// Check for updates via Sparkle framework (common for Mac apps)
    private func checkViaSparkleFramework(appPath: URL, bundleIdentifier: String, currentVersion: String?) async -> AppUpdate? {
        let bundle = Bundle(url: appPath)
        guard let bundle = bundle else { return nil }

        // Check for SUFeedURL - Sparkle's update feed URL
        if let feedURLString = bundle.infoDictionary?["SUFeedURL"] as? String,
           let feedURL = URL(string: feedURLString) {

            // Check for current version
            let currentVersion = currentVersion ?? bundle.infoDictionary?["CFBundleShortVersionString"] as? String

            // For now, create a placeholder update record
            // In a full implementation, you would fetch and parse the appcast feed
            let appName = (bundle.infoDictionary?["CFBundleDisplayName"] as? String) ??
                         (bundle.infoDictionary?["CFBundleName"] as? String) ??
                         appPath.deletingPathExtension().lastPathComponent
            return await parseSparkleFeed(feedURL: feedURL, bundleIdentifier: bundleIdentifier, appName: appName, currentVersion: currentVersion, appPath: appPath)
        }

        return nil
    }

    /// Parse Sparkle appcast feed for update information
    private func parseSparkleFeed(feedURL: URL, bundleIdentifier: String, appName: String, currentVersion: String?, appPath: URL) async -> AppUpdate? {
        do {
            // Try to fetch the appcast feed
            // Note: This is a simplified implementation - production code would handle
            // XML parsing of the Sparkle appcast format properly
            let (data, _) = try await URLSession.shared.data(from: feedURL)

            // Parse the appcast XML to find the latest version
            // This is a simplified regex-based approach - proper implementation would use XMLParser
            let xmlString = String(data: data, encoding: .utf8) ?? ""

            // Extract version using regex patterns common in Sparkle feeds
            let latestVersion = extractLatestVersionFromSparkleFeed(xmlString)

            if let latest = latestVersion, let current = currentVersion {
                let comparison = AppUpdate.compareVersions(current, latest)

                return AppUpdate(
                    bundleIdentifier: bundleIdentifier,
                    appName: appName,
                    currentVersion: current,
                    latestVersion: latest,
                    appPath: appPath,
                    updateAvailable: comparison == .updateAvailable,
                    updateURL: extractDownloadURLFromSparkleFeed(xmlString),
                    releaseNotes: extractReleaseNotesFromSparkleFeed(xmlString)
                )
            }
        } catch {
            // Network or parse error - fall through to return nil
        }

        return nil
    }

    /// Extract version from Sparkle appcast XML
    private func extractLatestVersionFromSparkleFeed(_ xml: String) -> String? {
        // Look for sparkle:version attribute in the first item
        let pattern = #"<item[^>]*>.*?<sparkle:version[^>]*>([^<]+)</ sparkle:version>"#
        if let regex = try? NSRegularExpression(pattern: pattern.replacingOccurrences(of: " ", with: ""), options: [.dotMatchesLineSeparators]),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           match.numberOfRanges > 1 {
            return String(xml[Range(match.range(at: 1), in: xml)!])
        }

        // Fallback: look for version attribute
        let fallbackPattern = #"version="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: fallbackPattern),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           match.numberOfRanges > 1 {
            return String(xml[Range(match.range(at: 1), in: xml)!])
        }

        return nil
    }

    /// Extract download URL from Sparkle appcast XML
    private func extractDownloadURLFromSparkleFeed(_ xml: String) -> URL? {
        let pattern = #"<enclosure[^>]*url="([^"]+)""#
        if let regex = try? NSRegularExpression(pattern: pattern),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           match.numberOfRanges > 1,
           let urlRange = Range(match.range(at: 1), in: xml) {
            return URL(string: String(xml[urlRange]))
        }
        return nil
    }

    /// Extract release notes from Sparkle appcast XML
    private func extractReleaseNotesFromSparkleFeed(_ xml: String) -> String? {
        let pattern = #"<sparkle:releaseNotesLink[^>]*>([^<]+)</ sparkle:releaseNotesLink>"#
        if let regex = try? NSRegularExpression(pattern: pattern.replacingOccurrences(of: " ", with: "")),
           let match = regex.firstMatch(in: xml, range: NSRange(xml.startIndex..., in: xml)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: xml) {
            return String(xml[range])
        }
        return nil
    }

    /// Check for updates via Mac App Store
    private func checkViaAppStore(bundleIdentifier: String, currentVersion: String?, appPath: URL) async -> AppUpdate? {
        // For App Store apps, we would need to query the App Store API
        // This is a placeholder for future implementation
        // Currently returns nil to fall back to default behavior

        return nil
    }

    // MARK: - App Bundle Analysis

    /// Get app dependencies/frameworks from an app bundle
    func getAppDependencies(for appPath: URL) -> [AppDependency] {
        var dependencies: [AppDependency] = []

        let frameworksPath = appPath.appendingPathComponent("Contents/Frameworks")

        guard fileManager.fileExists(atPath: frameworksPath.path) else {
            return dependencies
        }

        guard let enumerator = fileManager.enumerator(
            at: frameworksPath,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return dependencies
        }

        for case let url as URL in enumerator {
            let pathExtension = url.pathExtension

            // Frameworks (.framework) and dynamic libraries (.dylib)
            if pathExtension == "framework" || pathExtension == "dylib" {
                let name = url.deletingPathExtension().lastPathComponent

                // Get file size
                var isDirectory: ObjCBool = false
                var size: Int64 = 0

                if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
                    if let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                       let fileSize = attributes[.size] as? Int64 {
                        size = isDirectory.boolValue ? getDirectorySize(url) : fileSize
                    }
                }

                let dependencyType: AppDependency.DependencyType = pathExtension == "framework" ? .framework : .dylib

                dependencies.append(AppDependency(
                    name: name,
                    type: dependencyType,
                    path: url,
                    size: size,
                    version: getFrameworkVersion(url)
                ))
            }
        }

        return dependencies.sorted { $0.name.localizedCompare($1.name) == .orderedAscending }
    }

    /// Get all file locations associated with an app
    func getAppFileLocations(for bundleIdentifier: String, appPath: URL) -> [AppFileLocation] {
        var locations: [AppFileLocation] = []

        // App bundle location
        if let bundleAttrs = try? fileManager.attributesOfItem(atPath: appPath.path),
           let size = bundleAttrs[.size] as? Int64,
           let modDate = bundleAttrs[.modificationDate] as? Date {
            locations.append(AppFileLocation(
                path: appPath.path,
                type: .appBundle,
                size: size,
                lastModified: modDate
            ))
        }

        // Application Support
        if let supportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let appSupportPath = supportURL.appendingPathComponent(bundleIdentifier)
            if fileManager.fileExists(atPath: appSupportPath.path),
               let attrs = try? fileManager.attributesOfItem(atPath: appSupportPath.path),
               let size = attrs[.size] as? Int64,
               let modDate = attrs[.modificationDate] as? Date {
                locations.append(AppFileLocation(
                    path: appSupportPath.path,
                    type: .appSupport,
                    size: size,
                    lastModified: modDate
                ))
            }
        }

        // Caches
        if let cachesURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first {
            let cachePath = cachesURL.appendingPathComponent(bundleIdentifier)
            if fileManager.fileExists(atPath: cachePath.path),
               let attrs = try? fileManager.attributesOfItem(atPath: cachePath.path),
               let size = attrs[.size] as? Int64,
               let modDate = attrs[.modificationDate] as? Date {
                locations.append(AppFileLocation(
                    path: cachePath.path,
                    type: .caches,
                    size: size,
                    lastModified: modDate
                ))
            }
        }

        // Preferences
        let prefsPath = fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first?
            .appendingPathComponent("Preferences")
            .appendingPathComponent("\(bundleIdentifier).plist")
        if let prefs = prefsPath, fileManager.fileExists(atPath: prefs.path),
           let attrs = try? fileManager.attributesOfItem(atPath: prefs.path),
           let size = attrs[.size] as? Int64,
           let modDate = attrs[.modificationDate] as? Date {
            locations.append(AppFileLocation(
                path: prefs.path,
                type: .preferences,
                size: size,
                lastModified: modDate
            ))
        }

        // Containers (sandboxed apps)
        let containersBase = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers")
        let containerPath = containersBase.appendingPathComponent(bundleIdentifier)
        if fileManager.fileExists(atPath: containerPath.path),
           let attrs = try? fileManager.attributesOfItem(atPath: containerPath.path),
           let size = attrs[.size] as? Int64,
           let modDate = attrs[.modificationDate] as? Date {
            locations.append(AppFileLocation(
                path: containerPath.path,
                type: .containers,
                size: size,
                lastModified: modDate
            ))
        }

        // Saved Application State
        let savedStateBase = fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Saved Application State")
        let savedStatePath = savedStateBase.appendingPathComponent("\(bundleIdentifier).savedState")
        if fileManager.fileExists(atPath: savedStatePath.path),
           let attrs = try? fileManager.attributesOfItem(atPath: savedStatePath.path),
           let size = attrs[.size] as? Int64,
           let modDate = attrs[.modificationDate] as? Date {
            locations.append(AppFileLocation(
                path: savedStatePath.path,
                type: .savedState,
                size: size,
                lastModified: modDate
            ))
        }

        return locations
    }

    // MARK: - Helper Methods

    private func getDirectorySize(_ url: URL) -> Int64 {
        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey],
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if let resourceValues = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = resourceValues.fileSize {
                    totalSize += Int64(fileSize)
                }
            }
        }

        return totalSize
    }

    private func getFrameworkVersion(_ frameworkURL: URL) -> String? {
        // For frameworks, check the Info.plist for version
        let infoPlistPath = frameworkURL.appendingPathComponent("Contents/Info.plist")
        if let plist = NSDictionary(contentsOfFile: infoPlistPath.path),
           let version = plist["CFBundleShortVersionString"] as? String {
            return version
        }

        // For standalone dylibs, check the version in the filename
        let name = frameworkURL.deletingPathExtension().lastPathComponent
        let versionPattern = #"(\d+\.\d+(\.\d+)?)$"#
        if let regex = try? NSRegularExpression(pattern: versionPattern),
           let match = regex.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           match.numberOfRanges > 1,
           let range = Range(match.range(at: 1), in: name) {
            return String(name[range])
        }

        return nil
    }

    /// Clear update cache
    func clearCache() {
        updates.removeAll()
        lastCheckDate = nil
    }
}

// MARK: - App Dependency Model

/// Represents a framework or library dependency
struct AppDependency: Identifiable, Sendable, Codable {
    let id = UUID()
    let name: String
    let type: DependencyType
    let path: URL
    let size: Int64
    let version: String?

    enum DependencyType: String, Sendable, Codable {
        case framework = "Framework"
        case dylib = "Dynamic Library"
        case xpc = "XPC Service"
        case other = "Other"

        var icon: String {
            switch self {
            case .framework: return "cube.fill"
            case .dylib: return "link"
            case .xpc: return "arrow.up.arrow.down"
            case .other: return "doc.fill"
            }
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }
}

