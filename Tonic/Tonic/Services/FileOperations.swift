//
//  FileOperations.swift
//  Tonic
//
//  Service for trash and file management operations
//

import Foundation
import UniformTypeIdentifiers

// MARK: - File Operation Types

/// Types of file operations supported by FileOperations service
public enum FileOperationType: String, Sendable, CaseIterable, Codable {
    case delete = "Delete"
    case trash = "Move to Trash"
    case secureDelete = "Secure Delete"
    case copy = "Copy"
    case move = "Move"

    var icon: String {
        switch self {
        case .delete: return "trash"
        case .trash: return "arrow.down.doc"
        case .secureDelete: return "shredder"
        case .copy: return "doc.on.doc"
        case .move: return "arrow.right.doc.on.arrow.left"
        }
    }
}

/// Progress information for file operations
public struct FileOperationProgress: Sendable, Identifiable {
    public let id = UUID()
    public let operationType: FileOperationType
    public let currentFile: String
    public let processedFiles: Int
    public let totalFiles: Int
    public let bytesProcessed: Int64
    public let totalBytes: Int64

    public var progress: Double {
        guard totalFiles > 0 else { return 0 }
        return Double(processedFiles) / Double(totalFiles)
    }

    public var progressString: String {
        let progressPercent = Int(progress * 100)
        return "\(progressPercent)% (\(processedFiles)/\(totalFiles))"
    }
}

/// Result of a file operation
public struct FileOperationResult: Sendable {
    public let success: Bool
    public let operationType: FileOperationType
    public let filesProcessed: Int
    public let bytesFreed: Int64
    public let errors: [FileOperationError]
    public let duration: TimeInterval

    public var formattedBytesFreed: String {
        ByteCountFormatter.string(fromByteCount: bytesFreed, countStyle: .file)
    }

    public var formattedDuration: String {
        NumberFormatter.localizedString(from: NSNumber(value: duration), number: .decimal)
    }
}

/// Error information for file operations
public struct FileOperationError: Sendable, Error, LocalizedError {
    public let path: String
    public let errorType: ErrorType
    public let underlyingError: String?

    public enum ErrorType: String, Sendable {
        case accessDenied = "Access Denied"
        case notFound = "Not Found"
        case protected = "Protected File"
        case insufficientSpace = "Insufficient Space"
        case unknown = "Unknown Error"
    }

    public var errorDescription: String? {
        var description = "\(errorType.rawValue): \(path)"
        if let underlying = underlyingError {
            description += " - \(underlying)"
        }
        return description
    }
}

/// Record for undo/redo functionality
public struct FileOperationRecord: Sendable, Identifiable, Codable {
    public let id: UUID
    public let operationType: FileOperationType
    public let originalPaths: [String]
    public let destinationPaths: [String]?
    public let timestamp: Date

    public init(operationType: FileOperationType, originalPaths: [String], destinationPaths: [String]?) {
        self.id = UUID()
        self.operationType = operationType
        self.originalPaths = originalPaths
        self.destinationPaths = destinationPaths
        self.timestamp = Date()
    }

    /// Whether this operation can be undone
    public var canUndo: Bool {
        switch operationType {
        case .delete, .secureDelete:
            return false  // Cannot undo permanent deletion
        case .trash:
            return true   // Can restore from trash
        case .copy, .move:
            return destinationPaths != nil
        }
    }
}

// MARK: - File Operations Service

/// Service for managing file operations including trash, deletion, and secure deletion
@Observable
public final class FileOperations: @unchecked Sendable {

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let helperManager = PrivilegedHelperManager.shared

    private let lock = NSLock()
    private var _currentProgress: FileOperationProgress?
    private var _operationHistory: [FileOperationRecord] = []
    private var _isProcessing = false

    public var currentProgress: FileOperationProgress? {
        get { lock.locked { _currentProgress } }
        set { lock.locked { _currentProgress = newValue } }
    }

    public var operationHistory: [FileOperationRecord] {
        get { lock.locked { _operationHistory } }
        set { lock.locked { _operationHistory = newValue } }
    }

    public var isProcessing: Bool {
        get { lock.locked { _isProcessing } }
        set { lock.locked { _isProcessing = newValue } }
    }

    // Maximum history size for undo operations
    private let maxHistorySize = 50

    // MARK: - Singleton

    public static let shared = FileOperations()

    private init() {}

    // MARK: - Trash Operations

    /// Move files to trash using NSFileManager
    /// - Parameter paths: Array of file paths to move to trash
    /// - Parameter progressHandler: Optional closure for progress updates
    /// - Returns: Result of the operation
    @discardableResult
    public func moveFilesToTrash(
        atPaths paths: [String],
        progressHandler: ((FileOperationProgress) -> Void)? = nil
    ) async -> FileOperationResult {
        let startTime = Date()
        var errors: [FileOperationError] = []
        var processedCount = 0
        var bytesFreed: Int64 = 0
        var filesRequiringPrivileged: [String] = []

        isProcessing = true

        for (index, path) in paths.enumerated() {
            // Update progress
            let progress = FileOperationProgress(
                operationType: .trash,
                currentFile: path,
                processedFiles: index,
                totalFiles: paths.count,
                bytesProcessed: 0,
                totalBytes: 0
            )
            currentProgress = progress
            progressHandler?(progress)

            do {
                // Try to get file size before moving
                let attributes = try fileManager.attributesOfItem(atPath: path)
                let fileSize = attributes[.size] as? Int64 ?? 0

                // Attempt regular trash operation
                var resultingURL: NSURL?
                try fileManager.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: &resultingURL)

                if resultingURL != nil {
                    processedCount += 1
                    bytesFreed += fileSize
                } else {
                    // May require privileged access
                    filesRequiringPrivileged.append(path)
                }

            } catch let error as NSError {
                if error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoPermissionError {
                    // Permission denied - try with privileged helper
                    filesRequiringPrivileged.append(path)
                } else {
                    errors.append(FileOperationError(
                        path: path,
                        errorType: error.code == NSFileNoSuchFileError ? .notFound : .unknown,
                        underlyingError: error.localizedDescription
                    ))
                }
            }
        }

        // Handle files requiring privileged access
        if !filesRequiringPrivileged.isEmpty && helperManager.isInstalled {
            for path in filesRequiringPrivileged {
                do {
                    let success = try await helperManager.moveFileToTrash(atPath: path)
                    if success {
                        processedCount += 1
                    }
                } catch {
                    errors.append(FileOperationError(
                        path: path,
                        errorType: .accessDenied,
                        underlyingError: error.localizedDescription
                    ))
                }
            }
        }

        // Record operation for undo
        if !errors.isEmpty {
            let record = FileOperationRecord(
                operationType: .trash,
                originalPaths: paths,
                destinationPaths: nil
            )
            addToHistory(record)
        }

        isProcessing = false
        currentProgress = nil

        return FileOperationResult(
            success: errors.isEmpty || processedCount > 0,
            operationType: .trash,
            filesProcessed: processedCount,
            bytesFreed: bytesFreed,
            errors: errors,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    /// Empty the Trash
    /// - Parameter secure: Whether to securely delete (overwrite before delete)
    /// - Returns: Result of the operation
    @discardableResult
    public func emptyTrash(secure: Bool = false) async -> FileOperationResult {
        let startTime = Date()
        var errors: [FileOperationError] = []
        var filesProcessed = 0
        var bytesFreed: Int64 = 0

        isProcessing = true

        // Get trash paths for all user volumes
        let trashPaths = getAllTrashPaths()

        for trashPath in trashPaths {
            if let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: trashPath), includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in enumerator {
                    do {
                        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                        let fileSize = Int64(resourceValues.fileSize ?? 0)

                        if secure {
                            let _ = try await secureDeleteFile(atPath: url.path, passes: 3)
                        } else {
                            try fileManager.removeItem(at: url)
                        }

                        filesProcessed += 1
                        bytesFreed += fileSize
                    } catch {
                        errors.append(FileOperationError(
                            path: url.path,
                            errorType: .accessDenied,
                            underlyingError: error.localizedDescription
                        ))
                    }
                }
            }
        }

        isProcessing = false

        return FileOperationResult(
            success: errors.isEmpty || filesProcessed > 0,
            operationType: secure ? .secureDelete : .delete,
            filesProcessed: filesProcessed,
            bytesFreed: bytesFreed,
            errors: errors,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    /// Get the total size of items in Trash
    public func getTrashSize() async -> Int64 {
        var totalSize: Int64 = 0
        let trashPaths = getAllTrashPaths()

        for trashPath in trashPaths {
            if let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: trashPath), includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in enumerator {
                    do {
                        let resourceValues = try url.resourceValues(forKeys: [.fileSizeKey])
                        totalSize += Int64(resourceValues.fileSize ?? 0)
                    } catch {
                        continue
                    }
                }
            }
        }

        return totalSize
    }

    // MARK: - Delete Operations

    /// Delete files directly without moving to trash
    /// - Parameter paths: Array of file paths to delete
    /// - Parameter usePrivileged: Whether to use privileged helper for protected files
    /// - Returns: Result of the operation
    @discardableResult
    public func deleteFiles(
        atPaths paths: [String],
        usePrivileged: Bool = true
    ) async -> FileOperationResult {
        let startTime = Date()
        var errors: [FileOperationError] = []
        var processedCount = 0
        var bytesFreed: Int64 = 0

        isProcessing = true

        for (index, path) in paths.enumerated() {
            // Update progress
            currentProgress = FileOperationProgress(
                operationType: .delete,
                currentFile: path,
                processedFiles: index,
                totalFiles: paths.count,
                bytesProcessed: 0,
                totalBytes: 0
            )

            // Get file size before deletion
            let fileSize = (try? fileManager.attributesOfItem(atPath: path)[.size] as? Int64) ?? 0

            do {
                try fileManager.removeItem(atPath: path)
                processedCount += 1
                bytesFreed += fileSize
            } catch {
                // Check if protected and helper is available
                if usePrivileged && helperManager.isInstalled {
                    do {
                        let success = try await helperManager.deleteFile(atPath: path)
                        if success {
                            processedCount += 1
                            bytesFreed += fileSize
                        } else {
                            errors.append(FileOperationError(
                                path: path,
                                errorType: .accessDenied,
                                underlyingError: "Helper deletion failed"
                            ))
                        }
                    } catch {
                        errors.append(FileOperationError(
                            path: path,
                            errorType: .accessDenied,
                            underlyingError: error.localizedDescription
                        ))
                    }
                } else {
                    errors.append(FileOperationError(
                        path: path,
                        errorType: .accessDenied,
                        underlyingError: error.localizedDescription
                    ))
                }
            }
        }

        isProcessing = false
        currentProgress = nil

        return FileOperationResult(
            success: errors.isEmpty || processedCount > 0,
            operationType: .delete,
            filesProcessed: processedCount,
            bytesFreed: bytesFreed,
            errors: errors,
            duration: Date().timeIntervalSince(startTime)
        )
    }

    /// Securely delete a file by overwriting before deletion
    /// - Parameter path: Path to the file to securely delete
    /// - Parameter passes: Number of overwrite passes (default: 3)
    /// - Returns: True if successful
    public func secureDeleteFile(atPath path: String, passes: Int = 3) async throws -> Bool {
        // Check if file exists
        guard fileManager.fileExists(atPath: path) else {
            throw FileOperationError(path: path, errorType: .notFound, underlyingError: nil)
        }

        // Try with helper first if available
        if helperManager.isInstalled {
            return try await helperManager.secureDeleteFile(atPath: path, passes: passes)
        }

        // Fallback: manual secure deletion
        try await manualSecureDelete(atPath: path, passes: passes)
        return true
    }

    // MARK: - Undo/Redo

    /// Undo the last file operation
    public func undoLastOperation() async -> Bool {
        guard let lastOperation = operationHistory.last, lastOperation.canUndo else {
            return false
        }

        switch lastOperation.operationType {
        case .trash:
            // Restore files from trash
            for originalPath in lastOperation.originalPaths {
                await restoreFromTrash(originalPath: originalPath)
            }
            operationHistory.removeLast()
            return true

        case .move:
            // Move files back to original location
            if let destinations = lastOperation.destinationPaths {
                for (index, destPath) in destinations.enumerated() {
                    if index < lastOperation.originalPaths.count {
                        let originalPath = lastOperation.originalPaths[index]
                        try? fileManager.moveItem(atPath: destPath, toPath: originalPath)
                    }
                }
                operationHistory.removeLast()
                return true
            }

        default:
            return false
        }

        return false
    }

    /// Clear operation history
    public func clearHistory() {
        operationHistory.removeAll()
    }

    // MARK: - Helper Methods

    /// Get all trash paths for user and mounted volumes
    private func getAllTrashPaths() -> [String] {
        var paths: [String] = []

        // User trash
        if let trashPath = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first {
            paths.append(trashPath.path)
        }

        // Check for external volumes with .Trashes
        if let volumesRoot = try? fileManager.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: "/"), create: false) {
            let trashPath = volumesRoot.appendingPathComponent(".Trashes")
            if fileManager.fileExists(atPath: trashPath.path) {
                paths.append(trashPath.path)
            }
        }

        return paths
    }

    /// Restore a file from trash to its original location
    private func restoreFromTrash(originalPath: String) async -> Bool {
        let fileName = (originalPath as NSString).lastPathComponent
        let fileManager = FileManager.default

        // Find the file in trash
        guard let trashURL = fileManager.urls(for: .trashDirectory, in: .userDomainMask).first else {
            return false
        }

        // Search in trash
        if let enumerator = fileManager.enumerator(at: trashURL, includingPropertiesForKeys: [.nameKey]) {
            for case let url as URL in enumerator {
                if url.lastPathComponent == fileName {
                    do {
                        try fileManager.moveItem(at: url, to: URL(fileURLWithPath: originalPath))
                        return true
                    } catch {
                        return false
                    }
                }
            }
        }

        return false
    }

    /// Manual secure deletion implementation
    private func manualSecureDelete(atPath path: String, passes: Int) async throws {
        guard let handle = FileHandle(forWritingAtPath: path) else {
            throw FileOperationError(path: path, errorType: .accessDenied, underlyingError: "Cannot open file for writing")
        }

        let fileAttributes = try fileManager.attributesOfItem(atPath: path)
        let fileSize = fileAttributes[.size] as? Int64 ?? 0

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

            try handle.synchronize()
        }

        handle.closeFile()

        // Finally remove the file
        try fileManager.removeItem(atPath: path)
    }

    /// Add operation to history
    private func addToHistory(_ record: FileOperationRecord) {
        operationHistory.append(record)
        if operationHistory.count > maxHistorySize {
            operationHistory.removeFirst()
        }
    }

    // MARK: - Batch Operations

    /// Delete files in a directory matching a pattern
    public func deleteFilesInDirectory(
        atPath directoryPath: String,
        matchingPattern pattern: String? = nil,
        recursive: Bool = false
    ) async -> FileOperationResult {
        var filesToDelete: [String] = []

        guard fileManager.fileExists(atPath: directoryPath) else {
            return FileOperationResult(
                success: false,
                operationType: .delete,
                filesProcessed: 0,
                bytesFreed: 0,
                errors: [FileOperationError(path: directoryPath, errorType: .notFound, underlyingError: nil)],
                duration: 0
            )
        }

        let options: FileManager.DirectoryEnumerationOptions = recursive ? [] : [.skipsSubdirectoryDescendants]

        if let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: directoryPath), includingPropertiesForKeys: nil, options: options) {
            for case let url as URL in enumerator {
                let path = url.path

                if let pattern = pattern {
                    // Apply pattern matching
                    let fileName = (path as NSString).lastPathComponent
                    if fileName.range(of: pattern, options: .regularExpression) != nil {
                        filesToDelete.append(path)
                    }
                } else {
                    filesToDelete.append(path)
                }
            }
        }

        return await deleteFiles(atPaths: filesToDelete)
    }

    /// Calculate size of files at given paths
    public func calculateSize(ofPaths paths: [String]) -> Int64 {
        var totalSize: Int64 = 0

        for path in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
                continue
            }

            if isDirectory.boolValue {
                totalSize += directorySize(atPath: path)
            } else {
                if let attributes = try? fileManager.attributesOfItem(atPath: path),
                   let fileSize = attributes[.size] as? Int64 {
                    totalSize += fileSize
                }
            }
        }

        return totalSize
    }

    /// Recursively calculate directory size
    private func directorySize(atPath path: String) -> Int64 {
        var totalSize: Int64 = 0

        if let enumerator = fileManager.enumerator(at: URL(fileURLWithPath: path), includingPropertiesForKeys: [.fileSizeKey]) {
            for case let url as URL in enumerator {
                if let resourceValues = try? url.resourceValues(forKeys: [.fileSizeKey]),
                   let isDirectory = resourceValues.isDirectory,
                   !isDirectory {
                    totalSize += Int64(resourceValues.fileSize ?? 0)
                }
            }
        }

        return totalSize
    }

    // MARK: - Validation

    /// Check if paths are safe to delete (not protected)
    public func validatePathsForDeletion(_ paths: [String]) -> (safe: [String], protected: [String]) {
        var safePaths: [String] = []
        var protectedPaths: [String] = []

        for path in paths {
            if ProtectedApps.isPathProtected(path) {
                protectedPaths.append(path)
            } else {
                safePaths.append(path)
            }
        }

        return (safePaths, protectedPaths)
    }

    /// Check if a path requires elevated permissions
    public func requiresElevatedPermissions(_ path: String) -> Bool {
        // Try to read file attributes
        if let attributes = try? fileManager.attributesOfItem(atPath: path),
           let permissions = attributes[.posixPermissions] as? UInt16 {
            // Check if we have write permission
            let ownerOnly = (permissions & 0o200) != 0
            return !ownerOnly
        }
        return true
    }
}

// MARK: - FileHandle + Synchronize

extension FileHandle {
    func synchronize() throws {
        // fsync the file handle
        try self.synchronizeFile()
    }
}
