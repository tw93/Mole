//
//  HiddenSpaceScanner.swift
//  Tonic
//
//  Hidden space detection and analysis service
//  Task ID: fn-1.22
//

import Foundation
import SwiftUI
import OSLog

// MARK: - Hidden Space Item

struct HiddenSpaceItem: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64
    let type: HiddenItemType
    let isHidden: Bool
    let lastModified: Date

    enum HiddenItemType: String, CaseIterable {
        case gitDirectory = "Git Repository"
        case nodeModules = "Node Modules"
        case buildArtifacts = "Build Artifacts"
        case cache = "Cache"
        case virtualEnvironment = "Virtual Environment"
        case docker = "Docker Data"
        case logs = "Logs"
        case other = "Other Hidden"
        case hiddenFile = "Hidden File"
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    var icon: String {
        switch type {
        case .gitDirectory: return "point.topleft.down.curvedto.point.bottomright.up"
        case .nodeModules: return "rectangle.stack.fill"
        case .buildArtifacts: return "hammer.fill"
        case .cache: return "archivebox"
        case .virtualEnvironment: return "cube.fill"
        case .docker: return "box.truck.fill"
        case .logs: return "doc.text"
        case .other, .hiddenFile: return "eye.slash"
        }
    }

    var color: Color {
        switch type {
        case .gitDirectory: return Color(red: 0.9, green: 0.3, blue: 0.3)
        case .nodeModules: return Color(red: 0.4, green: 0.6, blue: 0.9)
        case .buildArtifacts: return Color(red: 0.6, green: 0.4, blue: 0.8)
        case .cache: return Color(red: 0.3, green: 0.7, blue: 0.4)
        case .virtualEnvironment: return Color(red: 0.5, green: 0.5, blue: 0.7)
        case .docker: return Color(red: 0.2, green: 0.6, blue: 0.6)
        case .logs: return Color(red: 0.8, green: 0.5, blue: 0.2)
        case .other, .hiddenFile: return Color(red: 0.5, green: 0.5, blue: 0.5)
        }
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: HiddenSpaceItem, rhs: HiddenSpaceItem) -> Bool {
        lhs.id == rhs.id
    }
}

// MARK: - Hidden Space Scan Result

struct HiddenSpaceScanResult: Sendable {
    let timestamp: Date
    let scanDuration: TimeInterval
    let hiddenItems: [HiddenSpaceItem]
    let totalHiddenSize: Int64
    let itemCount: Int
    let discrepancyReport: DiskDiscrepancyReport

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalHiddenSize, countStyle: .file)
    }

    var topItems: [HiddenSpaceItem] {
        hiddenItems.sorted { $0.size > $1.size }.prefix(10).map { $0 }
    }

    func itemsByType(_ type: HiddenSpaceItem.HiddenItemType) -> [HiddenSpaceItem] {
        hiddenItems.filter { $0.type == type }
    }

    func totalSizeForType(_ type: HiddenSpaceItem.HiddenItemType) -> Int64 {
        itemsByType(type).reduce(0) { $0 + $1.size }
    }
}

// MARK: - Disk Discrepancy Report

struct DiskDiscrepancyReport: Sendable {
    let finderUsedSpace: Int64
    let duUsedSpace: Int64
    let discrepancy: Int64
    let possibleCauses: [DiscrepancyCause]

    var formattedDiscrepancy: String {
        ByteCountFormatter.string(fromByteCount: abs(discrepancy), countStyle: .file)
    }

    var hasDiscrepancy: Bool {
        abs(discrepancy) > 100 * 1024 * 1024 // > 100MB
    }

    struct DiscrepancyCause: Sendable {
        let name: String
        let description: String
        let estimatedSize: Int64
        let fixable: Bool

        var formattedSize: String {
            ByteCountFormatter.string(fromByteCount: estimatedSize, countStyle: .file)
        }
    }
}

// MARK: - Hidden Space Scanner

@Observable
final class HiddenSpaceScanner: @unchecked Sendable {
    private let logger = Logger(subsystem: "com.tonic.app", category: "HiddenSpace")
    private let fileManager = FileManager.default
    private let lock = NSLock()

    private var _isScanning = false
    private var _progress: Double = 0

    var isScanning: Bool {
        get { lock.locked { _isScanning } }
        set { lock.locked { _isScanning = newValue } }
    }

    var progress: Double {
        get { lock.locked { _progress } }
        set { lock.locked { _progress = newValue } }
    }

    // MARK: - Known Hidden Space Patterns

    private let hiddenSpacePatterns: [(pattern: String, type: HiddenSpaceItem.HiddenItemType)] = [
        (".git", .gitDirectory),
        (".hg", .gitDirectory),
        (".svn", .gitDirectory),
        ("node_modules", .nodeModules),
        (".npm", .cache),
        ("build", .buildArtifacts),
        (".build", .buildArtifacts),
        ("dist", .buildArtifacts),
        (".dist", .buildArtifacts),
        ("target", .buildArtifacts),
        (".gradle", .buildArtifacts),
        ("Pods", .buildArtifacts),
        (".venv", .virtualEnvironment),
        ("venv", .virtualEnvironment),
        (".virtualenv", .virtualEnvironment),
        (".conda", .virtualEnvironment),
        ("__pycache__", .cache),
        (".pytest_cache", .cache),
        (".cache", .cache),
        (".caches", .cache),
        ("Docker", .docker),
        (".docker", .docker),
        ("logs", .logs),
        (".logs", .logs),
        (".log", .logs),
    ]

    // MARK: - Main Scan Method

    func scanPath(_ path: String, includeDotfiles: Bool = true) async throws -> HiddenSpaceScanResult {
        guard !isScanning else {
            throw HiddenSpaceScanError.scanInProgress
        }

        isScanning = true
        progress = 0
        let startTime = Date()

        logger.info("Starting hidden space scan at: \(path)")

        var hiddenItems: [HiddenSpaceItem] = []
        var isDirectory: ObjCBool = false

        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            isScanning = false
            throw HiddenSpaceScanError.pathNotFound(path)
        }

        if isDirectory.boolValue {
            hiddenItems = await scanDirectoryForHiddenSpace(path, includeDotfiles: includeDotfiles)
        }

        // Calculate totals
        let totalSize = hiddenItems.reduce(0) { $0 + $1.size }

        // Run discrepancy analysis
        let discrepancyReport = await analyzeDiscrepancy(at: path)

        let duration = Date().timeIntervalSince(startTime)

        logger.info("Scan completed: found \(hiddenItems.count) items, \(totalSize) bytes")

        progress = 1.0
        isScanning = false

        return HiddenSpaceScanResult(
            timestamp: Date(),
            scanDuration: duration,
            hiddenItems: hiddenItems,
            totalHiddenSize: totalSize,
            itemCount: hiddenItems.count,
            discrepancyReport: discrepancyReport
        )
    }

    // MARK: - Directory Scanning

    private func scanDirectoryForHiddenSpace(_ path: String, includeDotfiles: Bool) async -> [HiddenSpaceItem] {
        var items: [HiddenSpaceItem] = []

        guard let contents = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .nameKey],
            options: includeDotfiles ? [] : [.skipsHiddenFiles]
        ) else {
            return items
        }

        for item in contents {
            let itemPath = item.path
            let name = item.lastPathComponent
            let isHidden = name.hasPrefix(".")

            // Skip if not including dotfiles and not in our patterns
            if !includeDotfiles && isHidden {
                // Check if it's a known hidden directory type
                let isKnownType = hiddenSpacePatterns.contains { $0.pattern == name }
                if !isKnownType {
                    continue
                }
            }

            guard let resourceValues = try? item.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey]) else {
                continue
            }

            let isDirectory = resourceValues.isDirectory ?? false

            if isDirectory {
                // Check if it matches known patterns
                if let pattern = hiddenSpacePatterns.first(where: { $0.pattern == name }) {
                    let size = await measureDirectorySize(itemPath)
                    if size > 1024 * 1024 { // Only include if > 1MB
                        let item = HiddenSpaceItem(
                            name: name,
                            path: itemPath,
                            size: size,
                            type: pattern.type,
                            isHidden: isHidden,
                            lastModified: getFileModificationDate(itemPath) ?? Date()
                        )
                        items.append(item)
                    }
                } else if isHidden && includeDotfiles {
                    // Generic hidden directory
                    let size = await measureDirectorySize(itemPath)
                    if size > 10 * 1024 * 1024 { // Only if > 10MB
                        let item = HiddenSpaceItem(
                            name: name,
                            path: itemPath,
                            size: size,
                            type: .other,
                            isHidden: true,
                            lastModified: getFileModificationDate(itemPath) ?? Date()
                        )
                        items.append(item)
                    }

                    // Recursively scan hidden directory for more items
                    if shouldScanRecursively(name) {
                        let subItems = await scanDirectoryForHiddenSpace(itemPath, includeDotfiles: true)
                        items.append(contentsOf: subItems)
                    }
                }
            } else if isHidden && includeDotfiles {
                // Hidden file
                if let fileSize = resourceValues.fileSize, fileSize > 1 * 1024 * 1024 { // > 1MB
                    let item = HiddenSpaceItem(
                        name: name,
                        path: itemPath,
                        size: Int64(fileSize),
                        type: .hiddenFile,
                        isHidden: true,
                        lastModified: getFileModificationDate(itemPath) ?? Date()
                    )
                    items.append(item)
                }
            }
        }

        return items
    }

    // MARK: - Discrepancy Analysis

    private func analyzeDiscrepancy(at path: String) async -> DiskDiscrepancyReport {
        // Get Finder-style size (via getattrlist)
        let finderSize = await getFinderSize(path)

        // Get du-style size (actual sum of file sizes)
        let duSize = await getDuSize(path)

        let discrepancy = finderSize - duSize

        // Identify possible causes
        var causes: [DiskDiscrepancyReport.DiscrepancyCause] = []

        // Check for common causes
        if discrepancy > 0 {
            // Finder reports more - likely directory overhead, extended attributes, etc.

            // Check for local time machine snapshots
            let tpsSize = await getTimeMachineSnapshotSize()
            if tpsSize > 0 {
                causes.append(DiskDiscrepancyReport.DiscrepancyCause(
                    name: "Local Time Machine Snapshots",
                    description: "APFS snapshots created by Time Machine before backup",
                    estimatedSize: tpsSize,
                    fixable: true
                ))
            }

            // Check for file system overhead
            causes.append(DiskDiscrepancyReport.DiscrepancyCause(
                name: "File System Overhead",
                description: "Block allocation and metadata overhead",
                estimatedSize: min(discrepancy, 100 * 1024 * 1024),
                fixable: false
            ))

            // Check for extended attributes
            let xaSize = await estimateExtendedAttributesSize(path)
            if xaSize > 0 {
                causes.append(DiskDiscrepancyReport.DiscrepancyCause(
                    name: "Extended Attributes",
                    description: "Metadata stored with files",
                    estimatedSize: xaSize,
                    fixable: false
                ))
            }
        }

        return DiskDiscrepancyReport(
            finderUsedSpace: finderSize,
            duUsedSpace: duSize,
            discrepancy: discrepancy,
            possibleCauses: causes
        )
    }

    // MARK: - Size Measurement Methods

    private func getFinderSize(_ path: String) async -> Int64 {
        // Use NSURLTotalFileAvailableKey and NSURLTotalFileSizeKey for Finder-like size
        if let url = URL(string: "file://\(path)"),
           let resourceValues = try? url.resourceValues(forKeys: [.totalFileSizeKey, .fileAllocatedSizeKey]) {
            // Finder shows allocated size (block size * blocks)
            return Int64(resourceValues.totalFileSize ?? resourceValues.fileAllocatedSize ?? 0)
        }

        // Fallback to attributes
        if let attrs = try? fileManager.attributesOfItem(atPath: path) {
            return (attrs[.size] as? Int64) ?? 0
        }

        return 0
    }

    private func getDuSize(_ path: String) async -> Int64 {
        return await measureDirectorySize(path)
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

    private func getTimeMachineSnapshotSize() async -> Int64 {
        // Use tmutil to get local snapshot size
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tmutil")
        process.arguments = ["listlocalsnapshots"]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            guard let output = try? pipe.fileHandleForReading.readToEnd(),
                  let outputString = String(data: output, encoding: .utf8) else {
                return 0
            }

            // If there are snapshots, estimate size (rough calculation)
            if outputString.contains("com.apple.TimeMachine.") {
                // Estimate based on typical snapshot sizes
                return 500 * 1024 * 1024 // 500MB minimum if snapshots exist
            }
        } catch {
            logger.error("Failed to get Time Machine snapshot size: \(error.localizedDescription)")
        }

        return 0
    }

    private func estimateExtendedAttributesSize(_ path: String) async -> Int64 {
        // This is a rough estimation
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-l", path]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()
            process.waitUntilExit()

            guard let output = try? pipe.fileHandleForReading.readToEnd() else {
                return 0
            }

            // Rough estimate: 100 bytes per line of xattr output
            let outputString = String(data: output, encoding: .utf8) ?? ""
            let lineCount = outputString.components(separatedBy: .newlines).count
            return Int64(lineCount * 100)
        } catch {
            return 0
        }
    }

    // MARK: - Cleanup Actions

    func cleanItems(_ items: [HiddenSpaceItem], progressHandler: ((Int) -> Void)? = nil) async -> CleanupResult {
        logger.info("Cleaning \(items.count) hidden space items")

        var cleanedSize: Int64 = 0
        var cleanedCount = 0
        var errors: [String] = []
        let fileOps = FileOperations.shared

        for (index, item) in items.enumerated() {
            // Only clean safe-to-remove items
            guard isSafeToRemove(item) else {
                errors.append("Skipped (unsafe): \(item.name)")
                continue
            }

            do {
                let result = await fileOps.deleteFiles(atPaths: [item.path])
                if result.success {
                    cleanedSize += item.size
                    cleanedCount += 1
                } else {
                    errors.append("Failed: \(item.name)")
                }
            } catch {
                errors.append("Error: \(item.name) - \(error.localizedDescription)")
            }

            progressHandler?(index + 1)
        }

        return CleanupResult(
            itemsCleaned: cleanedCount,
            spaceFreed: cleanedSize,
            errors: errors
        )
    }

    // MARK: - Helper Methods

    private func getFileModificationDate(_ path: String) -> Date? {
        return (try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date)
    }

    private func shouldScanRecursively(_ name: String) -> Bool {
        // Only scan certain hidden directories recursively
        let recursiveAllowed = [
            ".git", ".hg", ".svn",
            "node_modules",
            ".venv", "venv", ".virtualenv",
            ".npm", ".cache",
            "Pods", "target", ".gradle"
        ]
        return recursiveAllowed.contains(name)
    }

    private func isSafeToRemove(_ item: HiddenSpaceItem) -> Bool {
        // Never safe to remove .git directories (they contain version history)
        if item.type == .gitDirectory {
            return false
        }

        // Generally safe to remove build artifacts and caches
        if item.type == .buildArtifacts || item.type == .cache {
            return true
        }

        // Virtual environments can be recreated
        if item.type == .virtualEnvironment {
            return true
        }

        // Docker data is manageable through Docker
        if item.type == .docker {
            return true
        }

        // Node modules can be reinstalled
        if item.type == .nodeModules {
            return true
        }

        // Default to not safe for other hidden items
        return false
    }
}

// MARK: - Cleanup Result

struct CleanupResult: Sendable {
    let itemsCleaned: Int
    let spaceFreed: Int64
    let errors: [String]

    var formattedSpaceFreed: String {
        ByteCountFormatter.string(fromByteCount: spaceFreed, countStyle: .file)
    }

    var message: String {
        if errors.isEmpty {
            return "Successfully cleaned \(itemsCleaned) items and freed \(formattedSpaceFreed)."
        }
        return "Cleaned \(itemsCleaned) items, freed \(formattedSpaceFreed). \(errors.count) errors occurred."
    }
}

// MARK: - Errors

enum HiddenSpaceScanError: Error, LocalizedError {
    case scanInProgress
    case pathNotFound(String)
    case accessDenied(String)

    var errorDescription: String? {
        switch self {
        case .scanInProgress:
            return "A scan is already in progress"
        case .pathNotFound(let path):
            return "Path not found: \(path)"
        case .accessDenied(let path):
            return "Access denied: \(path)"
        }
    }
}

// MARK: - Preview Helpers

#if DEBUG
extension HiddenSpaceItem {
    static func sample(name: String, size: Int64, type: HiddenItemType) -> HiddenSpaceItem {
        HiddenSpaceItem(
            name: name,
            path: "/Users/example/\(name)",
            size: size,
            type: type,
            isHidden: name.hasPrefix("."),
            lastModified: Date()
        )
    }
}
#endif
