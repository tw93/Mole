//
//  PrivilegedHelperProtocol.swift
//  Tonic
//
//  XPC protocol for privileged helper tool communication
//

import Foundation

/// Protocol defining the interface between the app and privileged helper
@objc(PrivilegedHelperProtocol)
public protocol PrivilegedHelperProtocol: NSObjectProtocol {
    /// Delete a file at the given path with root privileges
    /// - Parameter path: The absolute path to the file to delete
    /// - Returns: True if deletion succeeded, false otherwise
    func deleteFile(atPath path: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// Delete multiple files at the given paths
    /// - Parameter paths: Array of absolute paths to delete
    /// - Returns: Number of successfully deleted files and error message if any
    func deleteFiles(atPaths paths: [String], withReply reply: @escaping (Int, String?) -> Void)

    /// Move a file to trash (even if protected)
    /// - Parameter path: The absolute path to the file
    /// - Returns: True if move succeeded
    func moveFileToTrash(atPath path: String, withReply reply: @escaping (Bool, String?) -> Void)

    /// Clear system cache directory
    /// - Parameter cachePath: The path to the cache directory
    /// - Returns: Size of cleared cache in bytes
    func clearCache(atPath cachePath: String, withReply reply: @escaping (Int64, String?) -> Void)

    /// Run a cleanup command with root privileges
    /// - Parameter command: The command to execute
    /// - Parameter arguments: Command arguments
    /// - Returns: Output, exit code, and error message
    func runCleanupCommand(_ command: String, arguments: [String], withReply reply: @escaping (String?, Int32, String?) -> Void)

    /// Check if helper is properly installed and working
    /// - Returns: Version string of the helper
    func getVersion(withReply reply: @escaping (String?) -> Void)

    /// Securely delete a file by overwriting before deletion
    /// - Parameter path: The absolute path to the file
    /// - Parameter passes: Number of overwrite passes (default: 3)
    /// - Returns: True if secure delete succeeded
    func secureDeleteFile(atPath path: String, passes: Int, withReply reply: @escaping (Bool, String?) -> Void)
}

/// Error types for privileged operations
public enum PrivilegedHelperError: Error, LocalizedError {
    case notInstalled
    case installationFailed(String)
    case authorizationFailed
    case communicationFailed(String)
    case operationFailed(String)
    case invalidResponse

    public var errorDescription: String? {
        switch self {
        case .notInstalled:
            return "Privileged helper is not installed"
        case .installationFailed(let message):
            return "Failed to install helper: \(message)"
        case .authorizationFailed:
            return "Authorization failed"
        case .communicationFailed(let message):
            return "Communication with helper failed: \(message)"
        case .operationFailed(let message):
            return "Operation failed: \(message)"
        case .invalidResponse:
            return "Invalid response from helper"
        }
    }
}

/// Result type for privileged operations
public struct PrivilegedOperationResult {
    public let success: Bool
    public let errorMessage: String?
    public let bytesFreed: Int64?
    public let filesProcessed: Int

    public init(success: Bool, errorMessage: String? = nil, bytesFreed: Int64? = nil, filesProcessed: Int = 0) {
        self.success = success
        self.errorMessage = errorMessage
        self.bytesFreed = bytesFreed
        self.filesProcessed = filesProcessed
    }
}
