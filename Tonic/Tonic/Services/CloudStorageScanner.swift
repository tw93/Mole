//
//  CloudStorageScanner.swift
//  Tonic
//
//  Cloud storage scanning service
//  Task ID: fn-1.16
//

import Foundation

/// Cloud storage provider
public enum CloudProvider: String, CaseIterable, Identifiable {
    case icloud = "iCloud"
    case dropbox = "Dropbox"
    case googleDrive = "Google Drive"
    case onedrive = "OneDrive"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .icloud: return "icloud.fill"
        case .dropbox: return "circle.fill"
        case .googleDrive: return "globe"
        case .onedrive: return "cloud.fill"
        }
    }
}

/// Cloud storage scan result
public struct CloudStorageResult: Sendable {
    let provider: CloudProvider
    let localPath: String?
    let cacheSize: Int64
    let syncedFiles: Int

    var formattedCacheSize: String {
        ByteCountFormatter.string(fromByteCount: cacheSize, countStyle: .file)
    }
}

/// Cloud storage scanner
@Observable
public final class CloudStorageScanner: @unchecked Sendable {

    public static let shared = CloudStorageScanner()

    private let fileManager = FileManager.default

    public var isScanning = false

    private init() {}

    /// Scan for cloud storage services
    public func scanCloudServices() async -> [CloudStorageResult] {
        isScanning = true
        defer { isScanning = false }

        var results: [CloudStorageResult] = []

        // Scan for iCloud
        if let iCloudResult = await scaniCloud() {
            results.append(iCloudResult)
        }

        // Scan for Dropbox
        if let dropboxResult = await scanDropbox() {
            results.append(dropboxResult)
        }

        // Scan for Google Drive
        if let driveResult = await scanGoogleDrive() {
            results.append(driveResult)
        }

        // Scan for OneDrive
        if let onedriveResult = await scanOneDrive() {
            results.append(onedriveResult)
        }

        return results
    }

    /// Clear cloud cache
    public func clearCache(for provider: CloudProvider) async throws -> Int64 {
        guard let path = getCachePath(for: provider) else {
            return 0
        }

        let size = await getDirectorySize(path)
        try fileManager.removeItem(atPath: path)
        return size
    }

    // MARK: - Private Helpers

    private func scaniCloud() async -> CloudStorageResult? {
        let iCloudPath = fileManager.homeDirectoryForCurrentUser.path + "/Library/Mobile Documents"
        guard fileManager.fileExists(atPath: iCloudPath) else { return nil }

        let size = await getDirectorySize(iCloudPath)
        let files = await countFiles(in: iCloudPath)

        return CloudStorageResult(
            provider: .icloud,
            localPath: iCloudPath,
            cacheSize: size,
            syncedFiles: files
        )
    }

    private func scanDropbox() async -> CloudStorageResult? {
        let dropboxPath = fileManager.homeDirectoryForCurrentUser.path + "/Dropbox"
        guard fileManager.fileExists(atPath: dropboxPath) else { return nil }

        let size = await getDirectorySize(dropboxPath)
        let files = await countFiles(in: dropboxPath)

        return CloudStorageResult(
            provider: .dropbox,
            localPath: dropboxPath,
            cacheSize: size,
            syncedFiles: files
        )
    }

    private func scanGoogleDrive() async -> CloudStorageResult? {
        let drivePath = fileManager.homeDirectoryForCurrentUser.path + "/Google Drive"
        guard fileManager.fileExists(atPath: drivePath) else { return nil }

        let size = await getDirectorySize(drivePath)
        let files = await countFiles(in: drivePath)

        return CloudStorageResult(
            provider: .googleDrive,
            localPath: drivePath,
            cacheSize: size,
            syncedFiles: files
        )
    }

    private func scanOneDrive() async -> CloudStorageResult? {
        let onedrivePath = fileManager.homeDirectoryForCurrentUser.path + "/OneDrive"
        guard fileManager.fileExists(atPath: onedrivePath) else { return nil }

        let size = await getDirectorySize(onedrivePath)
        let files = await countFiles(in: onedrivePath)

        return CloudStorageResult(
            provider: .onedrive,
            localPath: onedrivePath,
            cacheSize: size,
            syncedFiles: files
        )
    }

    private func getCachePath(for provider: CloudProvider) -> String? {
        switch provider {
        case .icloud:
            return fileManager.homeDirectoryForCurrentUser.path + "/Library/Mobile Documents/com~apple~CloudDocs"
        case .dropbox:
            return fileManager.homeDirectoryForCurrentUser.path + "/Dropbox/.dropbox.cache"
        case .googleDrive:
            return fileManager.homeDirectoryForCurrentUser.path + "/Library/Application Support/Google/Drive"
        case .onedrive:
            return fileManager.homeDirectoryForCurrentUser.path + "/OneDrive/.cache"
        }
    }

    private func getDirectorySize(_ path: String) async -> Int64 {
        var totalSize: Int64 = 0

        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        var url: URL?
        while let current = enumerator.nextObject() as? URL {
            url = current
            if let resourceValues = try? current.resourceValues(forKeys: [.fileSizeKey]),
               let size = resourceValues.fileSize {
                totalSize += Int64(size)
            }
        }

        return totalSize
    }

    private func countFiles(in path: String) async -> Int {
        var count = 0

        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.isDirectoryKey]) else {
            return 0
        }

        var url: URL?
        while let current = enumerator.nextObject() as? URL {
            url = current
            if let resourceValues = try? current.resourceValues(forKeys: [.isDirectoryKey]),
               let isDirectory = resourceValues.isDirectory,
               !isDirectory {
                count += 1
            }
        }

        return count
    }
}
