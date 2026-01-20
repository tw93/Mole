//
//  PrivilegedHelperManager.swift
//  Tonic
//
//  Manages privileged helper tool for root-required operations
//

import Foundation
import ServiceManagement

/// Manages installation and communication with the privileged helper tool
@Observable
public final class PrivilegedHelperManager: NSObject {

    public static let shared = PrivilegedHelperManager()

    private let helperLabel = "com.tonicformac.app.helper"
    private(set) var isHelperInstalled = false
    private(set) var isHelperConnected = false

    public var installationStatus: String = "Unknown"
    public var lastError: String?

    // Computed property for isInstalled that FileOperations expects
    public var isInstalled: Bool {
        return isHelperInstalled
    }

    private override init() {
        super.init()
        _ = checkInstallationStatus()
    }

    // MARK: - Installation Management

    /// Check if the helper is currently installed
    public func checkInstallationStatus() -> Bool {
        // Try to get the job dictionary to check if helper is installed
        // Note: SMJobCopyDictionary is deprecated but still works for checking
        // Core Foundation objects are automatically memory managed in Swift
        let jobData = SMJobCopyDictionary(kSMDomainUserLaunchd, helperLabel as CFString)
        let isInstalled = jobData != nil

        isHelperInstalled = isInstalled
        installationStatus = isHelperInstalled ? "Installed" : "Not Installed"
        return isHelperInstalled
    }

    /// Install the privileged helper tool
    public func installHelper() async throws {
        installationStatus = "Installing..."

        // Create authorization reference
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authRef)

        guard status == errAuthorizationSuccess, let auth = authRef else {
            throw PrivilegedHelperError.authorizationFailed
        }

        defer {
            AuthorizationFree(auth, [])
        }

        var error: Unmanaged<CFError>?

        // SMJobBless: domain, executableLabel, auth, outError
        // Note: SMJobBless is deprecated in macOS 13+, but still required for privileged helpers
        let success = SMJobBless(
            kSMDomainUserLaunchd,
            helperLabel as CFString,
            auth,
            &error
        )

        if !success {
            if let error = error {
                let cfError = error.takeRetainedValue() as Error
                lastError = cfError.localizedDescription
                throw cfError
            }
            throw PrivilegedHelperError.installationFailed("Unknown error")
        }

        isHelperInstalled = true
        installationStatus = "Installed"
    }

    /// Uninstall the privileged helper tool
    public func uninstallHelper() async throws {
        // Create authorization reference
        var authRef: AuthorizationRef?
        let status = AuthorizationCreate(nil, nil, [], &authRef)

        guard status == errAuthorizationSuccess, let auth = authRef else {
            throw PrivilegedHelperError.authorizationFailed
        }

        defer {
            AuthorizationFree(auth, [])
        }

        var error: Unmanaged<CFError>?

        // SMJobRemove: domain, label, auth, wait, error
        let success = SMJobRemove(
            kSMDomainUserLaunchd,
            helperLabel as CFString,
            auth,
            true,
            &error
        )

        if !success {
            if let error = error {
                let cfError = error.takeRetainedValue() as Error
                throw cfError
            }
            throw PrivilegedHelperError.operationFailed("Failed to uninstall helper")
        }

        isHelperInstalled = false
        installationStatus = "Not Installed"
    }

    // MARK: - Connection Management

    /// Establish connection to the helper
    public func establishConnection() async throws {
        guard isHelperInstalled else {
            throw PrivilegedHelperError.notInstalled
        }

        // In production, this would create XPC connection
        // For now, simulate connection
        isHelperConnected = true
    }

    /// Disconnect from the helper
    public func disconnect() {
        isHelperConnected = false
    }

    // MARK: - Privileged Operations

    /// Delete a file at the given path with root privileges
    public func deleteFile(atPath path: String) async throws -> Bool {
        guard isHelperConnected else {
            throw PrivilegedHelperError.communicationFailed("Not connected to helper")
        }

        // Check if file is protected
        if ProtectedApps.isPathProtected(path) {
            throw PrivilegedHelperError.operationFailed("Cannot delete protected path")
        }

        // In production, this would call the XPC service
        // For now, use FileManager directly (works for user-owned files)
        try FileManager.default.removeItem(atPath: path)
        return true
    }

    /// Delete multiple files at the given paths
    public func deleteFiles(atPaths paths: [String]) async throws -> (Int, String?) {
        var successCount = 0

        for path in paths {
            do {
                _ = try await deleteFile(atPath: path)
                successCount += 1
            } catch {
                // Continue with next file
            }
        }

        return (successCount, nil)
    }

    /// Move a file to trash (even if protected)
    public func moveFileToTrash(atPath path: String) async throws -> Bool {
        guard isHelperConnected else {
            throw PrivilegedHelperError.communicationFailed("Not connected to helper")
        }

        // Use FileManager's trashItem
        var resultingURL: NSURL?
        try FileManager.default.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)
        return resultingURL != nil
    }

    /// Clear system cache directory
    public func clearCache(atPath cachePath: String) async throws -> Int64 {
        guard isHelperConnected else {
            throw PrivilegedHelperError.communicationFailed("Not connected to helper")
        }

        var totalSize: Int64 = 0
        let fileManager = FileManager.default

        guard let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: cachePath), includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }

        for case let url as URL in enumerator {
            do {
                let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                let fileSize = Int64(resourceValues.fileSize ?? 0)
                try fileManager.removeItem(at: url)
                totalSize += fileSize
            } catch {
                // Continue with next item
            }
        }

        return totalSize
    }

    /// Run a cleanup command with root privileges
    public func runCleanupCommand(_ command: String, arguments: [String]) async throws -> (String?, Int32, String?) {
        guard isHelperConnected else {
            throw PrivilegedHelperError.communicationFailed("Not connected to helper")
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: command)
        process.arguments = arguments

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        try process.run()
        process.waitUntilExit()

        let outputData = outputPipe.fileHandleForReading.readDataToEndOfFile()
        let errorData = errorPipe.fileHandleForReading.readDataToEndOfFile()

        let output = String(data: outputData, encoding: .utf8)
        let errorOutput = String(data: errorData, encoding: .utf8)

        return (output, process.terminationStatus, errorOutput)
    }

    /// Securely delete a file by overwriting before deletion
    public func secureDeleteFile(atPath path: String, passes: Int = 3) async throws -> Bool {
        guard isHelperConnected else {
            throw PrivilegedHelperError.communicationFailed("Not connected to helper")
        }

        // Check if file exists
        guard FileManager.default.fileExists(atPath: path) else {
            throw PrivilegedHelperError.operationFailed("File not found")
        }

        // Perform secure deletion
        try await performSecureDelete(atPath: path, passes: passes)
        return true
    }

    /// Perform the actual secure deletion
    private func performSecureDelete(atPath path: String, passes: Int) async throws {
        let fileManager = FileManager.default
        let fileAttributes = try fileManager.attributesOfItem(atPath: path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0

        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw PrivilegedHelperError.operationFailed("Cannot open file for writing")
        }

        // Overwrite patterns for secure deletion
        let patterns: [UInt8] = [0x00, 0xFF, 0x55, 0xAA, 0x00, 0xFF]

        for pass in 0..<passes {
            handle.seek(toFileOffset: 0)
            let pattern = patterns[pass % patterns.count]

            // Create buffer of 64KB chunks
            let chunkSize = 64 * 1024
            var buffer = Data(repeating: pattern, count: chunkSize)

            var remaining = fileSize
            while remaining > 0 {
                let writeSize = min(Int64(chunkSize), remaining)
                if writeSize < chunkSize {
                    buffer = Data(repeating: pattern, count: Int(writeSize))
                }
                handle.write(buffer)
                remaining -= writeSize
            }

            handle.synchronizeFile()
        }

        handle.closeFile()

        // Finally remove the file
        try fileManager.removeItem(atPath: path)
    }

    /// Get helper version
    public func getVersion() async throws -> String {
        guard isHelperConnected else {
            throw PrivilegedHelperError.communicationFailed("Not connected to helper")
        }

        return Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "Unknown"
    }
}
