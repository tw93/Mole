//
//  DiskScanner.swift
//  Tonic
//
//  Concurrent directory scanner for disk analysis
//

import Foundation

// MARK: - Scan Error

enum DiskScanError: Error, LocalizedError {
    case accessDenied(String)
    case notFound(String)
    case timeout(String)
    case cancelled
    case permissionRequired(String)

    var errorDescription: String? {
        switch self {
        case .accessDenied(let path):
            return "Access denied: \(path)"
        case .notFound(let path):
            return "Not found: \(path)"
        case .timeout(let path):
            return "Scan timeout: \(path)"
        case .cancelled:
            return "Scan cancelled"
        case .permissionRequired(let path):
            return "Full Disk Access required to scan \(path)"
        }
    }
}

// MARK: - Disk Scanner

/// Concurrent disk scanner using Swift Concurrency
@Observable
final class DiskScanner: @unchecked Sendable {

    // MARK: - Properties

    private let fileManager = FileManager.default
    private let lock = NSLock()
    private var _isScanning = false
    private var _currentProgress: DiskScanProgress?
    private var scanTask: Task<Void, Never>?

    var isScanning: Bool {
        get { lock.locked { _isScanning } }
        set { lock.locked { _isScanning = newValue } }
    }

    var currentProgress: DiskScanProgress? {
        get { lock.locked { _currentProgress } }
        set { lock.locked { _currentProgress = newValue } }
    }

    /// Cancel the current scan
    func cancelScan() {
        scanTask?.cancel()
        isScanning = false
    }

    // MARK: - Public Scan Methods

    /// Scan a directory path concurrently with timeout
    func scanPath(_ path: String, progress: @escaping (DiskScanProgress) -> Void) async throws -> DiskScanResult {
        guard !isScanning else {
            throw DiskScanError.cancelled
        }

        // Cancel any existing scan
        scanTask?.cancel()

        // Create new scan task
        return try await withTaskCancellationHandler(
            operation: {
                try await withTimeout(seconds: 60) { [self] in // 60 second timeout
                    try await performScan(path: path, progress: progress)
                }
            },
            onCancel: {
                isScanning = false
            }
        )
    }

    /// Perform the actual scan operation
    private func performScan(path: String, progress: @escaping (DiskScanProgress) -> Void) async throws -> DiskScanResult {
        isScanning = true
        defer { isScanning = false }

        // Check if path exists and is accessible
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            throw DiskScanError.notFound(path)
        }

        guard isDirectory.boolValue else {
            throw DiskScanError.accessDenied(path)
        }

        let startTime = Date()
        var filesScanned: Int64 = 0
        var dirsScanned: Int64 = 0
        var bytesScanned: Int64 = 0

        // Use TaskGroup for concurrent scanning
        let (entries, largeFiles) = try await withThrowingTaskGroup(of: ChunkResult.self) { group in
            // Get directory contents with error handling
            let children: [URL]
            do {
                children = try fileManager.contentsOfDirectory(at: URL(fileURLWithPath: path), includingPropertiesForKeys: nil)
            } catch {
                // If we can't access the directory, check if it's a permission issue
                if (error as NSError).code == NSFileReadNoPermissionError {
                    throw DiskScanError.permissionRequired(path)
                }
                throw DiskScanError.accessDenied(path)
            }

            // Worker pool sized for I/O-bound scanning
            let numWorkers = max(ProcessInfo.processInfo.processorCount * 4, 4)
            let semaphore = AsyncSemaphore(value: numWorkers)

            for child in children {
                group.addTask {
                    await semaphore.acquire()
                    defer {
                        Task { await semaphore.release() }
                    }

                    return await self.scanChild(
                        child: child,
                        parentPath: path,
                        filesScanned: &filesScanned,
                        dirsScanned: &dirsScanned,
                        bytesScanned: &bytesScanned,
                        progress: progress
                    )
                }
            }

            // Collect results with sorted arrays (Top-N)
            var entriesBuffer: [(DirEntry, Int64)] = []
            var largeFilesBuffer: [(LargeFile, Int64)] = []
            let maxEntries = 100
            let maxLargeFiles = 50

            for try await result in group {
                // Top-N insertion for entries
                for entry in result.entries {
                    if entry.size > 0 {
                        if entriesBuffer.count < maxEntries {
                            entriesBuffer.append((entry, entry.size))
                            entriesBuffer.sort { $0.1 > $1.1 }
                        } else if entry.size > entriesBuffer.last?.1 ?? 0 {
                            entriesBuffer[maxEntries - 1] = (entry, entry.size)
                            entriesBuffer.sort { $0.1 > $1.1 }
                        }
                    }
                }

                // Top-N insertion for large files
                for file in result.largeFiles {
                    if largeFilesBuffer.count < maxLargeFiles {
                        largeFilesBuffer.append((file, file.size))
                        largeFilesBuffer.sort { $0.1 > $1.1 }
                    } else if file.size > largeFilesBuffer.last?.1 ?? 0 {
                        largeFilesBuffer[maxLargeFiles - 1] = (file, file.size)
                        largeFilesBuffer.sort { $0.1 > $1.1 }
                    }
                }

                // Emit progress periodically
                if filesScanned % 100 == 0 {
                    progress(DiskScanProgress(
                        filesScanned: filesScanned,
                        dirsScanned: dirsScanned,
                        bytesScanned: bytesScanned,
                        currentPath: result.currentPath
                    ))
                    currentProgress = DiskScanProgress(
                        filesScanned: filesScanned,
                        dirsScanned: dirsScanned,
                        bytesScanned: bytesScanned,
                        currentPath: result.currentPath
                    )
                }
            }

            let entries = entriesBuffer.map { $0.0 }
            let largeFiles = largeFilesBuffer.map { $0.0 }
            return (entries, largeFiles)
        }

        // Try Spotlight for large files as fallback
        let finalLargeFiles = await findLargeFilesWithSpotlight(in: path, existing: largeFiles)

        // Calculate total size
        let totalSize = entries.reduce(0) { $0 + $1.size }

        let duration = Date().timeIntervalSince(startTime)

        return DiskScanResult(
            entries: entries,
            largeFiles: finalLargeFiles,
            totalSize: totalSize,
            totalFiles: filesScanned,
            scanDuration: duration
        )
    }

    /// Get overview sizes for system directories
    func getOverviewSizes(for paths: [String], progress: @escaping (String, Int64) -> Void) async throws -> [DirectoryOverviewEntry] {
        var entries: [DirectoryOverviewEntry] = []

        for path in paths {
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }

            let entry = DirectoryOverviewEntry(
                name: displayName(for: path),
                path: path,
                size: nil,  // Pending scan
                isDir: true
            )
            entries.append(entry)
        }

        // Scan each path with limited concurrency
        try await withThrowingTaskGroup(of: (path: String, size: Int64).self) { group in
            let maxConcurrent = min(4, entries.count)

            for (index, entry) in entries.enumerated() {
                if index >= maxConcurrent { break }

                group.addTask {
                    let size = try await self.calculateDirectorySize(entry.path)
                    progress(entry.path, size)
                    return (entry.path, size)
                }
            }

            for try await (path, size) in group {
                if let index = entries.firstIndex(where: { $0.path == path }) {
                    entries[index].size = size
                }
            }
        }

        return entries
    }

    // MARK: - Private Scan Methods

    private struct ChunkResult {
        let entries: [DirEntry]
        let largeFiles: [LargeFile]
        let currentPath: String
    }

    private func scanChild(
        child: URL,
        parentPath: String,
        filesScanned: inout Int64,
        dirsScanned: inout Int64,
        bytesScanned: inout Int64,
        progress: @escaping (DiskScanProgress) -> Void
    ) async -> ChunkResult {
        let path = child.path
        let name = (path as NSString).lastPathComponent

        // Skip symlinks
        if isSymlink(at: path) {
            return ChunkResult(entries: [], largeFiles: [], currentPath: path)
        }

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return ChunkResult(entries: [], largeFiles: [], currentPath: path)
        }

        if isDirectory.boolValue {
            return await scanDirectory(
                path: path,
                name: name,
                filesScanned: &filesScanned,
                dirsScanned: &dirsScanned,
                bytesScanned: &bytesScanned,
                progress: progress
            )
        } else {
            return scanFile(
                path: path,
                name: name,
                filesScanned: &filesScanned,
                bytesScanned: &bytesScanned
            )
        }
    }

    private func scanFile(
        path: String,
        name: String,
        filesScanned: inout Int64,
        bytesScanned: inout Int64
    ) -> ChunkResult {
        guard let attributes = try? fileManager.attributesOfItem(atPath: path),
              (attributes[.size] as? Int64) != nil else {
            return ChunkResult(entries: [], largeFiles: [], currentPath: path)
        }

        let actualSize = getActualFileSize(from: attributes)
        filesScanned += 1
        bytesScanned += actualSize

        let entry = DirEntry(
            name: name,
            path: path,
            size: actualSize,
            isDir: false,
            lastAccess: (attributes[.modificationDate] as? Date) ?? Date()
        )

        var largeFiles: [LargeFile] = []
        let minLargeFileSize: Int64 = 100 * 1024 * 1024  // 100 MB
        if actualSize >= minLargeFileSize,
           !shouldSkipFileForLargeTracking(path) {
            largeFiles.append(LargeFile(name: name, path: path, size: actualSize))
        }

        return ChunkResult(entries: [entry], largeFiles: largeFiles, currentPath: path)
    }

    private func scanDirectory(
        path: String,
        name: String,
        filesScanned: inout Int64,
        dirsScanned: inout Int64,
        bytesScanned: inout Int64,
        progress: @escaping (DiskScanProgress) -> Void
    ) async -> ChunkResult {
        // Skip certain directories
        let skipDirs: Set<String> = [".git", ".hg", ".svn", "node_modules", ".npm", ".venv", "venv", "build", "dist", ".build", "target"]
        if skipDirs.contains(name) {
            return ChunkResult(entries: [], largeFiles: [], currentPath: path)
        }

        // Use du command for directory size (much faster than recursive scan)
        let size: Int64
        if let duSize = await getDirectorySizeFromDu(path) {
            size = duSize
        } else {
            size = await fastRecursiveScan(path: path)
        }
        dirsScanned += 1
        bytesScanned += size

        let entry = DirEntry(
            name: name,
            path: path,
            size: size,
            isDir: true,
            lastAccess: getLastAccessTime(for: path) ?? Date()
        )

        return ChunkResult(entries: [entry], largeFiles: [], currentPath: path)
    }

    private func calculateDirectorySize(_ path: String) async -> Int64 {
        // Use du command for all directories (fast and reliable with Full Disk Access)
        return await getDirectorySizeFromDu(path) ?? 0
    }

    private func fastRecursiveScan(path: String) async -> Int64 {
        // Fallback to recursive scan only if du fails
        guard let contents = try? fileManager.contentsOfDirectory(
            at: URL(fileURLWithPath: path),
            includingPropertiesForKeys: [.fileSizeKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return 0
        }

        let skipDirs: Set<String> = [".git", ".hg", ".svn", "node_modules", ".npm", ".venv", "venv", "build", "dist"]

        return await withTaskGroup(of: Int64.self) { group in
            for item in contents {
                let itemPath = item.path
                let name = (itemPath as NSString).lastPathComponent

                if skipDirs.contains(name) {
                    continue
                }

                guard let resourceValues = try? item.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey]),
                      let isDirectory = resourceValues.isDirectory else {
                    continue
                }

                if isDirectory {
                    // Limit recursion depth for performance
                    let depth = (itemPath as NSString).pathComponents.count
                    if depth < 5 {  // Only scan 5 levels deep
                        group.addTask {
                            return await self.fastRecursiveScan(path: itemPath)
                        }
                    }
                } else {
                    let size = Int64(resourceValues.fileSize ?? 0)
                    group.addTask { return size }
                }
            }

            var total: Int64 = 0
            for await size in group {
                total += size
            }
            return total
        }
    }

    // MARK: - Spotlight Integration

    private func findLargeFilesWithSpotlight(in path: String, existing: [LargeFile]) async -> [LargeFile] {
        if !existing.isEmpty {
            return existing
        }

        let minLargeFileSize: Int64 = 100 * 1024 * 1024  // 100 MB
        let query = "kMDItemFSSize >= \(minLargeFileSize)"

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
        process.arguments = ["-onlyin", path, query]

        let pipe = Pipe()
        process.standardOutput = pipe

        do {
            try process.run()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 30_000_000_000)  // 30 seconds
                process.terminate()
            }

            let data = try? pipe.fileHandleForReading.readToEnd()
            timeoutTask.cancel()

            guard let output = String(data: data ?? Data(), encoding: .utf8) else {
                return existing
            }

            var files: [LargeFile] = []
            for line in output.components(separatedBy: .newlines) {
                let filePath = line.trimmingCharacters(in: .whitespaces)
                guard !filePath.isEmpty,
                      !shouldSkipFileForLargeTracking(filePath),
                      let attributes = try? fileManager.attributesOfItem(atPath: filePath),
                      let fileSize = attributes[.size] as? Int64 else {
                    continue
                }

                if fileSize >= minLargeFileSize {
                    let name = (filePath as NSString).lastPathComponent
                    files.append(LargeFile(name: name, path: filePath, size: fileSize))
                }
            }

            files.sort { $0.size > $1.size }
            return Array(files.prefix(50))

        } catch {
            return existing
        }
    }

    // MARK: - Helper Methods

    private func getDirectorySizeFromDu(_ path: String) async -> Int64? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", path]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()

            let timeoutTask = Task {
                try? await Task.sleep(nanoseconds: 60_000_000_000)  // 60 seconds
                process.terminate()
            }

            guard let data = try? pipe.fileHandleForReading.readToEnd(),
                  let output = String(data: data, encoding: .utf8) else {
                timeoutTask.cancel()
                return nil
            }

            timeoutTask.cancel()

            let fields = output.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
            guard let kbString = fields.first,
                  let kb = Int64(kbString) else {
                return nil
            }

            return kb * 1024
        } catch {
            return nil
        }
    }

    private func getActualFileSize(from attributes: [FileAttributeKey: Any]) -> Int64 {
        guard let fileSize = attributes[.size] as? Int64 else {
            return 0
        }

        // Use file size directly for simplicity
        return fileSize
    }

    private func getLastAccessTime(for path: String) -> Date? {
        return try? fileManager.attributesOfItem(atPath: path)[.modificationDate] as? Date
    }

    private func isSymlink(at path: String) -> Bool {
        do {
            let attrs = try FileManager.default.attributesOfItem(atPath: path)
            return attrs[.type] as? FileAttributeType == .typeSymbolicLink
        } catch {
            return false
        }
    }

    private func shouldSkipFileForLargeTracking(_ path: String) -> Bool {
        let skipExtensions: Set<String> = [
            ".swift", ".m", ".h", ".mm", ".cpp", ".c", ".cc", ".hpp", ".hxx",
            ".js", ".jsx", ".ts", ".tsx", ".py", ".go", ".rs", ".java", ".kt",
            ".json", ".xml", ".yaml", ".yml", ".txt", ".md", ".lock"
        ]

        let ext = ((path as NSString).pathExtension as String).lowercased()
        return skipExtensions.contains(".\(ext)")
    }

    private func displayName(for path: String) -> String {
        switch path {
        case FileManager.default.homeDirectoryForCurrentUser.path:
            return "Home"
        case "/Applications":
            return "Applications"
        case "/Library":
            return "System Library"
        case "/Volumes":
            return "Volumes"
        default:
            return (path as NSString).lastPathComponent
        }
    }

    // MARK: - Timeout Helper

    /// Execute an async operation with a timeout
    private func withTimeout<T>(
        seconds: TimeInterval,
        operation: @escaping () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw DiskScanError.timeout("Operation exceeded \(seconds) seconds")
            }

            guard let result = try await group.next() else {
                throw DiskScanError.timeout("Operation timed out")
            }

            group.cancelAll()
            return result
        }
    }
}

// MARK: - Async Semaphore

/// Async semaphore for concurrent task limiting
actor AsyncSemaphore {
    private var value: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(value: Int) {
        self.value = value
    }

    func acquire() async {
        if value > 0 {
            value -= 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if let waiter = waiters.first {
            waiters.removeFirst()
            waiter.resume()
        } else {
            value += 1
        }
    }
}

// MARK: - NSLock Extension

extension NSLock {
    func locked<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}

// MARK: - Data Types

/// Represents a single entry in a directory scan
struct DirEntry: Identifiable, Codable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    var size: Int64
    let isDir: Bool
    let lastAccess: Date

    enum CodingKeys: String, CodingKey {
        case name, path, size, isDir, lastAccess
    }
}

/// Represents a large file entry
struct LargeFile: Identifiable, Codable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name, path, size
    }
}

/// Result of a directory scan operation
struct DiskScanResult: Codable, Sendable {
    let entries: [DirEntry]
    let largeFiles: [LargeFile]
    let totalSize: Int64
    let totalFiles: Int64
    let scanDuration: TimeInterval

    var formattedTotalSize: String {
        ByteCountFormatter.string(fromByteCount: totalSize, countStyle: .file)
    }

    var formattedFileCount: String {
        NumberFormatter.localizedString(from: NSNumber(value: totalFiles), number: .decimal)
    }
}

/// Progress updates during scanning
struct DiskScanProgress: Sendable {
    let filesScanned: Int64
    let dirsScanned: Int64
    let bytesScanned: Int64
    let currentPath: String

    var formattedFilesScanned: String {
        NumberFormatter.localizedString(from: NSNumber(value: filesScanned), number: .decimal)
    }

    var formattedBytesScanned: String {
        ByteCountFormatter.string(fromByteCount: bytesScanned, countStyle: .file)
    }
}

/// Entry for system overview (top-level directories)
struct DirectoryOverviewEntry: Identifiable, Hashable, Sendable {
    let id = UUID()
    let name: String
    let path: String
    var size: Int64?
    let isDir: Bool

    /// Returns display size, or "Scanning..." for pending entries
    var displaySize: String {
        guard let size = size else {
            return "Scanning..."
        }
        return ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// Whether this entry has a valid size
    var isScanned: Bool {
        return size != nil
    }
}
