//
//  SystemOptimization.swift
//  Tonic
//
//  System optimization operations
//  Task ID: fn-1.7
//

import Foundation

/// Optimization action type
public enum OptimizationAction: String, CaseIterable, Identifiable, Sendable {
    case flushDNS = "Flush DNS Cache"
    case clearRAM = "Clear Inactive Memory"
    case rebuildLaunchServices = "Rebuild Launch Services"
    case cleanQuickLook = "Clean QuickLook Cache"
    case cleanFonts = "Clean Font Cache"

    public var id: String { rawValue }

    var icon: String {
        switch self {
        case .flushDNS: return "network"
        case .clearRAM: return "memorychip"
        case .rebuildLaunchServices: return "arrow.clockwise"
        case .cleanQuickLook: return "eye"
        case .cleanFonts: return "textformat"
        }
    }

    var description: String {
        switch self {
        case .flushDNS: return "Clear DNS cache to resolve network issues"
        case .clearRAM: return "Free up inactive memory (requires helper tool)"
        case .rebuildLaunchServices: return "Rebuild application database"
        case .cleanQuickLook: return "Clear thumbnail and preview cache"
        case .cleanFonts: return "Clear font cache to fix rendering issues"
        }
    }
}

/// Optimization result
public struct OptimizationResult: Sendable {
    let action: OptimizationAction
    let success: Bool
    let bytesFreed: Int64
    let message: String

    var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }
}

/// System optimization service
@Observable
public final class SystemOptimization: @unchecked Sendable {

    public static let shared = SystemOptimization()

    private let fileManager = FileManager.default

    public var isOptimizing = false
    public private(set) var progress: Double = 0
    public private(set) var currentAction: String?

    private init() {}

    /// Perform an optimization action
    public func performAction(_ action: OptimizationAction) async throws -> OptimizationResult {
        isOptimizing = true
        defer { isOptimizing = false }

        currentAction = action.rawValue
        progress = 0

        let result: OptimizationResult

        switch action {
        case .flushDNS:
            result = try await flushDNS()
        case .clearRAM:
            result = try await clearRAM()
        case .rebuildLaunchServices:
            result = try await rebuildLaunchServices()
        case .cleanQuickLook:
            result = try await cleanQuickLook()
        case .cleanFonts:
            result = try await cleanFonts()
        }

        progress = 1.0
        currentAction = nil

        return result
    }

    // MARK: - Individual Actions

    private func flushDNS() async throws -> OptimizationResult {
        // Flush DNS cache using dscacheutil
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/dscacheutil")
        process.arguments = ["-flushcache"]

        try process.run()
        process.waitUntilExit()

        // Also flush mDNSResponder
        let mdnsProcess = Process()
        mdnsProcess.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        mdnsProcess.arguments = ["-HUP", "mDNSResponder"]

        try? mdnsProcess.run()
        mdnsProcess.waitUntilExit()

        return OptimizationResult(
            action: .flushDNS,
            success: true,
            bytesFreed: 0,
            message: "DNS cache flushed successfully"
        )
    }

    private func clearRAM() async throws -> OptimizationResult {
        // Use purge command to free inactive memory
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/purge")

        try process.run()
        process.waitUntilExit()

        return OptimizationResult(
            action: .clearRAM,
            success: true,
            bytesFreed: 0,
            message: "Inactive memory freed"
        )
    }

    private func rebuildLaunchServices() async throws -> OptimizationResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister")
        process.arguments = ["-kill", "-r", "-domain", "local", "-domain", "system", "-domain", "user"]

        try process.run()
        process.waitUntilExit()

        return OptimizationResult(
            action: .rebuildLaunchServices,
            success: true,
            bytesFreed: 0,
            message: "Launch Services rebuilt"
        )
    }

    private func cleanQuickLook() async throws -> OptimizationResult {
        var bytesFreed: Int64 = 0

        // QuickLook cache locations
        let quickLookPaths = [
            fileManager.homeDirectoryForCurrentUser.path + "/Library/Caches/com.apple.QuickLook",
            fileManager.homeDirectoryForCurrentUser.path + "/Library/Caches/com.apple.QuickLook.thumbnailcache",
            "/var/folders/*/C/com.apple.QuickLook.thumbnailcache"
        ]

        for path in quickLookPaths {
            // Expand wildcards
            if path.contains("*") {
                let expanded = expandWildcard(path)
                for expandedPath in expanded {
                    if fileManager.fileExists(atPath: expandedPath) {
                        let size = await getDirectorySize(expandedPath)
                        try? fileManager.removeItem(atPath: expandedPath)
                        bytesFreed += size
                    }
                }
            } else if fileManager.fileExists(atPath: path) {
                let size = await getDirectorySize(path)
                try? fileManager.removeItem(atPath: path)
                bytesFreed += size
            }
        }

        // Restart QuickLook server
        let qlProcess = Process()
        qlProcess.executableURL = URL(fileURLWithPath: "/usr/bin/killall")
        qlProcess.arguments = ["QuickLookThumbnailingDaemon"]
        try? qlProcess.run()
        qlProcess.waitUntilExit()

        return OptimizationResult(
            action: .cleanQuickLook,
            success: true,
            bytesFreed: bytesFreed,
            message: "QuickLook cache cleaned"
        )
    }

    private func cleanFonts() async throws -> OptimizationResult {
        var bytesFreed: Int64 = 0

        let fontCachePaths = [
            fileManager.homeDirectoryForCurrentUser.path + "/Library/Caches/com.apple.ATS",
            "/Library/Caches/com.apple.ATS"
        ]

        for path in fontCachePaths {
            if fileManager.fileExists(atPath: path) {
                let size = await getDirectorySize(path)
                try? fileManager.removeItem(atPath: path)
                bytesFreed += size
            }
        }

        return OptimizationResult(
            action: .cleanFonts,
            success: true,
            bytesFreed: bytesFreed,
            message: "Font cache cleaned"
        )
    }

    // MARK: - Helpers

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

    private func expandWildcard(_ path: String) -> [String] {
        // For now, just return the path - wildcard expansion can be added later
        return [path]
    }
}
