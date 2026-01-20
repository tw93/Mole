//
//  AppUninstaller.swift
//  Tonic
//
//  App uninstaller with complete app removal
//  Task ID: fn-1.8
//

import Foundation
import AppKit

/// Uninstall progress
public struct UninstallProgress: Sendable {
    let currentStep: String
    let filesRemoved: Int
    let bytesFreed: Int64

    var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }
}

/// App uninstaller service
@Observable
public final class AppUninstaller: @unchecked Sendable {

    public static let shared = AppUninstaller()

    private let fileManager = FileManager.default

    public var isUninstalling = false
    public private(set) var progress: UninstallProgress?

    private init() {}

    /// Get all file locations for an app
    public func getFileLocations(for appPath: String) async -> [AppFileLocation] {
        var locations: [AppFileLocation] = []

        let appName = URL(fileURLWithPath: appPath).deletingPathExtension().lastPathComponent

        // App bundle
        locations.append(contentsOf: await scanAppBundle(appPath))

        // Application Support
        let appSupportPath = fileManager.homeDirectoryForCurrentUser.path + "/Library/Application Support/" + appName
        if fileManager.fileExists(atPath: appSupportPath) {
            locations.append(AppFileLocation(
                path: appSupportPath,
                type: .appSupport,
                size: await getDirectorySize(appSupportPath),
                lastModified: await getModificationDate(appSupportPath)
            ))
        }

        // Caches
        let cachesPath = fileManager.homeDirectoryForCurrentUser.path + "/Library/Caches/" + appName
        if fileManager.fileExists(atPath: cachesPath) {
            locations.append(AppFileLocation(
                path: cachesPath,
                type: .caches,
                size: await getDirectorySize(cachesPath),
                lastModified: await getModificationDate(cachesPath)
            ))
        }

        // Preferences
        let prefsPath = fileManager.homeDirectoryForCurrentUser.path + "/Library/Preferences/" + appName + ".plist"
        if fileManager.fileExists(atPath: prefsPath) {
            locations.append(AppFileLocation(
                path: prefsPath,
                type: .preferences,
                size: await getFileSize(prefsPath),
                lastModified: await getModificationDate(prefsPath)
            ))
        }

        return locations
    }

    /// Uninstall an app completely
    public func uninstallApp(at appPath: String, locations: [AppFileLocation]) async throws {
        isUninstalling = true
        defer { isUninstalling = false }

        var bytesFreed: Int64 = 0
        var filesRemoved = 0

        // Remove app bundle last
        let locationsToRemove = locations.filter { $0.type != .appBundle }
        let appBundle = locations.first { $0.type == .appBundle }

        for location in locationsToRemove {
            progress = UninstallProgress(
                currentStep: "Removing \(location.type.rawValue)...",
                filesRemoved: filesRemoved,
                bytesFreed: bytesFreed
            )

            try fileManager.removeItem(atPath: location.path)
            bytesFreed += location.size
            filesRemoved += 1
        }

        // Remove app bundle
        if let appBundle = appBundle {
            progress = UninstallProgress(
                currentStep: "Removing app bundle...",
                filesRemoved: filesRemoved,
                bytesFreed: bytesFreed
            )

            try fileManager.removeItem(atPath: appBundle.path)
            bytesFreed += appBundle.size
            filesRemoved += 1
        }

        progress = UninstallProgress(
            currentStep: "Refreshing Launch Services...",
            filesRemoved: filesRemoved,
            bytesFreed: bytesFreed
        )

        await refreshLaunchServices()

        progress = nil
    }

    /// Get app icon for display
    public func getAppIcon(for path: String) -> NSImage? {
        guard fileManager.fileExists(atPath: path) else { return nil }
        let appURL = URL(fileURLWithPath: path)

        guard let bundle = Bundle(url: appURL) else { return nil }

        // Try to get the icon file
        if let iconFile = bundle.object(forInfoDictionaryKey: "CFBundleIconFile") as? String,
           let resourceName = iconFile.split(separator: ".").first,
           let iconPath = bundle.path(forResource: String(resourceName), ofType: "icns") {
            if let icon = NSImage(contentsOfFile: iconPath) {
                return icon
            }
        }

        // Fallback to app icon
        return NSImage(contentsOfFile: path)
    }

    // MARK: - Private Helpers

    private func scanAppBundle(_ appPath: String) async -> [AppFileLocation] {
        guard fileManager.fileExists(atPath: appPath) else { return [] }

        let size = await getDirectorySize(appPath)
        let modDate = await getModificationDate(appPath)

        return [AppFileLocation(
            path: appPath,
            type: .appBundle,
            size: size,
            lastModified: modDate
        )]
    }

    private func refreshLaunchServices() async {
        // Rebuild Launch Services database
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        process.arguments = ["-kill"]

        try? process.run()
        process.waitUntilExit()
    }

    private func getDirectorySize(_ path: String) async -> Int64 {
        var totalSize: Int64 = 0

        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        while let current = enumerator.nextObject() as? URL {
            if let resourceValues = try? current.resourceValues(forKeys: [.fileSizeKey]),
               let size = resourceValues.fileSize {
                totalSize += Int64(size)
            }
        }

        return totalSize
    }

    private func getFileSize(_ path: String) async -> Int64 {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let fileSize = attrs[.size] as? Int64 else {
            return 0
        }
        return fileSize
    }

    private func getModificationDate(_ path: String) async -> Date {
        guard let attrs = try? fileManager.attributesOfItem(atPath: path),
              let modDate = attrs[.modificationDate] as? Date else {
            return Date()
        }
        return modDate
    }
}
